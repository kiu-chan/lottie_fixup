# lottie_fixup

Fixes Lottie/Bodymovin exports that crash or freeze the
[`lottie`](https://pub.dev/packages/lottie) Flutter package: audio layers,
empty precomps, and expressions that `lottie` doesn't execute (`loopOut()`/
`loopIn()`, `wiggle()`, `random()`, `time`-based motion, cross-layer links).

## Features

- **Stops the audio-layer crash** — After Effects audio layers (`"ty": 6`)
  ship without the transform block `lottie` expects, which throws
  `Null check operator used on a null value`. This package strips them.
- **Bakes `loopOut()`/`loopIn()` expressions** into real keyframes, so
  looping animations don't freeze after their first cycle (`lottie` doesn't
  execute expressions). All four After Effects loop modes are supported in
  both directions — `'cycle'`, `'pingpong'`, `'offset'`, `'continue'` — the
  latter two on any numeric property (position, scale, rotation, opacity...)
  — plus the duration-based `loopOutDuration()`/`loopInDuration()` variants
  in `'cycle'`/`'pingpong'` mode.
- **Bakes other expressions**, on a never-animated property *or* one that's
  already keyframed (the expression's result is authoritative, same as After
  Effects — the original curve is only available through `value`/
  `valueAtTime()`): continuous `time`-based motion (e.g. `time * 180` for
  constant rotation), `if`/`else` branching with comparisons/booleans, local
  `var` bindings, cross-layer links
  (`thisComp.layer('Name').transform.position`, copied exactly when that's
  the whole expression on a never-animated property, sampled when combined
  with other math or via `.valueAtTime(t)`), the `Math.*` namespace,
  `linear()`/`ease()`/`easeIn()`/`easeOut()`/`clamp()`,
  `add()`/`sub()`/`mul()`/`div()`/`value`, `posterizeTime()`, and
  `random()`/`wiggle()` (a deterministic, seeded approximation — After
  Effects' own noise/PRNG can't be reproduced bit-for-bit, but this is
  reproducible across builds and beats a frozen property). A `wiggle()`-only
  expression on a shape path wiggles each vertex independently.
- **Prunes empty precomps** and now-unreferenced assets left behind by the
  fixes above.
- Use it **at load time** (drop-in decoder, no build step) or **ahead of
  time** (CLI, zero runtime cost).

## Getting started

Add the dependency:

```yaml
dependencies:
  lottie_fixup: ^0.2.0
```

## Usage

### At load time — no build step

Drop `fixupLottieDecoder` into any `lottie` loading API that takes a
`decoder`:

```dart
import 'package:lottie/lottie.dart';
import 'package:lottie_fixup/lottie_fixup.dart';

Lottie.asset('assets/character.json', decoder: fixupLottieDecoder)
```

Safe to apply unconditionally, even to files already fixed ahead of
time — `fix` is a no-op when there's nothing left to do. This adds a JSON
decode/walk/re-encode once per composition load, not per frame. For larger
files, pass `backgroundLoading: true` to move that work off the UI isolate:

```dart
Lottie.asset(
  'assets/character.json',
  decoder: fixupLottieDecoder,
  backgroundLoading: true,
)
```

### Ahead of time — CLI

For an animation that ships in every build and never changes, fix it once
and skip the runtime cost entirely:

```bash
dart pub global activate lottie_fixup
lottie_fixup diagnose assets/animations/*.json   # report only, no changes
lottie_fixup fix assets/animations/*.json        # fix in place
```

### Library

```dart
import 'dart:convert';
import 'dart:io';
import 'package:lottie_fixup/lottie_fixup.dart';

final file = File('animation.json');
final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

final result = fix(doc); // mutates doc in place
if (result.changed) {
  file.writeAsStringSync(jsonEncode(doc));
}
```

## What this does *not* fix

- Expressions this package's small evaluator doesn't understand (e.g.
  `effect(...)`, a reference into a nested comp, `for`/`while` loops or
  user-defined functions) are reported (`diagnose`, or
  `FixResult.propertyBake.skippedExpressions`) but left untouched.
- `'offset'`/`'continue'` on a non-numeric value (a shape path, for example,
  rather than position/scale/rotation/opacity) is reported rather than
  baked, since those modes work by doing arithmetic directly on the value.
- A non-`wiggle()` expression on a shape path (arithmetic directly on a path
  value) is reported rather than baked — After Effects doesn't support that
  either.
- A duration variant (`loopOutDuration`/`loopInDuration`) whose duration is
  *shorter* than the keyframed segment itself is reported rather than baked
  — that would need interpolating a cut point in the middle of the real
  animation, which isn't implemented.
- A property that calls both `loopIn` and `loopOut` (a manual "loop both
  ways" expression) is reported rather than guessed at.
- `random()`/`wiggle()` are baked as a *plausible approximation*, not a
  bit-exact match to After Effects — see Features above.
- A layer missing `ks` for a reason other than being an audio layer is
  flagged (`SanitizeResult.layersMissingTransform`) rather than silently
  removed, since that could be a real authoring mistake worth checking by
  hand.

## Additional information

If this package saved you a debugging session, consider buying me a coffee.

[![ko-fi](https://storage.ko-fi.com/cdn/kofi5.png?v=6)](https://ko-fi.com/monlycute)
