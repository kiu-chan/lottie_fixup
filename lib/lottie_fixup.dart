/// Fixes for common issues in Lottie files exported from After Effects via
/// Bodymovin, before they reach the `lottie` Flutter package.
library;

export 'src/bake_loop_expressions.dart' show BakeResult, bakeLoopExpressions, loopGap;
export 'src/diagnose.dart' show Diagnosis, diagnose;
export 'src/fix.dart' show FixResult, fix;
export 'src/fixup_decoder.dart' show fixupLottieDecoder;
export 'src/sanitize_crashing_layers.dart'
    show SanitizeResult, sanitizeCrashingLayers, audioLayerType;
