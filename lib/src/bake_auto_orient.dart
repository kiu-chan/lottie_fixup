/// Bakes After Effects' Auto-Orient ("Orient Along Path", `"ao": 1`) into
/// plain rotation keyframes, so `lottie` never runs its own auto-orient code.
///
/// `lottie` does implement auto-orient, but its transform matrix
/// (`TransformKeyframeAnimation.getMatrix`, still the case in 3.5.1) gets it
/// wrong twice over:
///
/// - It converts the direction of travel to degrees, then passes that number
///   to `Matrix4.rotateZ`, which takes radians. A layer that should bank 60°
///   along a curved motion path is drawn turning 60 radians — nearly 10 full
///   spins — with an extra jolt wherever its heading crosses ±180°.
/// - While `ao` is on, it ignores the layer's own rotation (`r`) entirely,
///   where After Effects adds the two together.
///
/// This works out what After Effects shows instead, writes it into `r`, and
/// turns `ao` off: the tangent of the spatial motion path at the layer's
/// position along it — honoring each segment's temporal easing and the same
/// arc-length mapping `lottie` uses to move the layer, and never flipping
/// around when easing overshoots and comes back — plus the layer's own
/// rotation. A position with separated dimensions (`"s": true`) has no
/// spatial path, so it's oriented along its actual velocity instead.
///
/// The result is sampled once per frame as linear keyframes, dropping any
/// sample a straight line between its neighbors already matches within
/// 0.01°, with a near-instant snap (`loopGap` wide) where the motion turns a
/// sharp corner. While the layer pauses — or its position jumps, like at the
/// seam `bakeLoopExpressions` leaves in an open `'cycle'` loop — it keeps
/// facing its last heading. A layer that never actually moves just has `ao`
/// turned off, keeping its own rotation.
///
/// Not supported (left untouched, reported via
/// [AutoOrientBakeResult.skippedLayers]): 3D layers (`"ddd": 1`), which After
/// Effects orients in 3D, and a layer whose position or rotation still
/// carries an expression — its direction of travel would come from that
/// expression, which `lottie` never runs.
library;

import 'dart:math' as math;

import 'bake_loop_expressions.dart' show loopGap;

/// Result of baking auto-orient in one document.
class AutoOrientBakeResult {
  const AutoOrientBakeResult({
    required this.layersBaked,
    required this.skippedLayers,
  });

  /// Auto-oriented layers that had `ao` turned off, with their orientation
  /// baked into rotation keyframes (or nothing to bake, for a layer that
  /// never moves).
  final int layersBaked;

  /// Auto-oriented layers left as-is, each as
  /// `"<layer descriptor>: <reason>"`: 3D layers, or a position/rotation
  /// still carrying an expression.
  final List<String> skippedLayers;

  bool get changed => layersBaked > 0;
}

/// Degrees within which two rotations count as the same: the threshold for a
/// corner snap, and for dropping a sample its neighbors already imply.
const double _toleranceDegrees = 0.01;

/// Below this length a direction vector counts as no direction at all.
const double _epsilon = 1e-9;

/// A segment shorter than this many frames is a value jumping, not moving —
/// e.g. the `loopGap`-wide seam of a baked open `'cycle'` loop — so nothing
/// turns to face it.
const double _jumpFrames = 1e-3;

/// Walks [doc] and bakes auto-orient on every layer that has it, mutating
/// [doc] in place. Meant to run after the expression bakes, so a position
/// they baked is what the layer gets oriented along. Safe to call
/// repeatedly: a baked layer no longer has `ao` on.
AutoOrientBakeResult bakeAutoOrient(Map<String, dynamic> doc) {
  var baked = 0;
  final skipped = <String>[];

  void walkLayers(List<dynamic> layers) {
    for (final layer in layers) {
      if (layer is! Map<String, dynamic> || layer['ao'] != 1) continue;
      final ks = layer['ks'];
      // A layer with no transform block is sanitizeCrashingLayers' to report
      // (layersMissingTransform); there's nothing here to orient.
      if (ks is! Map<String, dynamic>) continue;
      final problem = _bakeLayer(layer, ks);
      if (problem == null) {
        baked++;
      } else {
        skipped.add('ty=${layer['ty']} nm=${layer['nm']}: $problem');
      }
    }
  }

  walkLayers((doc['layers'] as List?) ?? const []);
  for (final asset in (doc['assets'] as List? ?? const [])) {
    if (asset is Map && asset['layers'] is List) {
      walkLayers(asset['layers'] as List);
    }
  }

  return AutoOrientBakeResult(layersBaked: baked, skippedLayers: skipped);
}

/// Bakes one auto-oriented layer and returns null — or, leaving the layer
/// untouched, why it can't be baked.
String? _bakeLayer(Map<String, dynamic> layer, Map<String, dynamic> ks) {
  if (layer['ddd'] == 1) {
    return '3D layer, which After Effects orients in 3D';
  }
  // `lottie` reads rotation from `rz` as well as `r`; use whichever is there.
  final rotationKey = !ks.containsKey('r') && ks.containsKey('rz') ? 'rz' : 'r';
  final position = ks['p'];
  final rotation = ks[rotationKey];
  if (_hasExpression(position) || _hasExpression(rotation)) {
    return 'position or rotation still has an unbaked expression';
  }

  final List<(double, double)>? samples;
  try {
    final motion = _Motion.parse(position);
    samples = motion == null
        ? null
        : _sample(motion, _Curve.parse(rotation, 'rotation'));
  } catch (_) {
    // A value shaped some way this pass doesn't expect — the same boundary
    // the expression bakes draw: report this one layer, never crash the
    // rest of the document over it.
    return 'position or rotation has an unrecognized shape';
  }

  if (samples != null) {
    final prop = rotation is Map<String, dynamic>
        ? rotation
        : <String, dynamic>{};
    _writeRotation(prop, samples);
    ks[rotationKey] = prop;
  }
  layer['ao'] = 0;
  return null;
}

/// Whether [prop] still carries an expression — directly, or on either axis
/// of a position with separated dimensions.
bool _hasExpression(dynamic prop) {
  if (prop is! Map) return false;
  if (prop['x'] is String) return true;
  return prop['s'] == true &&
      (_hasExpression(prop['x']) || _hasExpression(prop['y']));
}

/// Samples the layer's total rotation — heading plus its own rotation — at
/// every frame and every keyframe of either, or returns null if the layer
/// never actually moves.
List<(double, double)>? _sample(_Motion motion, _Curve rotation) {
  final keyTimes = {...motion.keyTimes, ...rotation.keyTimes};
  final first = keyTimes.reduce(math.min);
  final last = keyTimes.reduce(math.max);
  final times = {
    ...keyTimes,
    for (var f = first.ceil(); f <= last.floor(); f++) f.toDouble(),
  }.toList()..sort();

  // (time, heading in degrees — null while not moving — own rotation)
  final raw = <(double, double?, double)>[];
  double? lastHeading;
  for (final t in times) {
    final heading = _degrees(motion.direction(t));
    if (keyTimes.contains(t)) {
      // Coming out of a pause, the heading "before" is wherever the layer
      // was last pointing.
      final headingBefore =
          _degrees(motion.direction(t, before: true)) ?? lastHeading;
      final rotationBefore = rotation.at(t, before: true);
      final corner =
          heading != null &&
          headingBefore != null &&
          _wrap(heading - headingBefore).abs() > _toleranceDegrees;
      final jump = (rotation.at(t) - rotationBefore).abs() > _toleranceDegrees;
      if ((corner || jump) && (raw.isEmpty || t - loopGap > raw.last.$1)) {
        // Snap, rather than turning gradually across the whole frame before.
        raw.add((t - loopGap, headingBefore, rotationBefore));
      }
      raw.add((t, heading ?? headingBefore, rotation.at(t)));
    } else {
      raw.add((t, heading, rotation.at(t)));
    }
    lastHeading = raw.last.$2 ?? lastHeading;
  }

  final firstHeading = raw.map((s) => s.$2).nonNulls.firstOrNull;
  if (firstHeading == null) return null;

  final samples = <(double, double)>[];
  var heading = firstHeading;
  for (final (t, rawHeading, ownRotation) in raw) {
    if (rawHeading != null) {
      // Unwrap into the half-turn nearest the previous sample, so playback
      // from e.g. 179° to -179° turns 2°, not 358° the long way round.
      heading = rawHeading + 360 * ((heading - rawHeading) / 360).round();
    }
    // Before the layer first moves it's already facing its first heading;
    // while not moving it keeps facing its last one.
    samples.add((t, heading + ownRotation));
  }
  return samples;
}

double? _degrees(_Vec? direction) => direction == null
    ? null
    : math.atan2(direction.$2, direction.$1) * 180 / math.pi;

/// [degrees] folded into [-180, 180].
double _wrap(double degrees) => degrees - 360 * (degrees / 360).round();

/// Writes [samples] into the rotation property [prop], keeping its other
/// fields (e.g. `ix`): a static value if they never change, otherwise linear
/// keyframes.
void _writeRotation(Map<String, dynamic> prop, List<(double, double)> samples) {
  final kept = _thin(samples);
  final start = kept.first.$2;
  if (kept.every((s) => (s.$2 - start).abs() <= _toleranceDegrees)) {
    prop['a'] = 0;
    prop['k'] = _rounded(start);
    return;
  }
  prop['a'] = 1;
  prop['k'] = [
    for (final (t, value) in kept)
      <String, dynamic>{
        't': t == t.roundToDouble() ? t.round() : t,
        's': [_rounded(value)],
      },
  ];
}

double _rounded(double degrees) => (degrees * 1000).round() / 1000;

/// Drops every sample that linear interpolation between the samples kept
/// around it already reproduces within the tolerance.
///
/// Single pass: from the last kept sample, tracks the range of slopes that
/// still pass within tolerance of every sample since, and keeps a sample
/// only once the line on to the next one falls outside that range.
List<(double, double)> _thin(List<(double, double)> samples) {
  if (samples.length <= 2) return samples;
  final kept = [samples.first];
  var (anchorTime, anchorValue) = samples.first;
  var low = double.negativeInfinity;
  var high = double.infinity;
  for (var j = 1; j < samples.length; j++) {
    final (t, value) = samples[j];
    final slope = (value - anchorValue) / (t - anchorTime);
    if (slope < low || slope > high) {
      final previous = samples[j - 1];
      kept.add(previous);
      (anchorTime, anchorValue) = previous;
      low = double.negativeInfinity;
      high = double.infinity;
    }
    final dt = t - anchorTime;
    low = math.max(low, (value - _toleranceDegrees - anchorValue) / dt);
    high = math.min(high, (value + _toleranceDegrees - anchorValue) / dt);
  }
  kept.add(samples.last);
  return kept;
}

typedef _Vec = (double, double);

_Vec _minus(_Vec a, _Vec b) => (a.$1 - b.$1, a.$2 - b.$2);

_Vec _plus(_Vec a, _Vec b) => (a.$1 + b.$1, a.$2 + b.$2);

double _length(_Vec v) => math.sqrt(v.$1 * v.$1 + v.$2 * v.$2);

/// A number, or the first element of a list of numbers — the two ways a
/// Lottie file stores a scalar.
double _number(dynamic v, String what) {
  if (v is num) return v.toDouble();
  if (v is List && v.isNotEmpty && v.first is num) {
    return (v.first as num).toDouble();
  }
  throw FormatException(what);
}

/// The x/y of a point stored as a list (any z is ignored, as in `lottie`).
_Vec _point(dynamic v, String what) {
  if (v is List && v.length >= 2 && v[0] is num && v[1] is num) {
    return ((v[0] as num).toDouble(), (v[1] as num).toDouble());
  }
  throw FormatException(what);
}

/// A layer's position over time, as far as auto-orient cares: which way the
/// layer is heading.
sealed class _Motion {
  /// Parses `ks.p`, or returns null for a position that isn't keyframed.
  static _Motion? parse(dynamic position) {
    if (position is! Map) return null;
    if (position['s'] == true) {
      final motion = _SeparatedMotion(
        _Curve.parse(position['x'], 'position'),
        _Curve.parse(position['y'], 'position'),
      );
      return motion.keyTimes.isEmpty ? null : motion;
    }
    final k = position['k'];
    if (k is! List || k.isEmpty || k.first is! Map) return null;
    final segments = _buildSegments<_PathSegment>(
      k,
      'position',
      (keyframe, t0, t1, from, to) => _PathSegment(
        t0,
        t1,
        _Easing.of(keyframe),
        hold: keyframe['h'] == 1,
        p0: _point(from, 'position'),
        p3: _point(to, 'position'),
        outHandle: keyframe['to'] == null
            ? null
            : _point(keyframe['to'], 'position'),
        inHandle: keyframe['ti'] == null
            ? null
            : _point(keyframe['ti'], 'position'),
      ),
    );
    return segments.isEmpty ? null : _PathMotion(segments);
  }

  /// Every keyframe time, in order.
  List<double> get keyTimes;

  /// Which way the layer is heading at [t], or null while it isn't moving.
  /// With [before], the heading arriving at [t] rather than leaving it —
  /// only different at a keyframe.
  _Vec? direction(double t, {bool before = false});
}

/// A position keyframed as a spatial motion path.
final class _PathMotion extends _Motion {
  _PathMotion(this._segments);

  final List<_PathSegment> _segments;

  @override
  List<double> get keyTimes => [
    for (final segment in _segments) segment.t0,
    _segments.last.t1,
  ];

  @override
  _Vec? direction(double t, {bool before = false}) {
    final segment = _segmentAt(_segments, t, before: before);
    return segment?.directionAt(segment.progress(t));
  }
}

/// A position with separated dimensions (`"s": true`): two independent
/// curves and no spatial path, so the layer heads along its velocity.
final class _SeparatedMotion extends _Motion {
  _SeparatedMotion(this._x, this._y);

  final _Curve _x;
  final _Curve _y;

  @override
  List<double> get keyTimes =>
      {..._x.keyTimes, ..._y.keyTimes}.toList()..sort();

  @override
  _Vec? direction(double t, {bool before = false}) {
    final velocity = (_x.slope(t, before: before), _y.slope(t, before: before));
    return _length(velocity) > _epsilon ? velocity : null;
  }
}

/// A scalar property over time: rotation, or one axis of a position with
/// separated dimensions.
class _Curve {
  _Curve._(this._segments, this._constant);

  static _Curve parse(dynamic prop, String what) {
    if (prop == null) return _Curve._(const [], 0);
    if (prop is! Map) throw FormatException(what);
    final k = prop['k'];
    if (k is List && k.isNotEmpty && k.first is Map) {
      final segments = _buildSegments<_ValueSegment>(
        k,
        what,
        (keyframe, t0, t1, from, to) => _ValueSegment(
          t0,
          t1,
          _Easing.of(keyframe),
          hold: keyframe['h'] == 1,
          from: _number(from, what),
          to: _number(to, what),
        ),
      );
      final firstValue = (k.first as Map)['s'];
      // `lottie` treats a keyframe with no value at all (e.g. `"k": [{}]`) as
      // 0 rather than failing.
      return _Curve._(
        segments,
        firstValue == null ? 0.0 : _number(firstValue, what),
      );
    }
    return _Curve._(const [], k == null ? 0.0 : _number(k, what));
  }

  final List<_ValueSegment> _segments;
  final double _constant;

  /// Time step, in frames, over which [slope] is measured.
  static const double _slopeStep = 1e-3;

  List<double> get keyTimes => _segments.isEmpty
      ? const []
      : [for (final segment in _segments) segment.t0, _segments.last.t1];

  /// Value at [t]; with [before], the value arriving at [t] — only different
  /// where a hold keyframe ends.
  double at(double t, {bool before = false}) {
    if (_segments.isEmpty) return _constant;
    final segment = _segmentAt(_segments, t, before: before);
    if (segment != null) return segment.valueAt(t);
    return t <= _segments.first.t0 ? _segments.first.from : _segments.last.to;
  }

  /// Rate of change at [t], per frame, measured within the one segment in
  /// effect (see [at] for [before]) so it never spans a keyframe: 0 during a
  /// hold, a jump, or outside the keyframed range.
  double slope(double t, {bool before = false}) {
    final segment = _segmentAt(_segments, t, before: before);
    if (segment == null || segment.hold || segment.isJump) return 0;
    final from = math.max(segment.t0, t - _slopeStep);
    final to = math.min(segment.t1, t + _slopeStep);
    return (segment.valueAt(to) - segment.valueAt(from)) / (to - from);
  }
}

/// One stretch of a keyframed property, from a keyframe to the next.
abstract class _Segment {
  _Segment(this.t0, this.t1, this.easing, {required this.hold});

  final double t0;
  final double t1;
  final _Easing? easing;

  /// A hold keyframe (`"h": 1`): the value doesn't change until [t1].
  final bool hold;

  /// Too short to be motion: see [_jumpFrames].
  bool get isJump => t1 - t0 < _jumpFrames;

  /// Whether this is the segment in effect at [t]: the one leaving [t], or
  /// with [before], the one arriving at it.
  bool covers(double t, {required bool before}) =>
      before ? t > t0 && t <= t1 : t >= t0 && t < t1;

  /// Eased progress through this segment at [t]: 0 at [t0], 1 at [t1] — or
  /// briefly past either, for easing that overshoots.
  double progress(double t) {
    final linear = t1 > t0
        ? ((t - t0) / (t1 - t0)).clamp(0.0, 1.0).toDouble()
        : 1.0;
    return easing?.transform(linear) ?? linear;
  }
}

S? _segmentAt<S extends _Segment>(
  List<S> segments,
  double t, {
  required bool before,
}) {
  for (final segment in segments) {
    if (segment.covers(t, before: before)) return segment;
  }
  return null;
}

/// One segment per consecutive pair of [keyframes], paired the way `lottie`
/// pairs them: a keyframe without an end value `e` ends at the next one's
/// `s`.
List<S> _buildSegments<S extends _Segment>(
  List<dynamic> keyframes,
  String what,
  S Function(
    Map<dynamic, dynamic> keyframe,
    double t0,
    double t1,
    dynamic from,
    dynamic to,
  )
  create,
) {
  final segments = <S>[];
  for (var i = 0; i < keyframes.length - 1; i++) {
    final keyframe = keyframes[i];
    final next = keyframes[i + 1];
    if (keyframe is! Map || next is! Map) throw FormatException(what);
    final from = keyframe['s'];
    final to = keyframe['e'] ?? next['s'];
    if (from == null || to == null) continue;
    segments.add(
      create(
        keyframe,
        _number(keyframe['t'], what),
        _number(next['t'], what),
        from,
        to,
      ),
    );
  }
  return segments;
}

/// A value segment of a scalar property.
class _ValueSegment extends _Segment {
  _ValueSegment(
    super.t0,
    super.t1,
    super.easing, {
    required super.hold,
    required this.from,
    required this.to,
  });

  final double from;
  final double to;

  /// Value at [t], clamped to this segment.
  double valueAt(double t) => hold ? from : from + (to - from) * progress(t);
}

/// One stretch of a spatial motion path: a straight line, or a cubic bezier
/// through the keyframe's spatial handles (`to`/`ti`).
class _PathSegment extends _Segment {
  _PathSegment(
    super.t0,
    super.t1,
    super.easing, {
    required super.hold,
    required this.p0,
    required this.p3,
    required _Vec? outHandle,
    required _Vec? inHandle,
  }) : // The same rule `lottie` builds its path with (Utils.createPath): a
       // curve only when both handles are present and either has a length.
       _curved =
           outHandle != null &&
           inHandle != null &&
           (_length(outHandle) != 0 || _length(inHandle) != 0),
       c1 = _plus(p0, outHandle ?? (0, 0)),
       c2 = _plus(p3, inHandle ?? (0, 0));

  final _Vec p0;
  final _Vec c1;
  final _Vec c2;
  final _Vec p3;
  final bool _curved;

  static const int _arcSteps = 256;

  /// Cumulative curve length at each of [_arcSteps] even steps of the bezier
  /// parameter.
  late final List<double> _arcLengths = _measure();

  /// Heading at eased [progress] through this segment, or null if the layer
  /// doesn't move along it.
  _Vec? directionAt(double progress) {
    // `lottie` only builds a path between two different values
    // (PathKeyframe); a hold or a jump isn't motion to face either.
    if (hold || isJump || p0 == p3) return null;
    if (!_curved) return _minus(p3, p0);
    final u = progress <= 0
        ? 0.0
        : progress >= 1
        ? 1.0
        : _parameterAt(progress);
    final tangent = _derivative(u);
    if (_length(tangent) > _epsilon) return tangent;
    // A zero-length handle leaves the curve no derivative at that end, but
    // the tangent approaching it still has a direction: toward the nearest
    // control point that isn't sitting on the end point.
    final fallbacks = u < 0.5
        ? [_minus(c2, p0), _minus(p3, p0)]
        : [_minus(p3, c1), _minus(p3, p0)];
    for (final fallback in fallbacks) {
      if (_length(fallback) > _epsilon) return fallback;
    }
    return null;
  }

  _Vec _pointAt(double u) {
    final m = 1 - u;
    final a = m * m * m;
    final b = 3 * m * m * u;
    final c = 3 * m * u * u;
    final d = u * u * u;
    return (
      a * p0.$1 + b * c1.$1 + c * c2.$1 + d * p3.$1,
      a * p0.$2 + b * c1.$2 + c * c2.$2 + d * p3.$2,
    );
  }

  _Vec _derivative(double u) {
    final m = 1 - u;
    final a = 3 * m * m;
    final b = 6 * m * u;
    final c = 3 * u * u;
    return (
      a * (c1.$1 - p0.$1) + b * (c2.$1 - c1.$1) + c * (p3.$1 - c2.$1),
      a * (c1.$2 - p0.$2) + b * (c2.$2 - c1.$2) + c * (p3.$2 - c2.$2),
    );
  }

  List<double> _measure() {
    final lengths = List.filled(_arcSteps + 1, 0.0);
    var previous = p0;
    for (var i = 1; i <= _arcSteps; i++) {
      final point = _pointAt(i / _arcSteps);
      lengths[i] = lengths[i - 1] + _length(_minus(point, previous));
      previous = point;
    }
    return lengths;
  }

  /// Bezier parameter at [fraction] of the way along the curve by length:
  /// `lottie`, like After Effects, moves a layer along its motion path by
  /// distance travelled, not by the raw bezier parameter.
  double _parameterAt(double fraction) {
    final lengths = _arcLengths;
    final target = fraction * lengths.last;
    var lo = 0;
    var hi = _arcSteps;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (lengths[mid] < target) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = lengths[hi] - lengths[lo];
    final within = span > 0 ? (target - lengths[lo]) / span : 0.0;
    return (lo + within) / _arcSteps;
  }
}

/// A segment's temporal easing: the cubic bezier through its keyframe's `o`
/// (departure) and `i` (arrival) handles.
class _Easing {
  _Easing(double x1, double y1, double x2, double y2)
    // y clamped like `lottie`'s keyframe parser does; x kept within [0, 1] so
    // the curve never doubles back on itself, which is what lets
    // [transform] bisect for it.
    : _x1 = x1.clamp(0.0, 1.0).toDouble(),
      _y1 = y1.clamp(-100.0, 100.0).toDouble(),
      _x2 = x2.clamp(0.0, 1.0).toDouble(),
      _y2 = y2.clamp(-100.0, 100.0).toDouble();

  /// Easing of the segment leaving [keyframe], or null for linear.
  static _Easing? of(Map<dynamic, dynamic> keyframe) {
    final out = keyframe['o'];
    final into = keyframe['i'];
    if (out is! Map || into is! Map) return null;
    // A missing handle coordinate reads as 0, as in `lottie`.
    double handle(dynamic v) => v == null ? 0 : _number(v, 'easing');
    return _Easing(
      handle(out['x']),
      handle(out['y']),
      handle(into['x']),
      handle(into['y']),
    );
  }

  final double _x1;
  final double _y1;
  final double _x2;
  final double _y2;

  /// Eased progress at linear progress [x], in [0, 1].
  double transform(double x) {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 50; i++) {
      final mid = (lo + hi) / 2;
      if (_cubic(_x1, _x2, mid) < x) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return _cubic(_y1, _y2, (lo + hi) / 2);
  }

  /// One coordinate of the bezier from 0 through [a] and [b] to 1.
  static double _cubic(double a, double b, double s) {
    final m = 1 - s;
    return 3 * m * m * s * a + 3 * m * s * s * b + s * s * s;
  }
}
