import 'bake_loop_expressions.dart';
import 'bake_property_expressions.dart';
import 'sanitize_crashing_layers.dart';

/// Combined result of running all fixes on a document.
class FixResult {
  const FixResult({
    required this.sanitize,
    required this.bake,
    required this.propertyBake,
  });

  final SanitizeResult sanitize;
  final BakeResult bake;
  final PropertyBakeResult propertyBake;

  bool get changed => sanitize.changed || bake.changed || propertyBake.changed;
}

/// Runs every fix on [doc] in place: strips crashing/dead layers and prunes
/// assets left unreferenced by that, bakes any `loopOut`/`loopIn` expression
/// into real keyframes, then bakes any remaining expression (cross-layer
/// links, `time`-based motion, `random()`/`wiggle()`) on a property that was
/// never manually keyframed. Safe to call repeatedly.
FixResult fix(Map<String, dynamic> doc) {
  final sanitize = sanitizeCrashingLayers(doc);
  final bake = bakeLoopExpressions(doc);
  final propertyBake = bakePropertyExpressions(doc);
  return FixResult(sanitize: sanitize, bake: bake, propertyBake: propertyBake);
}
