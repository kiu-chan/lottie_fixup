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

  /// Properties (never-keyframed or already-keyframed) with a non-loop
  /// expression that `fix` can bake — cross-layer links, `time`-based
  /// motion, `if`/`else`, `Math.*`, `random`/`wiggle`, etc. (see
  /// `bakePropertyExpressions`).
  final int propertyExpressionsToBake;

  /// Expressions found that `fix` will leave untouched: an unsupported loop
  /// mode/shape (e.g. a duration variant shorter than the keyframed
  /// segment, or an expression combining both `loopIn` and `loopOut`), a
  /// non-`wiggle()` expression on a shape path, or syntax this package's
  /// expression evaluator doesn't understand (nested comps, `effect(...)`,
  /// etc.).
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
