/// Read-only inspection of a Lottie document, without mutating it.
library;

import 'dart:convert';

import 'bake_loop_expressions.dart';

/// Report of issues found in a Lottie document, without fixing anything.
class Diagnosis {
  const Diagnosis({
    required this.audioLayers,
    required this.emptyPrecomps,
    required this.loopExpressionsToBake,
    required this.unsupportedExpressions,
  });

  /// Audio layers (`ty: 6`) across the root and all precomp assets. These
  /// crash the `lottie` Flutter package's layer parser.
  final int audioLayers;

  /// Precomp assets with an empty `layers` list.
  final int emptyPrecomps;

  /// Animated properties with a `loopOut`/`loopIn` expression that `fix`
  /// can bake into real keyframes.
  final int loopExpressionsToBake;

  /// Expressions found that `fix` will leave untouched: anything other than
  /// a supported `loopOut`/`loopIn` call (e.g. `wiggle`, `valueAtTime`), an
  /// unsupported loop mode (`'offset'`, `'continue'`), `loopIn('pingpong')`,
  /// or an expression combining both `loopIn` and `loopOut`.
  final List<String> unsupportedExpressions;

  bool get hasIssues =>
      audioLayers > 0 ||
      emptyPrecomps > 0 ||
      loopExpressionsToBake > 0 ||
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

  // bakeLoopExpressions mutates its argument, so run it on a fresh decode of
  // rawJson rather than the caller's doc, to reuse its detection logic
  // without actually changing anything the caller can see.
  final bake = bakeLoopExpressions(jsonDecode(rawJson) as Map<String, dynamic>);

  return Diagnosis(
    audioLayers: audioLayers,
    emptyPrecomps: emptyPrecomps,
    loopExpressionsToBake: bake.propertiesBaked,
    unsupportedExpressions: bake.skippedExpressions,
  );
}
