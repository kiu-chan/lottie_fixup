import 'bake_auto_orient.dart';
import 'bake_loop_expressions.dart';
import 'bake_options.dart';
import 'bake_property_expressions.dart';
import 'sanitize_crashing_layers.dart';
import 'strip_unsupported_effects.dart';

/// Combined result of running all fixes on a document.
class FixResult {
  const FixResult({
    required this.sanitize,
    required this.bake,
    required this.propertyBake,
    this.autoOrient = const AutoOrientBakeResult(
      layersBaked: 0,
      skippedLayers: [],
    ),
    this.effects = const EffectStripResult(
      effectsRemoved: 0,
      layersCleared: 0,
      effectNames: [],
    ),
  });

  final SanitizeResult sanitize;
  final BakeResult bake;
  final PropertyBakeResult propertyBake;
  final AutoOrientBakeResult autoOrient;
  final EffectStripResult effects;

  bool get changed =>
      sanitize.changed ||
      bake.changed ||
      propertyBake.changed ||
      autoOrient.changed ||
      effects.changed;
}

/// Runs every fix on [doc] in place: strips crashing/dead layers and prunes
/// assets left unreferenced by that, bakes any `loopOut`/`loopIn` expression
/// into real keyframes, then bakes any remaining supported expression on a
/// never-keyframed or already-keyframed property, bakes auto-orient into
/// plain rotation keyframes — after the expression passes, so a layer is
/// oriented along the position they just baked — and finally removes the
/// layer effects `lottie` ignores, once no expression is left to read them.
/// Safe to call repeatedly.
///
/// [options] toggles the parts of the property-expression pass that are
/// approximations or judgment calls rather than an exact match to After
/// Effects — see [BakeOptions] for what each one changes.
FixResult fix(
  Map<String, dynamic> doc, {
  BakeOptions options = const BakeOptions(),
}) {
  final sanitize = sanitizeCrashingLayers(doc);
  final bake = bakeLoopExpressions(doc);
  final propertyBake = bakePropertyExpressions(doc, options: options);
  final autoOrient = bakeAutoOrient(doc);
  final effects = stripUnsupportedEffects(doc);
  return FixResult(
    sanitize: sanitize,
    bake: bake,
    propertyBake: propertyBake,
    autoOrient: autoOrient,
    effects: effects,
  );
}
