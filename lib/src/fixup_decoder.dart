import 'dart:convert';

import 'package:lottie/lottie.dart';

import 'fix.dart';

/// A [LottieDecoder] that runs [fix] on the bytes before parsing, so a raw
/// After Effects/Bodymovin export — one that still has audio layers, empty
/// precomps, or a `loopOut()`/`loopIn()` expression — renders correctly
/// without a separate build-time bake step.
///
/// Pass it to any `lottie` loading API that accepts a `decoder`:
///
/// ```dart
/// Lottie.asset('assets/character.json', decoder: fixupLottieDecoder)
/// ```
///
/// Safe on files that are already clean: [fix] is a no-op when there's
/// nothing left to fix, so this can be applied unconditionally to every
/// Lottie asset in an app. The extra JSON decode/walk/re-encode runs once
/// per composition load (results are cached by the `lottie` package's own
/// `LottieCache`), not per frame.
Future<LottieComposition?> fixupLottieDecoder(List<int> bytes) async {
  final doc = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  fix(doc);
  return LottieComposition.parseJsonBytes(utf8.encode(jsonEncode(doc)));
}
