# lottie_fixup

Fixes Lottie/Bodymovin exports that crash or freeze the
[`lottie`](https://pub.dev/packages/lottie) Flutter package: audio layers,
empty precomps, and `loopOut()` / `loopIn()` expressions.

## Features

- **Stops the audio-layer crash** — After Effects audio layers (`"ty": 6`)
  ship without the transform block `lottie` expects, which throws
  `Null check operator used on a null value`. This package strips them.
- **Bakes `loopOut('cycle'|'pingpong')` and `loopIn('cycle')` expressions**
  into real keyframes, so looping animations don't freeze after their first
  cycle (`lottie` doesn't execute expressions).
- **Prunes empty precomps** and now-unreferenced assets left behind by the
  fixes above.
- Use it **at load time** (drop-in decoder, no build step) or **ahead of
  time** (CLI, zero runtime cost).

## Getting started

Add the dependency:

```yaml
dependencies:
  lottie_fixup: ^0.1.0
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

- Expressions other than `loopOut('cycle'|'pingpong')`/`loopIn('cycle')`
  (e.g. `wiggle`, `valueAtTime`, `loopIn('pingpong')`, the `'offset'`/
  `'continue'` loop modes, or a property that calls both `loopIn` and
  `loopOut`) are reported (`diagnose`, or `FixResult.bake.skippedExpressions`)
  but left untouched, rather than baked incorrectly.
- A layer missing `ks` for a reason other than being an audio layer is
  flagged (`SanitizeResult.layersMissingTransform`) rather than silently
  removed, since that could be a real authoring mistake worth checking by
  hand.

## Additional information

If this package saved you a debugging session, consider
[buying me a coffee](https://ko-fi.com/monlycute).
