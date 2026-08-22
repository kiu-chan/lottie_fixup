/// Fixes for common issues in Lottie files exported from After Effects via
/// Bodymovin, before they reach the `lottie` Flutter package.
///
/// This barrel also exports [fixupLottieDecoder], which depends on
/// `package:lottie`/`dart:ui`. Code that must run under plain `dart run`
/// (no Flutter engine attached — e.g. a CLI tool) should import
/// `package:lottie_fixup/core.dart` instead.
library;

export 'core.dart';
export 'src/fixup_decoder.dart' show fixupLottieDecoder;
