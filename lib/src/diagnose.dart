/// Read-only inspection of a Lottie document, without mutating it.
library;

import 'dart:convert';

import 'bake_loop_expressions.dart';
import 'bake_property_expressions.dart';

/// Report of issues found in a Lottie document, without fixing anything.
class Diagnosis {
  const Diagnosis({
    required this.audioLayers,
    required this.emptyPrecomps,
    required this.loopExpressionsToBake,
    required this.propertyExpressionsToBake,
    required this.unsupportedExpressions,
  });

  /// Audio layers (`ty: 6`) across the root and all precomp assets. These
  /// crash the `lottie` Flutter package's layer parser.
  final int audioLayers;

  /// Precomp assets with an empty `layers` list.
  final int emptyPrecomps;

  /// Animated properties with a `loopOut`/`loopIn`/`loopOutDuration`/
  /// `loopInDuration` expression that `fix` can bake into real keyframes.
  final int loopExpressionsToBake;

  /// Never-keyframed properties with a cross-layer link, `time`-based, or
  /// `random`/`wiggle` expression that `fix` can bake (see
  /// `bakePropertyExpressions`).
  final int propertyExpressionsToBake;

  /// Expressions found that `fix` will leave untouched: an unsupported loop
  /// mode/shape (e.g. a duration variant shorter than the keyframed
  /// segment, or an expression combining both `loopIn` and `loopOut`), an
  /// expression on an already-keyframed property that isn't a loop call
  /// (e.g. `wiggle` on a property with real keyframes, not just `"a": 0`),
  /// or syntax this package's expression evaluator doesn't understand
  /// (nested comps, `effect(...)`, etc.).
  final List<String> unsupportedExpressions;

  bool get hasIssues =>
      audioLayers > 0 ||
      emptyPrecomps > 0 ||
      loopExpressionsToBake > 0 ||
      propertyExpressionsToBake > 0 ||
      unsupportedExpressions.isNotEmpty;
}

/// Inspects a decoded Lottie [doc] (and its [rawJson] source) without
/// changing anything.
Diagnosis diagnose(String rawJson, Map<String, dynamic> doc) {
  var audioLayers = 0;
  var emptyPrecomps = 0;

  int countAudioLayers(List<dynamic> layers) =>
      layers.whereType<Map>().where((l) => l['ty'] == 6).length;

  audioLayers += countAudioLayers((doc['layers'] as List?) ?? const []);
  for (final asset in (doc['assets'] as List? ?? const [])) {
    if (asset is Map && asset['layers'] is List) {
      final layers = asset['layers'] as List;
      audioLayers += countAudioLayers(layers);
      if (layers.isEmpty) emptyPrecomps++;
    }
  }

  // bakeLoopExpressions/bakePropertyExpressions mutate their argument, so
  // run them on a fresh decode of rawJson rather than the caller's doc, to
  // reuse their detection logic without actually changing anything the
  // caller can see. propertyBake runs second, on the same freshly-baked
  // doc, so it only sees (and reports on) expressions the loop bake left
  // untouched — matching the order `fix` itself runs the two passes in.
  final freshDoc = jsonDecode(rawJson) as Map<String, dynamic>;
  final bake = bakeLoopExpressions(freshDoc);
  final propertyBake = bakePropertyExpressions(freshDoc);

  return Diagnosis(
    audioLayers: audioLayers,
    emptyPrecomps: emptyPrecomps,
    loopExpressionsToBake: bake.propertiesBaked,
    propertyExpressionsToBake: propertyBake.propertiesBaked,
    unsupportedExpressions: propertyBake.skippedExpressions,
  );
}
