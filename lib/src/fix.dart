import 'bake_loop_expressions.dart';
import 'sanitize_crashing_layers.dart';

/// Combined result of running all fixes on a document.
class FixResult {
  const FixResult({required this.sanitize, required this.bake});

  final SanitizeResult sanitize;
  final BakeResult bake;

  bool get changed => sanitize.changed || bake.changed;
}

/// Runs every fix on [doc] in place: strips crashing/dead layers and prunes
/// assets left unreferenced by that, then bakes any `loopOut` expression
/// into real keyframes. Safe to call repeatedly.
FixResult fix(Map<String, dynamic> doc) {
  final sanitize = sanitizeCrashingLayers(doc);
  final bake = bakeLoopExpressions(doc);
  return FixResult(sanitize: sanitize, bake: bake);
}
