import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:lottie_fixup/lottie_fixup.dart';

/// A document with one auto-oriented null layer carrying [ks], round-tripped
/// through JSON so its maps have the same loose types as a real file's.
Map<String, dynamic> _doc(Map<String, dynamic> ks, {int ddd = 0}) {
  return jsonDecode(
        jsonEncode({
          'v': '5.12.2',
          'fr': 30,
          'ip': 0,
          'op': 720,
          'w': 2048,
          'h': 2732,
          'layers': [
            {
              'ddd': ddd,
              'ind': 1,
              'ty': 3,
              'nm': 'layer',
              'sr': 1,
              'ao': 1,
              'ks': ks,
              'ip': 0,
              'op': 720,
              'st': 0,
            },
          ],
          'assets': <dynamic>[],
        }),
      )
      as Map<String, dynamic>;
}

Map<String, dynamic> _layer(Map<String, dynamic> doc) =>
    (doc['layers'] as List).single as Map<String, dynamic>;

Map<String, dynamic> _ks(Map<String, dynamic> doc) =>
    _layer(doc)['ks'] as Map<String, dynamic>;

/// The baked rotation at [t], played back the way `lottie` plays keyframes
/// with no easing: linearly.
double _rotationAt(Map<String, dynamic> doc, num t) {
  final k = (_ks(doc)['r'] as Map)['k'];
  if (k is num) return k.toDouble();
  final keyframes = (k as List).cast<Map<String, dynamic>>();
  double valueAt(int i) =>
      ((keyframes[i]['s'] as List).first as num).toDouble();
  num timeAt(int i) => keyframes[i]['t'] as num;
  if (t <= timeAt(0)) return valueAt(0);
  for (var i = 0; i < keyframes.length - 1; i++) {
    if (t <= timeAt(i + 1)) {
      final f = (t - timeAt(i)) / (timeAt(i + 1) - timeAt(i));
      return valueAt(i) + (valueAt(i + 1) - valueAt(i)) * f;
    }
  }
  return valueAt(keyframes.length - 1);
}

/// Position keyframes moving linearly through [points], 10 frames apart.
Map<String, dynamic> _linearPath(List<List<num>> points) => {
  'a': 1,
  'k': [
    for (var i = 0; i < points.length; i++) {'t': i * 10, 's': points[i]},
  ],
};

/// An arc from left to right that dips down in between: one long spatial
/// handle into the end point, a zero-length one out of the start point.
Map<String, dynamic> _arcRight({
  Map<String, dynamic>? out,
  Map<String, dynamic>? into,
}) => {
  'a': 1,
  'k': [
    {
      'i': into ?? {'x': 0.7, 'y': 1},
      'o': out ?? {'x': 0.2, 'y': 0.2},
      't': 100,
      's': [0, 400, 0],
      'to': [0, 0, 0],
      'ti': [-1500, 900, 0],
    },
    {
      't': 160,
      's': [3000, 400, 0],
    },
  ],
};

/// The same arc traced right to left: its heading passes through 180°.
Map<String, dynamic> _arcLeft() => {
  'a': 1,
  'k': [
    {
      'i': {'x': 0.8, 'y': 0.8},
      'o': {'x': 0.3, 'y': 0},
      't': 100,
      's': [3000, 400, 0],
      'to': [-1500, 900, 0],
      'ti': [0, 0, 0],
    },
    {
      't': 160,
      's': [0, 400, 0],
    },
  ],
};

void main() {
  group('bakeAutoOrient', () {
    // Reference headings for the arcs come from an independent evaluation of
    // the same curves (a dense arc-length table and bisected easing), not
    // from this package's own output.

    test('banks along a curved motion path instead of spinning', () {
      final doc = _doc({
        'p': _arcRight(),
        'r': {'a': 0, 'k': 0, 'ix': 10},
      });

      final result = bakeAutoOrient(doc);

      expect(result.layersBaked, 1);
      expect(result.skippedLayers, isEmpty);
      expect(_layer(doc)['ao'], 0);
      expect((_ks(doc)['r'] as Map)['ix'], 10);
      expect(_rotationAt(doc, 100), closeTo(30.964, 0.01));
      expect(_rotationAt(doc, 115), closeTo(11.904, 0.05));
      expect(_rotationAt(doc, 130), closeTo(-6.413, 0.05));
      expect(_rotationAt(doc, 145), closeTo(-23.168, 0.05));
      expect(_rotationAt(doc, 160), closeTo(-30.964, 0.01));
      // Held before and after the motion.
      expect(_rotationAt(doc, 90), closeTo(30.964, 0.01));
      expect(_rotationAt(doc, 170), closeTo(-30.964, 0.01));
      // One smooth bank: never turning back, never more than a few degrees
      // a frame (the reference peaks at 2.87°).
      for (var f = 100; f < 160; f++) {
        final turn = _rotationAt(doc, f + 1) - _rotationAt(doc, f);
        expect(turn, inInclusiveRange(-3, 0.01), reason: 'frame $f');
      }
    });

    test('unwraps a heading through 180° instead of spinning the long way '
        'round', () {
      final doc = _doc({'p': _arcLeft()});

      bakeAutoOrient(doc);

      expect(_rotationAt(doc, 100), closeTo(149.036, 0.01));
      expect(_rotationAt(doc, 130), closeTo(173.587, 0.05));
      expect(_rotationAt(doc, 145), closeTo(191.904, 0.05));
      expect(_rotationAt(doc, 160), closeTo(210.964, 0.01));
      for (var f = 100; f < 160; f++) {
        final turn = _rotationAt(doc, f + 1) - _rotationAt(doc, f);
        expect(turn, inInclusiveRange(-0.01, 3), reason: 'frame $f');
      }
    });

    test("places the layer along the curve by the segment's easing", () {
      final linear = _doc({
        'p': _arcRight(out: {'x': 0, 'y': 0}, into: {'x': 1, 'y': 1}),
      });
      final slowStart = _doc({
        'p': _arcRight(out: {'x': 0.9, 'y': 0}, into: {'x': 1, 'y': 1}),
      });

      bakeAutoOrient(linear);
      bakeAutoOrient(slowStart);

      // A quarter of the segment's time in: a quarter of the way along the
      // path when linear, far less with a slow start.
      expect(_rotationAt(linear, 115), closeTo(14.922, 0.05));
      expect(_rotationAt(slowStart, 115), closeTo(27.132, 0.05));
    });

    test("adds the layer's own rotation on top", () {
      final doc = _doc({
        'p': _linearPath([
          [0, 0],
          [100, 0],
        ]),
        'r': {
          'a': 1,
          'k': [
            {
              't': 0,
              's': [0],
            },
            {
              't': 10,
              's': [90],
            },
          ],
        },
      });

      bakeAutoOrient(doc);

      expect(_rotationAt(doc, 5), closeTo(45, 0.01));
      expect(_rotationAt(doc, 10), closeTo(90, 0.01));
    });

    test('writes a static rotation when the heading never changes', () {
      final doc = _doc({
        'p': _linearPath([
          [0, 0],
          [0, 100],
        ]),
        'r': {'a': 0, 'k': 15, 'ix': 10},
      });

      bakeAutoOrient(doc);

      // Straight down is 90°, plus the layer's own 15°.
      expect(_ks(doc)['r'], {'a': 0, 'k': 105, 'ix': 10});
    });

    test('snaps at a sharp corner in the motion path', () {
      final doc = _doc({
        'p': _linearPath([
          [0, 0],
          [100, 0],
          [100, 100],
        ]),
      });

      bakeAutoOrient(doc);

      expect(_rotationAt(doc, 5), closeTo(0, 0.01));
      expect(_rotationAt(doc, 10 - loopGap), closeTo(0, 0.01));
      expect(_rotationAt(doc, 10), closeTo(90, 0.01));
      expect(_rotationAt(doc, 15), closeTo(90, 0.01));
    });

    test('keeps its heading through a pause, then snaps to the new one', () {
      final doc = _doc({
        'p': _linearPath([
          [0, 0],
          [100, 0],
          [100, 0],
          [100, 100],
        ]),
      });

      bakeAutoOrient(doc);

      expect(_rotationAt(doc, 15), closeTo(0, 0.01));
      expect(_rotationAt(doc, 20 - loopGap), closeTo(0, 0.01));
      expect(_rotationAt(doc, 20), closeTo(90, 0.01));
    });

    test('orients a position with separated dimensions along its velocity', () {
      final doc = _doc({
        'p': {
          's': true,
          'x': {
            'a': 1,
            'k': [
              {
                't': 0,
                's': [0],
              },
              {
                't': 30,
                's': [100],
              },
            ],
          },
          'y': {
            'a': 1,
            'k': [
              {
                't': 0,
                's': [0],
              },
              {
                't': 30,
                's': [-100],
              },
            ],
          },
        },
      });

      bakeAutoOrient(doc);

      expect(_layer(doc)['ao'], 0);
      expect(_rotationAt(doc, 15), closeTo(-45, 0.01));
    });

    test('just turns auto-orient off on a layer that never moves, keeping its '
        'rotation', () {
      final doc = _doc({
        'p': {
          'a': 0,
          'k': [50, 50, 0],
        },
        'r': {'a': 0, 'k': 30},
      });

      final result = bakeAutoOrient(doc);

      expect(result.layersBaked, 1);
      expect(_layer(doc)['ao'], 0);
      expect(_ks(doc)['r'], {'a': 0, 'k': 30});
    });

    test('bakes layers inside precomp assets too', () {
      final doc = _doc({'p': _arcRight()});
      final layer = (doc['layers'] as List).removeLast() as Map;
      doc['assets'] = [
        {
          'id': 'comp_0',
          'layers': [layer],
        },
      ];

      final result = bakeAutoOrient(doc);

      expect(result.layersBaked, 1);
      expect(layer['ao'], 0);
    });

    test('leaves a 3D layer as-is and reports it', () {
      final doc = _doc({'p': _arcRight()}, ddd: 1);

      final result = bakeAutoOrient(doc);

      expect(result.layersBaked, 0);
      expect(result.skippedLayers.single, contains('3D'));
      expect(_layer(doc)['ao'], 1);
      expect(_ks(doc).containsKey('r'), isFalse);
    });

    test('leaves a layer whose position still has an expression as-is and '
        'reports it', () {
      final doc = _doc({
        'p': {..._arcRight(), 'x': 'wiggle(2, 30)'},
      });

      final result = bakeAutoOrient(doc);

      expect(result.layersBaked, 0);
      expect(result.skippedLayers.single, contains('expression'));
      expect(_layer(doc)['ao'], 1);
    });

    test('reports a malformed position instead of throwing', () {
      final doc = _doc({
        'p': {
          'a': 1,
          'k': [
            {'t': 0, 's': 'oops'},
            {
              't': 10,
              's': [1, 1],
            },
          ],
        },
      });

      final result = bakeAutoOrient(doc);

      expect(result.skippedLayers.single, contains('unrecognized'));
      expect(_layer(doc)['ao'], 1);
    });

    test('is a no-op the second time', () {
      final doc = _doc({'p': _arcRight()});

      expect(bakeAutoOrient(doc).changed, isTrue);
      final once = jsonEncode(doc);
      expect(bakeAutoOrient(doc).changed, isFalse);
      expect(jsonEncode(doc), once);
    });

    test('leaves lottie no auto-orient of its own to get wrong', () {
      final doc = _doc({'p': _arcRight()});
      LottieComposition parse() =>
          LottieComposition.parseJsonBytes(utf8.encode(jsonEncode(doc)));
      expect(parse().layers.single.transform.isAutoOrient, isTrue);

      bakeAutoOrient(doc);

      final composition = parse();
      expect(composition.warnings, isEmpty);
      expect(composition.layers.single.transform.isAutoOrient, isFalse);
    });
  });
}
