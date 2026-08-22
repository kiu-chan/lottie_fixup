## 0.1.0

- Initial release.
- `sanitizeCrashingLayers`: removes audio layers (`ty: 6`) that crash the `lottie` Flutter package's layer parser, drops empty precomps, and prunes assets left unreferenced by that.
- `bakeLoopExpressions`: bakes `loopOut('pingpong')` / `loopOut('cycle')` expressions into real keyframes, since `lottie` does not execute expressions.
- `diagnose`: read-only report of the same issues, without modifying the file.
- `fix`: runs both fixes together.
- CLI: `dart run lottie_fixup diagnose|fix <file...>`.
- `fixupLottieDecoder`: a `LottieDecoder` for the `lottie` package that runs `fix` on the bytes before parsing, fixing raw exports at load time with no build step. Requires the Flutter SDK.
