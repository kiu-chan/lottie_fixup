/// Bakes `loopOut()`/`loopIn()` expressions in a decoded Lottie document
/// into real keyframes.
///
/// After Effects only exports keyframes for one short cycle and lets the
/// `loopOut()`/`loopIn()` expression repeat it. The `lottie` Flutter package
/// does not run expressions, so outside the authored keyframe range the
/// property just freezes. This spreads the keyframes out for real, the same
/// way After Effects interprets those calls.
///
/// Supported: `loopOut`/`loopIn` in `'cycle'`, `'pingpong'`, `'offset'`, and
/// `'continue'` mode, on any animated property, plus the duration-based
/// `loopOutDuration`/`loopInDuration(type, durationSeconds)` variants (which
/// repeat a fixed-length span of time rather than the whole keyframed
/// segment) in `'cycle'`/`'pingpong'` mode. `'offset'` and `'continue'`
/// additionally require every keyframe's value to be a plain numeric list
/// (position/scale/rotation/opacity, not a shape path or other structured
/// value), since baking them means doing arithmetic on the values
/// themselves.
///
/// Not supported (left untouched, reported via [BakeResult.skippedExpressions]):
/// `'offset'`/`'continue'` on a non-numeric value, any expression that calls
/// both `loopIn` and `loopOut` on the same property, a duration variant
/// whose duration is shorter than the keyframed segment itself (would need
/// interpolating a cut point mid-segment, which isn't implemented), and any
/// expression (loop-related or not, e.g. `wiggle`/`random`) on a property
/// that was never manually keyframed (`"a": 0`) — there's nothing to repeat
/// since it has no keyframes at all, scalar (`r`, `o`) or multi-dimensional
/// (`p`, `s`, `a`) alike. (`wiggle`/`random`/`time`-based expressions and
/// cross-layer references on such a property are instead handled by
/// `bakePropertyExpressions`.)
library;

/// Gap (in frames) left between the end of one loop and the start of the
/// next, used for an open `'cycle'` loop (first and last value differ)
/// whose value must jump back to the start.
///
/// Must be tiny: the `lottie` package samples time-remap a fraction of a
/// frame short of the integer boundary (composition_layer.dart divides by
/// `durationFrames + 0.01`), landing roughly 2.8e-5 frame before the loop
/// point at minimum. A gap wider than that swallows the sample into the
/// jump segment and reads back an interpolated mid-jump value instead of the
/// real one, causing a one-frame glitch every loop. Do not widen this.
const double loopGap = 1e-5;

/// Linear (no-ease) bezier easing control points, in this package's scalar
/// `{x, y}` convention: `o` describes the departure from a keyframe, `i` the
/// arrival at the next one. Used to force a straight, constant-velocity
/// segment for `'continue'` mode, since that segment didn't exist in the
/// original file and shouldn't inherit unrelated easing from a neighbor.
const Map<String, double> _linearOut = {'x': 0.0, 'y': 0.0};
const Map<String, double> _linearIn = {'x': 1.0, 'y': 1.0};

/// Matches a `loopIn(...)` or `loopOut(...)` call. Group 1 is `In`/`Out`;
/// group 2 is the loop mode argument (`cycle`, `pingpong`, `offset`,
/// `continue`), or absent when the call omits it — After Effects then
/// defaults to `'cycle'`.
final RegExp _loopCall = RegExp(r'''loop(In|Out)\s*\(\s*(?:['"](\w+)['"])?''');

/// Matches a `loopInDuration(...)`/`loopOutDuration(...)` call. Group 1 is
/// `In`/`Out`; group 3 is the loop mode (defaults to `'cycle'` when
/// omitted, same as [_loopCall]); group 4 is the duration argument, in
/// seconds.
final RegExp _loopDurationCall = RegExp(
  r'''loop(In|Out)Duration\s*\(\s*(?:(['"])(\w+)\2\s*,\s*)?([\d.]+)?''',
);

/// Result of baking loop expressions in one document.
class BakeResult {
  const BakeResult({
    required this.propertiesBaked,
    required this.totalLoops,
    required this.skippedExpressions,
  });

  /// How many animated properties had a `loopOut`/`loopIn` expression baked.
  final int propertiesBaked;

  /// Total number of extra loop repetitions written across all properties.
  final int totalLoops;

  /// Expressions that were found but weren't baked — not a `loopOut`/
  /// `loopIn`/`loopOutDuration`/`loopInDuration` call, `'offset'`/
  /// `'continue'` on a non-numeric value, a duration variant shorter than
  /// the keyframed segment, or an expression combining both `loopIn` and
  /// `loopOut` — and were left as-is.
  final List<String> skippedExpressions;

  bool get changed => propertiesBaked > 0;
}

/// Walks [doc] and bakes every supported `loopOut`/`loopIn` expression
/// found, mutating [doc] in place. Safe to call repeatedly: a document with
/// no more expressions is a no-op.
BakeResult bakeLoopExpressions(Map<String, dynamic> doc) {
  final start = (doc['ip'] as num?) ?? 0;
  final end = doc['op'] as num;
  final fr = (doc['fr'] as num?) ?? 30;
  final loopCounts = <int>[];
  final skipped = <String>[];
  _walk(doc, start, end, fr, loopCounts, skipped);
  return BakeResult(
    propertiesBaked: loopCounts.length,
    totalLoops: loopCounts.fold(0, (a, b) => a + b),
    skippedExpressions: skipped,
  );
}

void _walk(
  dynamic node,
  num start,
  num end,
  num fr,
  List<int> loopCounts,
  List<String> skipped,
) {
  if (node is Map<String, dynamic>) {
    final expr = node['x'];
    final k = node['k'];
    if (expr is String) {
      // Baking needs real keyframes to repeat: a property with `"a": 0`
      // (never manually animated) stores its value directly in `k` instead
      // — a plain number for a scalar property (rotation, opacity) or a
      // plain list of numbers for a multi-dimensional one (position, scale)
      // — so it can't be baked no matter the expression. Only `k` shaped as
      // a list of keyframe objects (`"a": 1`) is eligible.
      final keyframed = k is List && k.isNotEmpty && k.every((kf) => kf is Map);
      if (!keyframed) {
        skipped.add(expr);
      } else if (!_bakeMatchedLoop(node, expr, k, start, end, fr, loopCounts)) {
        skipped.add(expr);
      }
    }
    for (final value in node.values.toList()) {
      _walk(value, start, end, fr, loopCounts, skipped);
    }
  } else if (node is List) {
    for (final value in node) {
      _walk(value, start, end, fr, loopCounts, skipped);
    }
  }
}

/// Tries to match and bake [expr] as a loop call on an already-keyframed
/// property. Returns whether it was baked (and, if so, has already recorded
/// its loop count into [loopCounts]).
bool _bakeMatchedLoop(
  Map<String, dynamic> node,
  String expr,
  List<dynamic> k,
  num start,
  num end,
  num fr,
  List<int> loopCounts,
) {
  final matches = _loopCall.allMatches(expr).toList();
  final durationMatches = _loopDurationCall.allMatches(expr).toList();

  // Anything other than exactly one loop call of one kind — none (not a
  // loop expression at all), or more than one (e.g. loopIn and loopOut
  // combined on the same property) — isn't safe to bake automatically.
  if (matches.length == 1 && durationMatches.isEmpty) {
    final forward = matches.single.group(1) == 'Out';
    final mode = matches.single.group(2) ?? 'cycle';
    final supported = switch (mode) {
      'cycle' || 'pingpong' => true,
      'offset' || 'continue' => _numericKeyframes(k),
      _ => false,
    };
    if (!supported) return false;
    loopCounts.add(
      _bakeProperty(node, start, end, forward: forward, mode: mode),
    );
    return true;
  }

  if (durationMatches.length == 1 && matches.isEmpty) {
    final match = durationMatches.single;
    final forward = match.group(1) == 'Out';
    final mode = match.group(3) ?? 'cycle';
    final durationSeconds = num.tryParse(match.group(4) ?? '');
    // Only 'cycle'/'pingpong' are supported for the duration variant: unlike
    // tiling a whole segment, extrapolation ('continue') has no notion of a
    // fixed period, and 'offset' over an arbitrary duration isn't a
    // documented After Effects behavior worth guessing at.
    if (mode != 'cycle' && mode != 'pingpong') return false;
    if (durationSeconds == null || durationSeconds <= 0) return false;
    final durationFrames = durationSeconds * fr;
    final t0 = (k.first as Map)['t'] as num;
    final tEnd = (k.last as Map)['t'] as num;
    // Only supported when the requested duration reaches past the actual
    // keyframed span, so the "extra" time is a flat hold rather than a cut
    // through the middle of the real animation (which would need
    // interpolating a value at that cut point — not implemented).
    final feasible = forward
        ? (tEnd - durationFrames) < t0
        : (t0 + durationFrames) > tEnd;
    if (!feasible) return false;
    loopCounts.add(
      _bakeProperty(
        node,
        start,
        end,
        forward: forward,
        mode: mode,
        durationFrames: durationFrames,
      ),
    );
    return true;
  }

  return false;
}

/// Whether every keyframe's `s` is a plain list of numbers — the shape
/// `'offset'`/`'continue'` need in order to do arithmetic on the values.
bool _numericKeyframes(List<dynamic> keyframes) {
  for (final kf in keyframes) {
    if (kf is! Map || kf['s'] is! List) return false;
    if ((kf['s'] as List).any((v) => v is! num)) return false;
  }
  return true;
}

/// Bakes one animated property with a `loopOut`/`loopIn` expression.
/// Returns the number of extra loops written.
///
/// [durationFrames], when given (for `loopOutDuration`/`loopInDuration`),
/// replaces the natural keyframe-implied period with a fixed one: the
/// repeating "segment" becomes the last (forward) or first (backward)
/// [durationFrames] worth of time relative to the boundary keyframe, padded
/// with a flat hold back to a synthetic cut point wherever that span
/// extends past the actual keyframed range (which is the only case this
/// supports — see [_walk]'s feasibility check).
int _bakeProperty(
  Map<String, dynamic> prop,
  num start,
  num end, {
  required bool forward,
  required String mode,
  num? durationFrames,
}) {
  var keyframes = (prop['k'] as List).cast<Map<String, dynamic>>();
  prop.remove('x');

  var t0 = keyframes.first['t'] as num;
  final tEnd = keyframes.last['t'] as num;
  var period = tEnd - t0;
  if (period <= 0) return 0;

  if (durationFrames != null) {
    period = durationFrames;
    // A segment's easing pair (`i`/`o`) both live on the keyframe where that
    // segment *starts* (confirmed by real Bodymovin exports: a terminal
    // keyframe with no outgoing segment carries neither field). So the new
    // synthetic hold segment gets its own self-contained linear `i`/`o`
    // pair, and the existing keyframe it attaches to — which already fully
    // describes its own original segment — is left completely untouched.
    if (forward) {
      final cut = tEnd - durationFrames;
      keyframes = [
        {'t': cut, 's': keyframes.first['s'], 'i': _linearIn, 'o': _linearOut},
        ...keyframes,
      ];
      t0 = cut;
    } else {
      final cut = t0 + durationFrames;
      keyframes = [
        ...keyframes.sublist(0, keyframes.length - 1),
        {...keyframes.last, 'i': _linearIn, 'o': _linearOut},
        {'t': cut, 's': keyframes.last['s']},
      ];
    }
  }

  switch (mode) {
    case 'continue':
      return forward
          ? _bakeContinueForward(prop, keyframes, end)
          : _bakeContinueBackward(prop, keyframes, start);
    case 'offset':
      return forward
          ? _bakeOffsetForward(prop, keyframes, t0, period, end)
          : _bakeOffsetBackward(prop, keyframes, t0, period, start);
    case 'pingpong':
      return forward
          ? _bakeCycleForward(prop, keyframes, t0, period, end, pingpong: true)
          : _bakeBackwardCycle(
              prop,
              keyframes,
              t0,
              period,
              start,
              pingpong: true,
            );
    default: // 'cycle'
      return forward
          ? _bakeCycleForward(prop, keyframes, t0, period, end, pingpong: false)
          : _bakeBackwardCycle(
              prop,
              keyframes,
              t0,
              period,
              start,
              pingpong: false,
            );
  }
}

/// Bakes `loopOut('cycle'|'pingpong')`: repeats the segment shape forward to
/// [end], mirroring it every other repetition for `pingpong`.
int _bakeCycleForward(
  Map<String, dynamic> prop,
  List<Map<String, dynamic>> keyframes,
  num t0,
  num period,
  num end, {
  required bool pingpong,
}) {
  final segForward = [
    for (final kf in keyframes) {...kf, 't': (kf['t'] as num) - t0},
  ];
  // reverseSegment recomputes its own relative timing from the original
  // (non-shifted) keyframes, so it must receive `keyframes`, not `segForward`.
  final segBackward = pingpong ? _reverseSegment(keyframes) : segForward;

  // A loop closes cleanly when the first and last value already match; if
  // not, the last keyframe has to be kept and the value snaps back to the
  // start ('cycle' behavior).
  final closed =
      pingpong || _jsonEquals(segForward.first['s'], segForward.last['s']);

  final out = <Map<String, dynamic>>[];
  var rep = 0;
  while (t0 + rep * period < end) {
    final segment = (pingpong && rep.isOdd) ? segBackward : segForward;
    for (var i = 0; i < segment.length - 1; i++) {
      final kf = segment[i];
      out.add({...kf, 't': t0 + rep * period + (kf['t'] as num)});
    }
    if (!closed) {
      final last = segment.last;
      out.add({...last, 't': t0 + (rep + 1) * period - loopGap});
    }
    rep += 1;
  }
  final lastSegment = (pingpong && rep.isOdd) ? segBackward : segForward;
  out.add({'t': t0 + rep * period, 's': lastSegment.last['s']});

  prop['k'] = out;
  return rep;
}

/// Bakes a `loopIn('cycle')` expression: tiles the segment shape backward
/// from its first keyframe down to [start] (`doc['ip']`), so the same shape
/// repeats before the authored start instead of holding a static value.
///
/// Each backward tile writes its own leading edge (so, unlike the forward
/// case, no extra keyframe is needed to close off the last tile — it's
/// already the array's first element, and `lottie` holds a property's value
/// for any time before its first keyframe). For `pingpong`, the tile
/// immediately before `t0` is the mirrored segment (its last value, at
/// `t0`, then matches the recorded segment's first value), alternating with
/// the plain forward shape further back — the same alternation
/// `_bakeCycleForward` does going forward, just phase-shifted by one since
/// tiling starts adjacent to `t0` instead of at it.
int _bakeBackwardCycle(
  Map<String, dynamic> prop,
  List<Map<String, dynamic>> keyframes,
  num t0,
  num period,
  num start, {
  required bool pingpong,
}) {
  final segForward = [
    for (final kf in keyframes) {...kf, 't': (kf['t'] as num) - t0},
  ];
  // reverseSegment recomputes its own relative timing from the original
  // (non-shifted) keyframes, so it must receive `keyframes`, not `segForward`.
  final segBackward = pingpong ? _reverseSegment(keyframes) : segForward;
  final closed =
      pingpong || _jsonEquals(segForward.first['s'], segForward.last['s']);

  final chunks = <List<Map<String, dynamic>>>[];
  var rep = 0;
  while (t0 - rep * period > start) {
    final segment = (pingpong && rep.isEven) ? segBackward : segForward;
    final leftEdge = t0 - (rep + 1) * period;
    final chunk = <Map<String, dynamic>>[
      for (var i = 0; i < segment.length - 1; i++)
        {...segment[i], 't': leftEdge + (segment[i]['t'] as num)},
    ];
    if (!closed) {
      chunk.add({...segment.last, 't': (t0 - rep * period) - loopGap});
    }
    chunks.add(chunk);
    rep += 1;
  }

  prop['k'] = [for (final chunk in chunks.reversed) ...chunk, ...keyframes];
  return rep;
}

/// Bakes `loopOut('offset')`: repeats the segment shape forward to [end],
/// like `'cycle'`, but each repetition's values are shifted by
/// `last - first` from the one before, so the property keeps trending
/// instead of snapping back to the start every period.
///
/// Every repetition connects to the next without a gap by construction —
/// tile `k`'s value at its own local end (`Vend + k*delta`) is exactly
/// tile `k+1`'s value at its local start (`Vstart + (k+1)*delta`), since
/// `Vend == Vstart + delta` — so unlike `'cycle'`, no seam/hold keyframe is
/// ever needed here.
int _bakeOffsetForward(
  Map<String, dynamic> prop,
  List<Map<String, dynamic>> keyframes,
  num t0,
  num period,
  num end,
) {
  final segForward = [
    for (final kf in keyframes) {...kf, 't': (kf['t'] as num) - t0},
  ];
  final delta = _delta(
    segForward.first['s'] as List,
    segForward.last['s'] as List,
  );

  final out = <Map<String, dynamic>>[];
  var rep = 0;
  while (t0 + rep * period < end) {
    for (var i = 0; i < segForward.length - 1; i++) {
      final kf = segForward[i];
      out.add({
        ...kf,
        't': t0 + rep * period + (kf['t'] as num),
        's': _offsetBy(kf['s'] as List, delta, rep),
      });
    }
    rep += 1;
  }
  // The trailing point closes off repetition `rep - 1` (the last one
  // actually written above), not `rep` itself, which was never started.
  out.add({
    't': t0 + rep * period,
    's': _offsetBy(segForward.last['s'] as List, delta, rep - 1),
  });

  prop['k'] = out;
  return rep;
}

/// Bakes `loopIn('offset')`: the backward-tiling counterpart of
/// [_bakeOffsetForward], continuing the same per-period value trend
/// backward from the first keyframe down to [start].
int _bakeOffsetBackward(
  Map<String, dynamic> prop,
  List<Map<String, dynamic>> keyframes,
  num t0,
  num period,
  num start,
) {
  final segForward = [
    for (final kf in keyframes) {...kf, 't': (kf['t'] as num) - t0},
  ];
  final delta = _delta(
    segForward.first['s'] as List,
    segForward.last['s'] as List,
  );

  final chunks = <List<Map<String, dynamic>>>[];
  var rep = 0;
  while (t0 - rep * period > start) {
    final leftEdge = t0 - (rep + 1) * period;
    final k = -(rep + 1);
    final chunk = <Map<String, dynamic>>[
      for (var i = 0; i < segForward.length - 1; i++)
        {
          ...segForward[i],
          't': leftEdge + (segForward[i]['t'] as num),
          's': _offsetBy(segForward[i]['s'] as List, delta, k),
        },
    ];
    chunks.add(chunk);
    rep += 1;
  }

  prop['k'] = [for (final chunk in chunks.reversed) ...chunk, ...keyframes];
  return rep;
}

/// Bakes `loopOut('continue')`: rather than repeating any keyframes,
/// extrapolates a single straight segment past the last keyframe at the
/// rate of change of the original segment's last leg (a linear
/// approximation of AE's velocity-continuation behavior, which can factor
/// in that leg's own easing curve — evaluating that precisely isn't worth
/// the risk of getting the bezier math wrong for a rarely-used mode).
int _bakeContinueForward(
  Map<String, dynamic> prop,
  List<Map<String, dynamic>> keyframes,
  num end,
) {
  final last = keyframes.last;
  final lastTime = last['t'] as num;
  if (end <= lastTime) return 0;
  final prev = keyframes[keyframes.length - 2];
  final dt = lastTime - (prev['t'] as num);
  if (dt <= 0) return 0;
  final velocity = _delta(
    prev['s'] as List,
    last['s'] as List,
  ).map((d) => d / dt).toList();

  prop['k'] = [
    ...keyframes.sublist(0, keyframes.length - 1),
    {...last, 'o': _linearOut},
    {
      't': end,
      's': _offsetBy(last['s'] as List, velocity, end - lastTime),
      'i': _linearIn,
    },
  ];
  return 1;
}

/// Bakes `loopIn('continue')`: the backward counterpart of
/// [_bakeContinueForward], extrapolating a single straight segment before
/// the first keyframe at that segment's own rate of change.
int _bakeContinueBackward(
  Map<String, dynamic> prop,
  List<Map<String, dynamic>> keyframes,
  num start,
) {
  final first = keyframes.first;
  final t0 = first['t'] as num;
  if (start >= t0) return 0;
  final second = keyframes[1];
  final dt = (second['t'] as num) - t0;
  if (dt <= 0) return 0;
  final velocity = _delta(
    first['s'] as List,
    second['s'] as List,
  ).map((d) => d / dt).toList();

  prop['k'] = [
    {
      't': start,
      's': _offsetBy(first['s'] as List, velocity, start - t0),
      'o': _linearOut,
    },
    {...first, 'i': _linearIn},
    ...keyframes.sublist(1),
  ];
  return 1;
}

/// Component-wise `end - start` for two same-length numeric value lists.
List<num> _delta(List<dynamic> start, List<dynamic> end) => [
  for (var i = 0; i < start.length; i++) (end[i] as num) - (start[i] as num),
];

/// `s + k * delta`, component-wise.
List<num> _offsetBy(List<dynamic> s, List<num> delta, num k) => [
  for (var i = 0; i < s.length; i++) (s[i] as num) + k * delta[i],
];

/// Reverses a keyframe segment for 'pingpong', with time made relative to
/// 0..period, easing mirrored, and spatial tangents swapped.
List<Map<String, dynamic>> _reverseSegment(
  List<Map<String, dynamic>> keyframes,
) {
  final n = keyframes.length;
  final t0 = keyframes.first['t'] as num;
  final period = (keyframes.last['t'] as num) - t0;
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < n; i++) {
    final src = keyframes[n - 1 - i];
    final kf = <String, dynamic>{
      't': period - ((src['t'] as num) - t0),
      's': src['s'],
    };
    final j = n - 2 - i;
    if (j >= 0) {
      // A keyframe missing 'i'/'o' (no easing recorded — effectively
      // linear) isn't something real AE exports normally do, but isn't
      // invalid either; fall back to the same linear default used
      // elsewhere in this file rather than crashing on the null cast.
      kf['o'] = _mirrorEasing(
        keyframes[j]['i'] as Map<String, dynamic>? ?? _linearIn,
      );
      kf['i'] = _mirrorEasing(
        keyframes[j]['o'] as Map<String, dynamic>? ?? _linearOut,
      );
      if (keyframes[j].containsKey('ti')) {
        kf['to'] = keyframes[j]['ti'];
        kf['ti'] = keyframes[j]['to'];
      }
    }
    out.add(kf);
  }
  return out;
}

/// Mirrors a bezier easing point along the time axis: f'(t) = 1 - f(1 - t),
/// i.e. every control value becomes `1 - value`.
Map<String, dynamic> _mirrorEasing(Map<String, dynamic> point) {
  return {'x': _flip(point['x']), 'y': _flip(point['y'])};
}

dynamic _flip(dynamic value) {
  if (value is List) {
    return [for (final v in value) 1 - (v as num)];
  }
  return 1 - (value as num);
}

bool _jsonEquals(dynamic a, dynamic b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}
