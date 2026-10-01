/// Extends layers inside a time-remapped precomp that miss the start or end
/// of the range the remap plays, so a part meant to be on screen for the
/// whole cycle doesn't blink out once per loop.
///
/// A looping cycle (a walk, a wing beat...) is often a precomp whose time
/// remap (`tm`) runs from its first frame to its last and jumps back, over
/// and over. Every layer in it is meant to span the whole cycle, but one
/// nudged by a frame in After Effects — starting at frame 1 (`"ip": 1`)
/// while the remap jumps back to frame 0, or ending a frame early — is
/// invisible for that frame of every cycle: a limb vanishes and reappears
/// each loop, a flicker easy to miss while scrubbing in After Effects.
/// `lottie` maps a remap value of `v` seconds to
/// precomp frame `v * fr` (the root composition's `fr`), and hides a layer
/// outside `ip <= frame < op`.
///
/// A layer counts as meant to span the cycle when it lasts at least as long
/// as the remapped range (`op - ip`), give or take a frame, which excludes
/// parts that only show for a moment, like a blink. When such a layer misses at most one frame at
/// either end of the range, its `ip` is moved back to the start of the range
/// and/or its `op` past the end. Its keyframes are untouched, so in the frame
/// it gains it holds its first or last keyframe value. A larger gap could be
/// deliberate, so it's reported via [TimeRemapGapResult.skippedLayers]
/// instead.
///
/// Only precomps that every referencing layer plays through an animated time
/// remap are checked: one also played without a remap (or with a static one)
/// shows its layers' in and out points as authored, and moving them would
/// change that playback too. When several layers remap the same precomp, the
/// union of their ranges is used. Meant to run after the expression bakes,
/// so a `loopOut()` on the time remap is already real keyframes.
library;

import 'dart:math' as math;

/// Result of one [closeTimeRemapGaps] call.
class TimeRemapGapResult {
  const TimeRemapGapResult({
    required this.layersExtended,
    required this.skippedLayers,
  });

  /// Layers whose `ip` and/or `op` were moved to cover the whole remapped
  /// range of their precomp.
  final int layersExtended;

  /// Layers that span the cycle but miss more than one frame of it, left
  /// as-is, each as `"<layer descriptor>: <reason>"`.
  final List<String> skippedLayers;

  bool get changed => layersExtended > 0;
}

/// The widest gap, in frames, at either end of the remapped range that is
/// closed automatically — and how much shorter than the range a layer can be
/// and still count as spanning it.
const double _maxGapFrames = 1;

/// Frames within which a layer counts as covering an end of the range.
const double _epsilon = 1e-3;

/// Closes the time-remap gaps in [doc] in place, across every precomp asset.
/// Safe to call repeatedly: an extended layer covers its range afterwards.
TimeRemapGapResult closeTimeRemapGaps(Map<String, dynamic> doc) {
  final fr = doc['fr'];
  if (fr is! num || fr <= 0) {
    return const TimeRemapGapResult(layersExtended: 0, skippedLayers: []);
  }

  final precomps = <String, List<dynamic>>{};
  for (final asset in (doc['assets'] as List? ?? const [])) {
    if (asset is Map && asset['id'] is String && asset['layers'] is List) {
      precomps[asset['id'] as String] = asset['layers'] as List;
    }
  }

  // Union of the remapped ranges per precomp, in precomp frames; a precomp
  // also referenced without an animated remap goes in [notRemapped].
  final ranges = <String, (double, double)>{};
  final notRemapped = <String>{};

  void collect(List<dynamic> layers) {
    for (final l in layers) {
      if (l is! Map || l['ty'] != 0) continue;
      final id = l['refId'];
      if (id is! String || !precomps.containsKey(id)) continue;
      final range = _remappedRange(l['tm'], fr.toDouble());
      if (range == null) {
        notRemapped.add(id);
        continue;
      }
      final prev = ranges[id];
      ranges[id] = prev == null
          ? range
          : (math.min(prev.$1, range.$1), math.max(prev.$2, range.$2));
    }
  }

  collect((doc['layers'] as List?) ?? const []);
  for (final layers in precomps.values) {
    collect(layers);
  }

  var extended = 0;
  final skipped = <String>[];

  for (final MapEntry(key: id, value: (lo, hi)) in ranges.entries) {
    if (notRemapped.contains(id)) continue;
    for (final layer in precomps[id]!) {
      if (layer is! Map) continue;
      final ip = layer['ip'];
      final op = layer['op'];
      if (ip is! num || op is! num) continue;
      if (op - ip < hi - lo - _maxGapFrames) continue;

      final startGap = ip - lo;
      final endGap = hi - op;
      if (startGap <= _epsilon && endGap <= _epsilon) continue;
      if (startGap > _maxGapFrames || endGap > _maxGapFrames) {
        skipped.add(
          'ty=${layer['ty']} nm=${layer['nm']}: visible from frame '
          '${_frame(ip)} to ${_frame(op)}, but its precomp "$id" is '
          'remapped across frames ${_frame(lo)}-${_frame(hi)}',
        );
        continue;
      }
      if (startGap > _epsilon) layer['ip'] = lo.floor();
      if (endGap > _epsilon) layer['op'] = hi.floor() + 1;
      extended++;
    }
  }

  return TimeRemapGapResult(layersExtended: extended, skippedLayers: skipped);
}

/// The lowest and highest precomp frame an animated time remap [tm] plays,
/// or null for a missing or static remap, or one spanning under a frame —
/// which holds the precomp still rather than cycling through it.
(double, double)? _remappedRange(Object? tm, double fr) {
  if (tm is! Map || tm['a'] != 1 || tm['k'] is! List) return null;
  final values = <double>[];
  for (final k in tm['k'] as List) {
    if (k is! Map) continue;
    final s = k['s'];
    final v = s is List && s.isNotEmpty ? s.first : s;
    if (v is num) values.add(v * fr);
  }
  if (values.length < 2) return null;
  final lo = values.reduce(math.min);
  final hi = values.reduce(math.max);
  return hi - lo < 1 ? null : (lo, hi);
}

/// [frame] with at most two decimals and no trailing zeros.
String _frame(num frame) {
  final s = frame.toStringAsFixed(2);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}
