/// Bakes `loopOut()`/`loopIn()` expressions in a decoded Lottie document
/// into real keyframes.
///
/// After Effects only exports keyframes for one short cycle and lets the
/// `loopOut()`/`loopIn()` expression repeat it. The `lottie` Flutter package
/// does not run expressions, so outside the authored keyframe range the
/// property just freezes. This spreads the keyframes out for real, the same
/// way After Effects interprets those calls.
///
/// Supported: `loopOut('cycle' | 'pingpong')` and `loopIn('cycle')`.
/// Not supported (left untouched, reported via [BakeResult.skippedExpressions]):
/// `loopIn('pingpong')`, the `'offset'`/`'continue'` loop modes, and any
/// expression that calls both `loopIn` and `loopOut` on the same property.
library;

/// Gap (in frames) left between the end of one loop and the start of the
/// next, used for an open loop (`'cycle'` mode whose first and last value
/// differ) whose value must jump back to the start.
///
/// Must be tiny: the `lottie` package samples time-remap a fraction of a
/// frame short of the integer boundary (composition_layer.dart divides by
/// `durationFrames + 0.01`), landing roughly 2.8e-5 frame before the loop
/// point at minimum. A gap wider than that swallows the sample into the
/// jump segment and reads back an interpolated mid-jump value instead of the
/// real one, causing a one-frame glitch every loop. Do not widen this.
const double loopGap = 1e-5;

/// Matches a `loopIn(...)` or `loopOut(...)` call. Group 1 is `In`/`Out`;
/// group 2 is the loop mode argument (`cycle`, `pingpong`, `offset`,
/// `continue`), or absent when the call omits it — After Effects then
/// defaults to `'cycle'`.
final RegExp _loopCall = RegExp(r'''loop(In|Out)\s*\(\s*(?:['"](\w+)['"])?''');

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
  /// `loopIn` call, an unsupported loop mode, `loopIn('pingpong')`, or an
  /// expression combining both `loopIn` and `loopOut` — and were left as-is.
  final List<String> skippedExpressions;

  bool get changed => propertiesBaked > 0;
}

/// Walks [doc] and bakes every supported `loopOut`/`loopIn` expression
/// found, mutating [doc] in place. Safe to call repeatedly: a document with
/// no more expressions is a no-op.
BakeResult bakeLoopExpressions(Map<String, dynamic> doc) {
  final start = (doc['ip'] as num?) ?? 0;
  final end = doc['op'] as num;
  final loopCounts = <int>[];
  final skipped = <String>[];
  _walk(doc, start, end, loopCounts, skipped);
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
  List<int> loopCounts,
  List<String> skipped,
) {
  if (node is Map<String, dynamic>) {
    final expr = node['x'];
    final k = node['k'];
    if (expr is String && k is List) {
      final matches = _loopCall.allMatches(expr).toList();
      // Anything other than exactly one loopIn/loopOut call — none (not a
      // loop expression at all), or two (loopIn and loopOut combined on the
      // same property) — isn't safe to bake automatically.
      if (matches.length == 1) {
        final forward = matches.single.group(1) == 'Out';
        final mode = matches.single.group(2) ?? 'cycle';
        final supported = mode == 'cycle' || (forward && mode == 'pingpong');
        if (supported) {
          loopCounts.add(
            _bakeProperty(
              node,
              start,
              end,
              forward: forward,
              pingpong: mode == 'pingpong',
            ),
          );
        } else {
          skipped.add(expr);
        }
      } else {
        skipped.add(expr);
      }
    }
    for (final value in node.values.toList()) {
      _walk(value, start, end, loopCounts, skipped);
    }
  } else if (node is List) {
    for (final value in node) {
      _walk(value, start, end, loopCounts, skipped);
    }
  }
}

/// Bakes one animated property with a `loopOut`/`loopIn` expression.
/// Returns the number of extra loops written.
int _bakeProperty(
  Map<String, dynamic> prop,
  num start,
  num end, {
  required bool forward,
  required bool pingpong,
}) {
  final keyframes = (prop['k'] as List).cast<Map<String, dynamic>>();
  prop.remove('x');

  final t0 = keyframes.first['t'] as num;
  final period = (keyframes.last['t'] as num) - t0;
  if (period <= 0) return 0;

  if (!forward) {
    return _bakeBackwardCycle(prop, keyframes, t0, period, start);
  }

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
/// for any time before its first keyframe). `loopIn('pingpong')` isn't
/// supported: the mirrored/alternating segment used for `loopOut('pingpong')`
/// doesn't carry over cleanly to tiling backward, so that case is reported
/// via [BakeResult.skippedExpressions] instead of reaching this function.
int _bakeBackwardCycle(
  Map<String, dynamic> prop,
  List<Map<String, dynamic>> keyframes,
  num t0,
  num period,
  num start,
) {
  final segForward = [
    for (final kf in keyframes) {...kf, 't': (kf['t'] as num) - t0},
  ];
  final closed = _jsonEquals(segForward.first['s'], segForward.last['s']);

  final chunks = <List<Map<String, dynamic>>>[];
  var rep = 0;
  while (t0 - rep * period > start) {
    final leftEdge = t0 - (rep + 1) * period;
    final chunk = <Map<String, dynamic>>[
      for (var i = 0; i < segForward.length - 1; i++)
        {...segForward[i], 't': leftEdge + (segForward[i]['t'] as num)},
    ];
    if (!closed) {
      chunk.add({...segForward.last, 't': (t0 - rep * period) - loopGap});
    }
    chunks.add(chunk);
    rep += 1;
  }

  prop['k'] = [for (final chunk in chunks.reversed) ...chunk, ...keyframes];
  return rep;
}

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
      kf['o'] = _mirrorEasing(keyframes[j]['i'] as Map<String, dynamic>);
      kf['i'] = _mirrorEasing(keyframes[j]['o'] as Map<String, dynamic>);
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
