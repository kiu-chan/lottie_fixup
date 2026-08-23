## 1.0.1

- Shortened pubspec description.

## 1.0.0

- **Fixed a real crash risk**: `bakePropertyExpressions` only ever caught its
  own `ExpressionEvalError` around parsing and per-frame sampling, so
  anything else — a malformed numeric literal in an expression (the
  tokenizer accepted e.g. `1.2.3` as one token, then `num.parse` threw a
  `FormatException`), or a cross-layer/`.valueAtTime()` reference into a
  layer whose property was shaped unexpectedly (a plain `TypeError` from an
  invalid cast) — propagated all the way up through `fix`/
  `fixupLottieDecoder` uncaught, crashing the whole file's processing (and
  the widget) over a single bad expression instead of leaving just that one
  property unsupported. Both bake paths (`_tryBakeNumeric`,
  `_tryBakeShapePath`) now catch broadly at that boundary, so one malformed
  expression or malformed referenced property never takes down every other,
  unrelated, otherwise-fine property in the same document.
- **Fixed a real correctness bug**: a division that lands on exactly zero at
  a sampled frame (e.g. `1 / (time - 1)`) silently produced `Infinity`/`NaN`
  — Dart's arithmetic doesn't throw on this — which then crashed
  `jsonEncode` later, at serialization time, with a much less useful error
  pointing nowhere near the actual expression. Non-finite results are now
  rejected where a value is finalized into a keyframe, so the property is
  reported unsupported instead — except where the non-finite value was only
  ever an intermediate step already handled by `clamp()` (e.g. `clamp(1 / x,
  -100, 100)`), which still bakes correctly.
- **Fixed a real correctness bug**: a `wiggle()`-only knot cache was shared
  across *every* `wiggle()` call in an expression, keyed only by knot index
  — so a layered "octave noise" rig like `wiggle(1, 50) + wiggle(5, 10)` (a
  common After Effects technique) had its second call silently read back
  the first call's cached knot whenever their indices happened to coincide,
  producing incorrect, correlated motion instead of two independent noise
  signals. Each `wiggle()` call site now gets its own independent knot
  cache.
- **Fixed a real correctness bug**: `bakePropertyExpressions` walked and
  baked layers/properties top-down in document order, so a cross-layer
  reference (or, as of this release, a same-layer `thisLayer`/`transform`
  reference — see below) to a property that itself had its own not-yet-baked
  expression copied or sampled that property's stale pre-expression value
  whenever the source happened to appear later in the walk — common, since
  layer array order has no relationship to pickwhip direction. Once copied,
  it was never revisited even after the source was correctly baked moments
  later. Property baking is now dependency-ordered: baking a property first
  recursively bakes any not-yet-baked property it references (anywhere in
  its expression, not just a bare reference), regardless of where either one
  sits in the document. A genuine reference cycle (already undefined
  behavior in After Effects itself) bakes against the cycle-closing
  property's current state rather than recursing forever.
- `bakePropertyExpressions`/cross-layer references: `skew`/`skewAxis` are
  now recognized transform properties (alongside `position`/`rotation`/
  `scale`/`opacity`/`anchorPoint`), so
  `thisComp.layer('Name').transform.skew` no longer reports "unknown
  transform property".
- New same-layer reference support: `thisLayer.transform.<prop>` and bare
  `transform.<prop>` (sugar for the same thing) now resolve to the
  expression's own layer, reusing the same cross-layer machinery —
  `.valueAtTime()`, dense sampling when combined with other math, and exact
  keyframe copying for a bare reference all work identically to a
  `thisComp.layer(...)` reference. This is exact, not an approximation (like
  the pre-existing cross-layer support it reuses), so it isn't gated by
  `BakeOptions`.
- **New: structural crash detection and repair**, extending
  `sanitizeCrashingLayers` beyond audio layers/empty precomps to six more
  crash-causing JSON shapes — each grounded in a specific, confirmed
  non-null-assertion or unassigned-`late`-field crash in the `lottie`
  package's own parser/model source, the same standard the audio-layer fix
  was already held to:
  - A precomp layer (`ty: 0`) whose `refId` doesn't resolve to any asset
    (missing, non-string, or no match) is removed —
    `composition.getPrecomps(refId)!` throws building the render tree
    otherwise. Unlike a dangling `refId` this package's own pruning might
    create (already guarded against separately), this can be present in
    the input file itself.
  - A text layer (`ty: 5`) missing `t`/`t.d` is removed — `lottie`'s text
    layer unconditionally null-checks it while being built.
  - An asset entry with no usable `id` (missing, `null`, a bool, an array,
    or an object — a number is fine, `lottie` coerces it) is removed —
    such an asset can never legitimately be referenced, and `lottie`'s own
    asset parser crashes reading its `id`.
  - A `masksProperties` entry missing `mode`, `pt`, or `o` is removed —
    each is read into a variable with no fallback, so `lottie` crashes
    building the mask itself, not just when it's later applied.
  - A gradient-fill/gradient-stroke/solid-stroke shape-content item
    (`gf`/`gs`/`st`) missing a required companion field (gradient
    colors/start/end point, or stroke color/width) is removed, recursing
    through shape groups. `lottie`'s own source confirms this really
    happens in the wild: a code comment there specifically calls out
    Telegram's Lottie export omitting the sibling opacity field in these
    same objects.
  - An out-of-range `lc`/`lj` (line cap/join, valid range `1..3`) on a
    `gs`/`st` item is cleared — just that one field, leaving the rest of
    the stroke intact — instead of indexing `lottie`'s internal enum list
    out of bounds.
  - New, diagnostic-only (matching the existing `layersMissingTransform`
    treatment — reported, not altered, since there's no principled safe
    default for an arbitrary property): any animatable-value-shaped object
    (`{"a":..,"k":..}`, or a gradient's `{"p":..,"k":..}`) found with a
    missing or empty `k` is reported via the new
    `SanitizeResult.propertiesWithEmptyKeyframes` — `lottie` crashes
    indexing the last element of an empty keyframe list, and this is the
    broadest-blast-radius issue found (it can occur on essentially any
    animatable property anywhere in the file).
  - `SanitizeResult`'s new fields are all optional/defaulted, keeping the
    door open for a caller to construct one directly (e.g. in a test)
    without naming every field.
- `diagnose`/`Diagnosis`: gains a new `sanitize` field (a `SanitizeResult`)
  surfacing all of the above, plus the pre-existing
  `layersMissingTransform` diagnostic, which `Diagnosis` never exposed
  before. Computed on its own fresh decode, independent of the
  loop/property-expression bake passes, so a structurally-broken layer
  being removed there never changes what
  `loopExpressionsToBake`/`propertyExpressionsToBake`/
  `unsupportedExpressions` report for the same document.
- CLI: `diagnose` and `fix` both report all of the above; `fix` now prints
  its diagnostic-only warnings (missing transform, empty keyframes) even
  on a file where nothing else needed fixing, rather than only printing
  `nothing to fix.` and silently dropping them.

## 0.3.0

- **Fixed a real correctness bug**: `bakePropertyExpressions` used to only
  ever look at an expression's *last* statement, silently discarding any
  statement before it — so `posterizeTime(6); $bm_rt = wiggle(3, 30);` baked
  "successfully" but with `posterizeTime` dropped entirely, producing smooth
  per-frame interpolation instead of a 6-updates-per-second stepped hold.
  Fixed by replacing the single-expression extractor with a real statement
  interpreter that runs the whole expression body in order.
- The expression evaluator now understands a much larger, still-deliberately
  small subset of AE expression syntax as part of that rewrite:
  - `if`/`else` (with `<`, `>`, `<=`, `>=`, `==`, `!=`, `&&`, `||`, `!`, and
    `? :`), and local `var` bindings — e.g. branching a property's value by
    `time`, or a two-step computation like `var s = ...; $bm_rt = [s, s, 100];`.
  - `.valueAtTime(t)` on a cross-layer transform reference, for
    delayed/trailing "follow" rigs.
  - The `Math.*` namespace (`Math.sin`, `Math.cos`, `Math.abs`, `Math.sqrt`,
    `Math.pow`, `Math.max`/`Math.min`, `Math.PI`, etc.), not just bare `PI`.
  - `linear()`/`ease()`/`easeIn()`/`easeOut()` interpolation helpers and
    `clamp()`.
  - `add()`/`sub()`/`mul()`/`div()` vector math and the `value` identifier
    (the property's own pre-expression value), plus array literals
    (`[a, b, c]`) as a standalone expression, not just index access.
  - `posterizeTime(fps)` actually posterizes (quantizes) `time` for the rest
    of the expression's evaluation instead of being a no-op; `seedRandom()`
    is now recognized (a no-op, since this package's seeding is already
    deterministic and independent of it) instead of making the whole
    expression unsupported.
- `bakePropertyExpressions` now also bakes a supported expression on a
  property that's *already* keyframed (previously only never-keyframed
  properties were eligible; an expression on real keyframes was always
  reported as unsupported). The original keyframe curve — linearly sampled,
  per frame — becomes the `value`/`wiggle()` base, matching how After
  Effects itself evaluates an expression layered on top of real keyframes.
- `bakePropertyExpressions`: a `wiggle(freq, amp)`-only expression on a shape
  path (`ty: "sh"`'s `ks`) is now baked too, wiggling each vertex
  independently (own seed, own knots) and leaving `i`/`o` tangent handles
  and `c` untouched. Any other expression on a path remains unsupported —
  arithmetic directly on a path value isn't something After Effects supports
  either.
- New `BakeOptions`, for opting out of the specific parts of expression
  baking above that are an approximation or a judgment call rather than an
  exact match to After Effects (`random()`/`wiggle()`, baking on an
  already-keyframed property, shape-path `wiggle()`, `ease()`/`easeIn()`/
  `easeOut()`) — every option defaults to `true` (bake everything, today's
  behavior), so this is purely additive. Threaded through `fix`, `diagnose`,
  the new `fixupLottieDecoderWithOptions` (`fixupLottieDecoder` keeps its
  no-argument default-options signature), and new CLI flags
  (`--no-random-wiggle`, `--no-keyframed-properties`,
  `--no-shape-path-wiggle`, `--no-approximate-easing`).

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
