## Unreleased

- `bakeLoopExpressions`: `loopIn('cycle')` is now detected and baked (tiling
  the segment backward from its first keyframe down to `doc['ip']`) —
  previously only `loopOut` was recognized at all, so a property using
  `loopIn` alone was silently left frozen with no warning.
- `bakeLoopExpressions`: loop mode is now parsed precisely instead of
  guessed from `expr.contains('pingpong')`, so a mode other than `'cycle'`/
  `'pingpong'` is never silently mis-baked as `'cycle'` again.
- `bakeLoopExpressions`: `'offset'` and `'continue'` are now baked too, for
  both `loopOut` and `loopIn`, on any property whose keyframe values are
  plain numbers (position, scale, rotation, opacity...). `'offset'` repeats
  the segment shape but shifts each repetition's values by `last - first`,
  so the property keeps trending instead of snapping back to the start.
  `'continue'` doesn't repeat keyframes at all — it extrapolates a single
  straight segment past the boundary keyframe at that segment's own rate of
  change. Left untouched and reported via `skippedExpressions` when the
  property's values aren't plain numbers (e.g. a shape path), same as
  `loopIn('pingpong')` (not yet supported) and an expression that calls both
  `loopIn` and `loopOut` on the same property.
- `Diagnosis` (breaking): `loopOutOccurrences` (a raw substring count over
  the file) is replaced by `loopExpressionsToBake` and `unsupportedExpressions`,
  computed with the same detection logic as `bakeLoopExpressions` — so
  `diagnose` now agrees with `fix` about what will and won't be baked, and
  also surfaces expressions other than `loopOut`.
- CLI `diagnose`: reports unsupported expressions in addition to the
  bakeable-expression count.

## 0.1.0

- Initial release.
- `sanitizeCrashingLayers`: removes audio layers (`ty: 6`) that crash the `lottie` Flutter package's layer parser, drops empty precomps, and prunes assets left unreferenced by that.
- `bakeLoopExpressions`: bakes `loopOut('pingpong')` / `loopOut('cycle')` expressions into real keyframes, since `lottie` does not execute expressions.
- `diagnose`: read-only report of the same issues, without modifying the file.
- `fix`: runs both fixes together.
- CLI: `dart run lottie_fixup diagnose|fix <file...>`.
- `fixupLottieDecoder`: a `LottieDecoder` for the `lottie` package that runs `fix` on the bytes before parsing, fixing raw exports at load time with no build step. Requires the Flutter SDK.
