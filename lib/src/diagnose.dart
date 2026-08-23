/// Read-only inspection of a Lottie document, without mutating it.
library;

import 'dart:convert';

import 'bake_loop_expressions.dart';
import 'bake_options.dart';
import 'bake_property_expressions.dart';
import 'sanitize_crashing_layers.dart';

/// Report of issues found in a Lottie document, without fixing anything.
class Diagnosis {
  const Diagnosis({
    required this.audioLayers,
    required this.emptyPrecomps,
    required this.loopExpressionsToBake,
    required this.propertyExpressionsToBake,
    required this.unsupportedExpressions,
    this.sanitize = const SanitizeResult(
      audioLayersRemoved: 0,
      emptyPrecompsRemoved: 0,
      unreferencedAssetsRemoved: 0,
      layersMissingTransform: [],
    ),
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

  /// Structural crash risks found by `sanitizeCrashingLayers` — layers,
  /// assets, masks, and shape content shaped in a way that crashes
  /// `lottie`'s parser or render-tree builder — beyond the audio-layer/
  /// empty-precomp counts already summarized in [audioLayers]/
  /// [emptyPrecomps] above. See `SanitizeResult`'s fields for what each one
  /// means and whether `fix` can repair it automatically or only flag it.
  /// Computed on its own fresh decode, independent of the bake passes
  /// above: removing a structurally broken layer here never changes
  /// [loopExpressionsToBake]/[propertyExpressionsToBake]/
  /// [unsupportedExpressions], even though `fix` itself does run sanitize
  /// before baking.
  final SanitizeResult sanitize;

  bool get hasIssues =>
      audioLayers > 0 ||
      emptyPrecomps > 0 ||
      loopExpressionsToBake > 0 ||
      propertyExpressionsToBake > 0 ||
      unsupportedExpressions.isNotEmpty ||
      sanitize.changed ||
      sanitize.layersMissingTransform.isNotEmpty ||
      sanitize.propertiesWithEmptyKeyframes.isNotEmpty;
}

/// Inspects a decoded Lottie [doc] (and its [rawJson] source) without
/// changing anything. Pass the same [options] you intend to call `fix` with
/// so this reports exactly what that call would (or wouldn't) bake — see
/// [BakeOptions].
Diagnosis diagnose(
  String rawJson,
  Map<String, dynamic> doc, {
  BakeOptions options = const BakeOptions(),
}) {
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

  // sanitizeCrashingLayers/bakeLoopExpressions/bakePropertyExpressions all
  // mutate their argument, so each runs on a fresh decode of rawJson rather
  // than the caller's doc, to reuse their detection logic without actually
  // changing anything the caller can see. propertyBake runs second, on the
  // same freshly-baked doc as bake, so it only sees (and reports on)
  // expressions the loop bake left untouched — matching the order `fix`
  // itself runs the two passes in.
  //
  // sanitize deliberately gets its *own separate* fresh decode rather than
  // sharing freshDoc with the two bake calls: sanitizeCrashingLayers can
  // remove a whole layer (a precomp with a dangling refId, a text layer
  // missing its document data), and that layer could itself carry an
  // expression. Chaining sanitize -> bake on one shared decode (which would
  // more faithfully mirror fix()'s real pipeline order) would then make
  // loopExpressionsToBake/propertyExpressionsToBake/unsupportedExpressions
  // depend on sanitize's findings too, silently changing what those
  // already-public fields report for such a document. Keeping the decodes
  // independent means adding sanitize here never changes what this
  // function already reported for any existing field.
  final sanitize = sanitizeCrashingLayers(
    jsonDecode(rawJson) as Map<String, dynamic>,
  );

  final freshDoc = jsonDecode(rawJson) as Map<String, dynamic>;
  final bake = bakeLoopExpressions(freshDoc);
  final propertyBake = bakePropertyExpressions(freshDoc, options: options);

  return Diagnosis(
    audioLayers: audioLayers,
    emptyPrecomps: emptyPrecomps,
    loopExpressionsToBake: bake.propertiesBaked,
    propertyExpressionsToBake: propertyBake.propertiesBaked,
    unsupportedExpressions: propertyBake.skippedExpressions,
    sanitize: sanitize,
  );
}
