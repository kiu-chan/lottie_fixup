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

    test('loopIn closed cycle repeats backward keyframes from the start', () {
      final prop = _property([
        {
          't': 20,
          's': [0],
        },
        {
          't': 25,
          's': [10],
        },
        {
          't': 30,
          's': [0],
        }, // same as first -> closed loop
      ], "loopIn('cycle')");
      final doc = {'ip': 0, 'op': 40, 'nested': prop};

      final result = bakeLoopExpressions(doc);

      expect(result.propertiesBaked, 1);
      expect(prop.containsKey('x'), isFalse);
      final k = (prop['k'] as List).cast<Map<String, dynamic>>();
      final times = k.map((kf) => kf['t']).toList();
      // Tiled backward in 10-frame periods, covering down to (and past)
      // frame 0, then the original keyframes continue unchanged from t=20.
      expect(times.first, lessThanOrEqualTo(0));
      expect(k.last['t'], 30);
      expect(k.last['s'], [0]);
      // The original segment itself is untouched.
      expect(k.firstWhere((kf) => kf['t'] == 20)['s'], [0]);
      expect(k.firstWhere((kf) => kf['t'] == 25)['s'], [10]);
    });

    test('loopIn open cycle snaps forward to the kept segment', () {
      final prop = _property([
        {
          't': 20,
          's': [0],
        },
        {
          't': 30,
          's': [100],
        }, // differs from first -> open loop
      ], "loopIn('cycle')");
      final doc = {'ip': 0, 'op': 40, 'nested': prop};

      bakeLoopExpressions(doc);

      final k = (prop['k'] as List).cast<Map<String, dynamic>>();
      // Expect a keyframe holding the end value just before t=20 (the
      // original first keyframe), exactly loopGap before it.
      final seam = k.firstWhere(
        (kf) => (kf['t'] as num) > 19 && (kf['t'] as num) < 20,
      );
      expect(seam['s'], [100]);
      expect(seam['t'], closeTo(20 - loopGap, 1e-9));
    });

    test('loopIn does not extend before doc.ip', () {
      final prop = _property([
        {
          't': 5,
          's': [0],
        },
        {
          't': 10,
          's': [0],
        },
      ], "loopIn('cycle')");
      final doc = {'ip': 5, 'op': 40, 'nested': prop};

      final result = bakeLoopExpressions(doc);

      // t0 (5) already <= ip (5): nothing to tile backward, but the
      // expression is still stripped.
      expect(result.propertiesBaked, 1);
      expect(result.totalLoops, 0);
      expect(prop.containsKey('x'), isFalse);
      final k = (prop['k'] as List).cast<Map<String, dynamic>>();
      expect(k, [
        {
          't': 5,
          's': [0],
        },
        {
          't': 10,
          's': [0],
        },
      ]);
    });

    test('loopIn(pingpong) mirrors the segment backward, alternating with the '
        'plain shape further back', () {
      final prop = _property([
        {
          't': 20,
          's': [0],
          'i': {'x': 0.2, 'y': 0.0},
          'o': {'x': 0.8, 'y': 1.0},
        },
        {
          't': 26,
          's': [10],
        },
      ], "loopIn('pingpong')");
      final doc = {'ip': 0, 'op': 40, 'nested': prop};

      final result = bakeLoopExpressions(doc);

      expect(result.propertiesBaked, 1);
      expect(prop.containsKey('x'), isFalse);
      final k = (prop['k'] as List).cast<Map<String, dynamic>>();
      final times = k.map((kf) => kf['t']).toList();
      expect(times, orderedEquals(times.toList()..sort()));
      expect(times.first, lessThanOrEqualTo(0));
      // The tile immediately before t=20 is the mirrored segment: its
      // value at t=20 must match the recorded segment's own start (0),
      // for the animation to connect continuously across the seam.
      final mirroredTile = k.firstWhere((kf) => kf['t'] == 14);
      expect(mirroredTile['s'], [10]);
      final seam = k.firstWhere((kf) => kf['t'] == 20);
      expect(seam['s'], [0]);
      // The original segment itself is untouched.
      expect(k.firstWhere((kf) => kf['t'] == 26)['s'], [10]);
    });

    test('loopIn(pingpong) falls back to linear easing when a keyframe has '
        'none, instead of crashing', () {
      final prop = _property([
        {
          't': 0,
          's': [0],
        },
        {
          't': 5,
          's': [10],
        },
      ], "loopIn('pingpong')");
      final doc = {'ip': -20, 'op': 24, 'nested': prop};

      final result = bakeLoopExpressions(doc);

      expect(result.propertiesBaked, 1);
      expect(prop.containsKey('x'), isFalse);
    });

    test("loopOutDuration(1) repeats a fixed 1-second span (fr=30) ending at "
        'the last keyframe, holding flat wherever that span reaches before '
        'the first keyframe', () {
      final prop = _property([
        {
          't': 0,
          's': [50],
          'i': {'x': 0.667, 'y': 1},
          'o': {'x': 0.333, 'y': 0},
        },
        {
          't': 10,
          's': [150],
        },
      ], 'loopOutDuration(1)');
      final doc = {'ip': 0, 'op': 20, 'fr': 30, 'nested': prop};

      final result = bakeLoopExpressions(doc);

      expect(result.propertiesBaked, 1);
      expect(prop.containsKey('x'), isFalse);
      final k = (prop['k'] as List).cast<Map<String, dynamic>>();
      final times = k.map((kf) => kf['t']).toList();
      expect(times, orderedEquals(times.toList()..sort()));
      // One period (30 frames) is a 20-frame flat hold at 50 followed by
      // the real 10-frame ramp to 150, then (an open loop, since 50 != 150)
      // a snap back to 50 to start the next period. The first period
      // starts at t = 10 - 30 = -20.
      expect(k.first['t'], -20);
      expect(k.first['s'], [50]);
      expect(k.firstWhere((kf) => kf['t'] == 0)['s'], [50]);
      // The original ramp's own easing survives untouched.
      expect(k.firstWhere((kf) => kf['t'] == 0)['o'], {'x': 0.333, 'y': 0});
      // Just before the seam at t=10, the ramp has reached 150; at t=10
      // itself it's already snapped back to the next period's flat hold.
      final seam = k.firstWhere(
        (kf) => (kf['t'] as num) > 9 && (kf['t'] as num) < 10,
      );
      expect(seam['s'], [150]);
      expect(k.firstWhere((kf) => kf['t'] == 10)['s'], [50]);
    });

    test('loopOutDuration shorter than the keyframed segment is not supported '
        'and is reported', () {
      final prop = _property([
        {
          't': 0,
          's': [50],
        },
        {
          't': 10,
          's': [150],
        },
      ], 'loopOutDuration(0.1)'); // 3 frames at fr=30 < the 10-frame span
      final doc = {'ip': 0, 'op': 20, 'fr': 30, 'nested': prop};

      final result = bakeLoopExpressions(doc);

      expect(result.propertiesBaked, 0);
      expect(result.skippedExpressions, ['loopOutDuration(0.1)']);
    });

    test(
      "loopInDuration('pingpong', 1) is baked using the pingpong tiling",
      () {
        final prop = _property([
          {
            't': 20,
            's': [50],
          },
          {
            't': 25,
            's': [150],
          },
        ], "loopInDuration('pingpong', 1)");
        final doc = {'ip': 0, 'op': 40, 'fr': 30, 'nested': prop};

        final result = bakeLoopExpressions(doc);

        expect(result.propertiesBaked, 1);
        expect(prop.containsKey('x'), isFalse);
        final k = (prop['k'] as List).cast<Map<String, dynamic>>();
        final times = k.map((kf) => kf['t']).toList();
        expect(times, orderedEquals(times.toList()..sort()));
        expect(times.first, lessThan(0));
      },
    );

    test(
      "loopOut('offset') trends by the per-period delta, never snapping back",
      () {
        final prop = _property([
          {
            't': 0,
            's': [0],
          },
          {
            't': 10,
            's': [10],
          },
        ], "loopOut('offset')");
        final doc = {'op': 35, 'nested': prop};

        final result = bakeLoopExpressions(doc);

        expect(result.propertiesBaked, 1);
        final k = (prop['k'] as List).cast<Map<String, dynamic>>();
        expect(k.map((kf) => kf['t']).toList(), [0, 10, 20, 30, 40]);
        expect(k.map((kf) => kf['s']).toList(), [
          [0],
          [10],
          [20],
          [30],
          [40],
        ]);
      },
    );

    test("loopIn('offset') continues the same trend backward", () {
      final prop = _property([
        {
          't': 40,
          's': [100],
        },
        {
          't': 50,
          's': [110],
        },
      ], "loopIn('offset')");
      final doc = {'ip': 0, 'op': 50, 'nested': prop};

      final result = bakeLoopExpressions(doc);

      expect(result.propertiesBaked, 1);
      final k = (prop['k'] as List).cast<Map<String, dynamic>>();
      expect(k.map((kf) => kf['t']).toList(), [0, 10, 20, 30, 40, 50]);
      expect(k.map((kf) => kf['s']).toList(), [
        [60],
        [70],
        [80],
        [90],
        [100],
        [110],
      ]);
    });

    test(
      "loopOut('continue') extrapolates a straight segment at the last leg's rate",
      () {
        final prop = _property([
          {
            't': 0,
            's': [0],
          },
          {
            't': 10,
            's': [20],
          },
        ], "loopOut('continue')");
        final doc = {'op': 25, 'nested': prop};

        final result = bakeLoopExpressions(doc);

        expect(result.propertiesBaked, 1);
        final k = (prop['k'] as List).cast<Map<String, dynamic>>();
        expect(k, [
          {
            't': 0,
            's': [0],
          },
          {
            't': 10,
            's': [20],
            'o': {'x': 0.0, 'y': 0.0},
          },
          {
            't': 25,
            's': [50], // velocity 2/frame, extrapolated 15 frames past t=10
            'i': {'x': 1.0, 'y': 1.0},
          },
        ]);
      },
    );

    test(
      "loopIn('continue') extrapolates backward at the first leg's rate",
      () {
        final prop = _property([
          {
            't': 20,
            's': [0],
          },
          {
            't': 30,
            's': [20],
          },
        ], "loopIn('continue')");
        final doc = {'ip': 0, 'op': 30, 'nested': prop};

        final result = bakeLoopExpressions(doc);

        expect(result.propertiesBaked, 1);
        final k = (prop['k'] as List).cast<Map<String, dynamic>>();
        expect(k, [
          {
            't': 0,
            's': [-40], // velocity 2/frame, extrapolated 20 frames before t=20
            'o': {'x': 0.0, 'y': 0.0},
          },
          {
            't': 20,
            's': [0],
            'i': {'x': 1.0, 'y': 1.0},
          },
          {
            't': 30,
            's': [20],
          },
        ]);
      },
    );

    test(
      "loopOut('offset') on a non-numeric value (e.g. a shape path) is reported, not baked",
      () {
        final prop = _property([
          {
            't': 0,
            's': [
              {
                'i': [
                  [0, 0],
                ],
                'o': [
                  [0, 0],
                ],
                'v': [
                  [0, 0],
                ],
                'c': false,
              },
            ],
          },
          {
            't': 5,
            's': [
              {
                'i': [
                  [0, 0],
                ],
                'o': [
                  [0, 0],
                ],
                'v': [
                  [10, 10],
                ],
                'c': false,
              },
            ],
          },
        ], "loopOut('offset')");
        final doc = {'op': 24, 'nested': prop};

        final result = bakeLoopExpressions(doc);

        expect(result.propertiesBaked, 0);
        expect(result.skippedExpressions, ["loopOut('offset')"]);
        expect(prop['x'], "loopOut('offset')"); // untouched, not baked
      },
    );

    test(
      'an expression combining loopIn and loopOut is reported, not guessed',
      () {
        final prop = _property([
          {
            't': 0,
            's': [0],
          },
          {
            't': 5,
            's': [10],
          },
        ], "loopIn('cycle'); loopOut('cycle');");
        final doc = {'op': 24, 'ip': 0, 'nested': prop};

        final result = bakeLoopExpressions(doc);

        expect(result.propertiesBaked, 0);
        expect(result.skippedExpressions, [
          "loopIn('cycle'); loopOut('cycle');",
        ]);
      },
    );

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

    test('a scalar property never manually keyframed ("a": 0, "k": <num>) with '
        'an expression is reported, not silently ignored', () {
      // Mirrors bodymovin's export for e.g. opacity/rotation with an
      // expression but no keyframes: "k" is a raw number, not a list.
      final prop = {'x': 'random(50, 100)', 'k': 100};
      final doc = {'op': 60, 'nested': prop};

      final result = bakeLoopExpressions(doc);

      expect(result.propertiesBaked, 0);
      expect(result.skippedExpressions, ['random(50, 100)']);
      expect(prop['x'], 'random(50, 100)'); // untouched
      expect(prop['k'], 100); // untouched
    });

    test(
      'a multi-dimensional property never manually keyframed ("a": 0, "k": '
      '[x, y, z]") with an expression is reported, not treated as keyframes',
      () {
        // Mirrors bodymovin's export for e.g. position with an expression
        // but no keyframes: "k" is a raw numeric list, not a keyframe list.
        final prop = {
          'x': 'wiggle(2, 40)',
          'k': [100, 100, 0],
        };
        final doc = {'op': 60, 'nested': prop};

        final result = bakeLoopExpressions(doc);

        expect(result.propertiesBaked, 0);
        expect(result.skippedExpressions, ['wiggle(2, 40)']);
        expect(prop['x'], 'wiggle(2, 40)'); // untouched
        expect(prop['k'], [100, 100, 0]); // untouched
      },
    );

    test("loopOut('cycle') on a never-keyframed property is reported instead "
        'of crashing on the raw (non-keyframe) value', () {
      final prop = {
        'x': "loopOut('cycle')",
        'k': [100, 100, 0],
      };
      final doc = {'op': 60, 'nested': prop};

      final result = bakeLoopExpressions(doc);

      expect(result.propertiesBaked, 0);
      expect(result.skippedExpressions, ["loopOut('cycle')"]);
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
