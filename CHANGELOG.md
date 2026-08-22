## 0.2.0

- `bakeLoopExpressions`: `loopIn('pingpong')` is now baked too, mirroring
  the segment backward from the first keyframe the same way
  `loopOut('pingpong')` already mirrors it forward — previously reported as
  unsupported.
- `bakeLoopExpressions`: the duration-based `loopOutDuration(type,
  durationSeconds)`/`loopInDuration(type, durationSeconds)` variants are now
  baked in `'cycle'`/`'pingpong'` mode, by repeating a fixed-length span of
  time (rather than the whole keyframed segment) ending/starting at the
  boundary keyframe, holding flat wherever that span reaches past the
  actually-keyframed range. A duration shorter than the keyframed segment
  itself isn't supported (would need interpolating a cut point mid-segment)
  and is reported instead.
- Fixed a latent crash in the `'pingpong'` mirroring helper when a keyframe
  had no `i`/`o` easing recorded at all (falls back to linear instead of a
  null-cast error).
- New `bakePropertyExpressions` (exported from `core.dart`), run by `fix`
  after `bakeLoopExpressions`: bakes expressions on a property that was
  never manually keyframed (`"a": 0`) that aren't a loop call —
  `time`-based motion (e.g. `time * 180` for continuous rotation),
  cross-layer links (`thisComp.layer('Name').transform.position`, copied
  exactly when that's the whole expression, otherwise sampled alongside
  other arithmetic), and `random()`/`wiggle()` (a seeded, deterministic
  approximation — After Effects' own noise/PRNG isn't reproducible
  bit-for-bit, but this is reproducible across builds and beats a frozen
  property).
- `Diagnosis` (breaking): adds `propertyExpressionsToBake`, and
  `unsupportedExpressions` now reflects what's left after *both* bake passes
  run (previously only `bakeLoopExpressions`'), so it no longer lists
  expressions `bakePropertyExpressions` can actually handle.
- `FixResult` (breaking): adds `propertyBake` (a `PropertyBakeResult`).
- CLI: reports unbaked/baked property expressions alongside loop
  expressions.

## 0.1.1

- `bakeLoopExpressions` (fix): expressions on a scalar property that was
  never manually keyframed (`"a": 0`, e.g. rotation or opacity with a
  `random()`/`loopOut()` expression but no keyframes) are no longer silently
  invisible to both `diagnose` and `fix`. The detection only checked
  `k is List`, which holds for a keyframe array (`"a": 1`) but also — wrongly
  — for a non-animated multi-dimensional property's raw `[x, y, z]` value; a
  non-animated scalar property's raw `k` (a plain number) failed the check
  and skipped detection entirely, rather than being reported via
  `skippedExpressions` like every other unsupported case. Detection now
  checks that `k` is actually a list of keyframe objects, which also
  prevents attempting to bake a `loopOut`/`loopIn` call found on a
  non-animated multi-dimensional property (previously would have crashed
  doing keyframe arithmetic on raw numbers).
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
