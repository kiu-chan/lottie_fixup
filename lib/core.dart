/// The pure-Dart half of `lottie_fixup`: fixes for common issues in Lottie
/// files exported from After Effects via Bodymovin, with no dependency on
/// Flutter. Import this (instead of `package:lottie_fixup/lottie_fixup.dart`)
/// from code that must run under plain `dart run` — a CLI tool or a script
/// with no Flutter engine attached — since the main library also exports
/// [fixupLottieDecoder], which pulls in `package:lottie` and therefore
/// `dart:ui`.
library;

export 'src/bake_loop_expressions.dart' show BakeResult, bakeLoopExpressions, loopGap;
export 'src/diagnose.dart' show Diagnosis, diagnose;
export 'src/fix.dart' show FixResult, fix;
export 'src/sanitize_crashing_layers.dart'
    show SanitizeResult, sanitizeCrashingLayers, audioLayerType;
