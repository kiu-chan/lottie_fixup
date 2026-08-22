import 'package:lottie_fixup/lottie_fixup.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _property(
  List<Map<String, dynamic>> keyframes,
  String expr,
) {
  return {'x': expr, 'k': keyframes};
}

void main() {
  group('bakeLoopExpressions', () {
    test('closed cycle loop repeats forward keyframes to the end', () {
      final prop = _property([
        {
          't': 0,
          's': [0],
        },
        {
          't': 5,
          's': [10],
        },
        {
          't': 10,
          's': [0],
        }, // same as first -> closed loop
      ], "loopOut('cycle')");
      final doc = {'op': 24, 'nested': prop};

      final result = bakeLoopExpressions(doc);

      expect(result.propertiesBaked, 1);
      expect(prop.containsKey('x'), isFalse);
      final k = (prop['k'] as List).cast<Map<String, dynamic>>();
      // Closed loop: no extra keyframe at the seam, values keep repeating
      // 0, 10, 0, 10, 0, ... every 10 frames up to (and covering) frame 24.
      final times = k.map((kf) => kf['t']).toList();
      expect(times.last, greaterThanOrEqualTo(24));
      expect(k.first['s'], [0]);
      expect(k[1]['s'], [10]);
    });

    test('open cycle loop snaps back to start with a tiny gap', () {
      final prop = _property([
        {
          't': 0,
          's': [0],
        },
        {
          't': 10,
          's': [100],
        }, // differs from first -> open loop
      ], "loopOut('cycle')");
      final doc = {'op': 24, 'nested': prop};

      bakeLoopExpressions(doc);

      final k = (prop['k'] as List).cast<Map<String, dynamic>>();
      // Expect a keyframe holding the end value just before the loop point,
      // exactly loopGap before the next period boundary.
      final seam = k.firstWhere(
        (kf) => (kf['t'] as num) > 9 && (kf['t'] as num) < 10,
      );
      expect(seam['s'], [100]);
      expect(seam['t'], closeTo(10 - loopGap, 1e-9));
    });

    test('pingpong mirrors easing and swaps spatial tangents', () {
      final prop = _property([
        {
          't': 0,
          's': [0],
          'i': {'x': 0.2, 'y': 0.0},
          'o': {'x': 0.8, 'y': 1.0},
          'to': [1, 0, 0],
          'ti': [-1, 0, 0],
        },
        {
          't': 6,
          's': [10],
        },
      ], "loopOut('pingpong')");
      final doc = {'op': 12, 'nested': prop};

      final result = bakeLoopExpressions(doc);

      expect(result.propertiesBaked, 1);
      final k = (prop['k'] as List).cast<Map<String, dynamic>>();
      // First forward segment: t=0 (s=0), t=6 (s=10).
      // Then the reverse (pingpong) segment starts at t=6 again, mirrored.
      final reverseStart = k.firstWhere((kf) => kf['t'] == 6);
      expect(reverseStart['s'], [10]);
      expect(reverseStart['o'], {'x': 1 - 0.2, 'y': 1 - 0.0});
      expect(reverseStart['i'], {'x': 1 - 0.8, 'y': 1 - 1.0});
      expect(reverseStart['to'], [-1, 0, 0]);
      expect(reverseStart['ti'], [1, 0, 0]);
    });

    test('non-loopOut expressions are left untouched and reported', () {
      final prop = _property([
        {
          't': 0,
          's': [0],
        },
        {
          't': 5,
          's': [10],
        },
      ], 'wiggle(2, 10)');
      final doc = {'op': 24, 'nested': prop};

      final result = bakeLoopExpressions(doc);

      expect(result.propertiesBaked, 0);
      expect(result.skippedExpressions, ['wiggle(2, 10)']);
      expect(prop['x'], 'wiggle(2, 10)'); // untouched
    });

    test('is a no-op on an already-baked document', () {
      final prop = _property([
        {
          't': 0,
          's': [0],
        },
        {
          't': 5,
          's': [10],
        },
        {
          't': 10,
          's': [0],
        },
      ], "loopOut('cycle')");
      final doc = {'op': 24, 'nested': prop};

      bakeLoopExpressions(doc);
      final second = bakeLoopExpressions(doc);

      expect(second.changed, isFalse);
    });
  });
}
