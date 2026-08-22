# lottie_fixup

Fixes for common issues in Lottie files exported from After Effects via
Bodymovin, before they reach the [`lottie`](https://pub.dev/packages/lottie)
Flutter package.

## Why

Bodymovin exports carry a few things `lottie` can't handle:

- **Audio layers** (`"ty": 6`) ship without a transform block (`ks`).
  `lottie`'s layer parser does a non-null assertion on it and throws
  `Null check operator used on a null value` — the whole widget gets
  replaced by a red error screen.
- **`loopOut()` / `loopIn()` expressions** — After Effects exports keyframes
  for one short cycle and lets the expression repeat it. `lottie` does not
  run expressions, so the property freezes after its last keyframe instead
  of looping.
- **Empty precomps** and the now-unreferenced assets left behind by removing
  the above — harmless to render, just dead weight in the file.

This package strips the layers that crash, bakes `loopOut` expressions into
real keyframes the same way After Effects interprets them, and prunes
whatever becomes unreferenced as a result — either ahead of time as a build
step, or on the fly as files load.

## Usage

### Fix at load time — no build step

Drop `fixupLottieDecoder` into any `lottie` loading API that takes a
`decoder`, and a raw, unbaked export just works:

```dart
import 'package:lottie/lottie.dart';
import 'package:lottie_fixup/lottie_fixup.dart';

Lottie.asset('assets/character.json', decoder: fixupLottieDecoder)
```

Safe to apply unconditionally, even to files already fixed ahead of time:
`fix` is a no-op when there's nothing left to do. The extra JSON
decode/walk/re-encode runs once per composition load — `lottie` caches the
parsed `LottieComposition` afterward — not once per frame.

That one-time cost isn't free, though. Measured on a 365 KB animation
(20-run average, on a fast desktop machine):

| | avg. time |
|---|---|
| `LottieComposition.fromBytes` (no fixup) | ~5.8 ms |
| `fixupLottieDecoder` (decode + fix + re-encode + parse) | ~17.3 ms |

The overhead is mostly the generic `jsonDecode`/`jsonEncode` round-trip
through `Map<String, dynamic>`, not the `fix` logic itself — `lottie`'s own
parser reads bytes more directly. By default this runs **synchronously on
the UI isolate**, as part of `AssetLottie.load()`; for a file this size,
that's already close to one frame budget (16.7 ms at 60 fps) on a fast
machine, and proportionally worse on low-end hardware. Pass
`backgroundLoading: true` to move it off the UI thread (`lottie` runs it via
`compute()` on a background isolate):

```dart
Lottie.asset(
  'assets/character.json',
  decoder: fixupLottieDecoder,
  backgroundLoading: true,
)
```

### Fix ahead of time — CLI

For an animation that ships in every build and never changes, fixing once
and shipping the clean file skips this cost entirely — the decoder has
nothing left to do:

```bash
dart pub global activate lottie_fixup
lottie_fixup diagnose assets/animations/*.json   # report only, no changes
lottie_fixup fix assets/animations/*.json        # fix in place
```

Or without a global activation, from a checkout:

```bash
dart run lottie_fixup fix path/to/animation.json
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

`fix`, its two halves — `sanitizeCrashingLayers` and `bakeLoopExpressions`
— and `fixupLottieDecoder` are all safe to run repeatedly: a file with
nothing left to fix is a no-op.

## What this does *not* fix

- Expressions other than `loopOut`/`loopIn` (e.g. `wiggle`, `valueAtTime`)
  are reported (`diagnose`, or `FixResult.bake.skippedExpressions`) but left
  untouched — baking an arbitrary After Effects expression means
  interpreting a JS-like language, out of scope here.
- A layer missing `ks` for a reason other than being an audio layer is
  flagged (`SanitizeResult.layersMissingTransform`) rather than silently
  removed, since that could be a real authoring mistake worth looking at by
  hand rather than a known, safe-to-drop pattern.

## Background

Written after a real crash caused by an audio layer shipped in an After
Effects export, and a real "character freezes after one second" bug caused
by an unbaked `loopOut('pingpong')` expression. See the package source for
the exact mechanics (including why the loop gap used when snapping a value
back to its start must stay as small as `1e-5` frame — a larger gap causes a
one-frame glitch once per loop that's easy to miss on a quick look).
