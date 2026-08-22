/// Toggles for the parts of expression-baking that are approximations or
/// judgment calls rather than an exact match to how After Effects would
/// render the same expression — so a caller that wants stricter,
/// more conservative output can opt out of a specific one instead of
/// getting a possibly-inexact bake, or losing baking entirely for
/// everything else.
///
/// Every option here defaults to `true` (today's behavior: bake everything
/// this package knows how to). Turning one off only ever makes baking more
/// conservative — an expression that would have been baked is instead left
/// untouched and reported via `PropertyBakeResult.skippedExpressions`/
/// `Diagnosis.unsupportedExpressions`, never removed or altered.
library;

class BakeOptions {
  const BakeOptions({
    this.bakeRandomAndWiggle = true,
    this.bakeOnKeyframedProperties = true,
    this.bakeShapePathWiggle = true,
    this.bakeApproximateEasing = true,
  });

  /// Bake `random()`/`wiggle()` expressions at all. After Effects' own
  /// noise/PRNG is proprietary, so these are baked as a seeded,
  /// deterministic *approximation* — reproducible across builds, but not a
  /// bit-exact match to what AE itself renders. Turn this off to leave any
  /// expression using `random()`/`wiggle()` unsupported instead (this also
  /// disables [bakeShapePathWiggle], since that mechanism is wiggle-only).
  final bool bakeRandomAndWiggle;

  /// Bake a supported expression on a property that's *already* keyframed
  /// (not just `"a": 0`), using the property's own original keyframe curve
  /// — linearly resampled, not the authored bezier easing — as the
  /// per-frame `value`/`wiggle()` base. This replaces the property's real
  /// keyframes with a dense per-frame bake, a bigger structural change than
  /// baking a never-keyframed property. Turn this off to leave every
  /// expression on an already-keyframed property unsupported, matching
  /// versions of this package before 0.3.0.
  final bool bakeOnKeyframedProperties;

  /// Bake a `wiggle()`-only expression on a shape path (`ty: "sh"`'s `ks`),
  /// wiggling each vertex independently. This is a newer, more speculative
  /// mechanism than the numeric/vector bake path, and only takes effect
  /// when [bakeRandomAndWiggle] is also on. Turn this off to leave every
  /// expression on a shape path unsupported.
  final bool bakeShapePathWiggle;

  /// Bake `ease()`/`easeIn()`/`easeOut()` calls. Unlike `linear()` (an exact
  /// formula), these approximate After Effects' bezier-based easing with a
  /// quadratic/smoothstep curve — close, but not a bit-exact match. Turn
  /// this off to leave any expression using them unsupported; `linear()`
  /// and everything else are unaffected.
  final bool bakeApproximateEasing;
}
