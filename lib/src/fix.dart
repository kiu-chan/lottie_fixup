import 'bake_auto_orient.dart';
import 'bake_loop_expressions.dart';
import 'bake_options.dart';
import 'bake_property_expressions.dart';
import 'sanitize_crashing_layers.dart';

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
  });

  final SanitizeResult sanitize;
  final BakeResult bake;
  final PropertyBakeResult propertyBake;
  final AutoOrientBakeResult autoOrient;

  bool get changed =>
      sanitize.changed ||
      bake.changed ||
      propertyBake.changed ||
      autoOrient.changed;
}

/// Runs every fix on [doc] in place: strips crashing/dead layers and prunes
/// assets left unreferenced by that, bakes any `loopOut`/`loopIn` expression
/// into real keyframes, then bakes any remaining supported expression on a
/// never-keyframed or already-keyframed property, and finally bakes
/// auto-orient into plain rotation keyframes — last, so a layer is oriented
/// along the position the expression passes just baked. Safe to call
/// repeatedly.
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
  return FixResult(
    sanitize: sanitize,
    bake: bake,
    propertyBake: propertyBake,
    autoOrient: autoOrient,
  );
}
