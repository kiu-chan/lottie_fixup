import 'package:lottie_fixup/lottie_fixup.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _layer(String name, Map<String, dynamic> ks, {int? ind}) {
  return {'nm': name, if (ind != null) 'ind': ind, 'ty': 4, 'ks': ks};
}

void main() {
  group('bakePropertyExpressions', () {
    test('continuous time-based rotation is sampled every frame', () {
      final layer = _layer('spin box', {
        'r': {'a': 0, 'k': 0, 'x': 'var \$bm_rt;\n\$bm_rt = time * 180;'},
      });
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 60,
        'layers': [layer],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.propertiesBaked, 1);
      final r = layer['ks']!['r'] as Map<String, dynamic>;
      expect(r.containsKey('x'), isFalse);
      expect(r['a'], 1);
      final k = (r['k'] as List).cast<Map<String, dynamic>>();
      expect(k.length, 61); // one keyframe per frame, 0..60 inclusive
      expect(k.first, {
        't': 0,
        's': [0],
      });
      expect(k.last['t'], 60);
      expect((k.last['s'] as List).first, closeTo(360, 1e-9)); // 2s * 180/s
    });

    test('a bare cross-layer transform reference copies keyframes exactly', () {
      final driver = _layer('Driver', {
        'p': {
          'a': 1,
          'k': [
            {
              'i': {'x': 0.667, 'y': 1},
              'o': {'x': 0.333, 'y': 0},
              't': 0,
              's': [60, 60, 0],
            },
            {
              't': 30,
              's': [140, 140, 0],
            },
          ],
        },
      });
      final follower = _layer('Follower', {
        'p': {
          'a': 0,
          'k': [60, 60, 0],
          'x':
              "var \$bm_rt;\n\$bm_rt = thisComp.layer('Driver').transform.position;",
        },
      });
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 60,
        'layers': [driver, follower],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.propertiesBaked, 1);
      final p = follower['ks']!['p'] as Map<String, dynamic>;
      expect(p.containsKey('x'), isFalse);
      expect(p['a'], 1);
      // Exact copy: same keyframe count/values/easing as the source, not a
      // dense per-frame resample.
      expect(p['k'], driver['ks']!['p']!['k']);
    });

    test(
      'a cross-layer reference combined with arithmetic is densely sampled',
      () {
        final driver = _layer('Driver', {
          'r': {
            'a': 1,
            'k': [
              {
                't': 0,
                's': [0],
              },
              {
                't': 10,
                's': [100],
              },
            ],
          },
        });
        final follower = _layer('Follower', {
          'r': {
            'a': 0,
            'k': 0,
            'x':
                "var \$bm_rt;\n\$bm_rt = thisComp.layer('Driver').transform.rotation + 10;",
          },
        });
        final doc = {
          'fr': 30,
          'ip': 0,
          'op': 10,
          'layers': [driver, follower],
        };

        final result = bakePropertyExpressions(doc);

        expect(result.propertiesBaked, 1);
        final r = follower['ks']!['r'] as Map<String, dynamic>;
        expect(r['a'], 1);
        final k = (r['k'] as List).cast<Map<String, dynamic>>();
        expect(k.first['s'], [10]); // driver=0 at t=0, +10
        expect(k.last['s'], [110]); // driver=100 at t=10, +10
      },
    );

    test('random(min, max) bakes a deterministic, held per-frame value', () {
      final layer = _layer('random box', {
        'o': {
          'a': 0,
          'k': 100,
          'x': 'var \$bm_rt;\n\$bm_rt = random(50, 100);',
        },
      });
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 60,
        'layers': [layer],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.propertiesBaked, 1);
      final o = layer['ks']!['o'] as Map<String, dynamic>;
      expect(o['a'], 1);
      final k = (o['k'] as List).cast<Map<String, dynamic>>();
      expect(k.length, 61);
      for (final kf in k) {
        final v = (kf['s'] as List).first as num;
        expect(v, greaterThanOrEqualTo(50));
        expect(v, lessThanOrEqualTo(100));
      }
      // Held (not interpolated) between frames, matching AE's per-frame
      // flicker — every non-last keyframe is a hold.
      for (final kf in k.sublist(0, k.length - 1)) {
        expect(kf['h'], 1);
      }
      expect(k.last.containsKey('h'), isFalse);

      // Deterministic: baking an identical document again yields the same
      // sequence of values (same seed derived from layer name + expression).
      final again = _layer('random box', {
        'o': {
          'a': 0,
          'k': 100,
          'x': 'var \$bm_rt;\n\$bm_rt = random(50, 100);',
        },
      });
      final againDoc = {
        'fr': 30,
        'ip': 0,
        'op': 60,
        'layers': [again],
      };
      bakePropertyExpressions(againDoc);
      expect((again['ks']!['o'] as Map)['k'], k);
    });

    test('wiggle(freq, amp) jitters around the base value, per axis', () {
      final layer = _layer('wiggle box', {
        'p': {
          'a': 0,
          'k': [100, 100, 0],
          'x': 'var \$bm_rt;\n\$bm_rt = wiggle(2, 40);',
        },
      });
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 60,
        'layers': [layer],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.propertiesBaked, 1);
      final p = layer['ks']!['p'] as Map<String, dynamic>;
      expect(p['a'], 1);
      final k = (p['k'] as List).cast<Map<String, dynamic>>();
      expect(k.length, 61);
      for (final kf in k) {
        final s = (kf['s'] as List).cast<num>();
        expect(s.length, 3);
        expect(s[0], inInclusiveRange(60, 140));
        expect(s[1], inInclusiveRange(60, 140));
        expect(s[2], inInclusiveRange(-40, 40));
      }
      // Not every sample is identical — it's actually wiggling.
      final distinctFirstComponents = k
          .map((kf) => (kf['s'] as List).first)
          .toSet();
      expect(distinctFirstComponents.length, greaterThan(1));
    });

    test('wiggle() layered on top of real keyframes jitters around the '
        'interpolated original curve, matching how AE evaluates it', () {
      final layer = _layer('box', {
        'o': {
          'x': 'wiggle(2, 10)',
          'k': [
            {
              't': 0,
              's': [0],
            },
            {
              't': 5,
              's': [10],
            },
          ],
        },
      });
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 24,
        'layers': [layer],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.propertiesBaked, 1);
      final o = layer['ks']!['o'] as Map<String, dynamic>;
      expect(o.containsKey('x'), isFalse);
      expect(o['a'], 1);
      final k = (o['k'] as List).cast<Map<String, dynamic>>();
      expect(k.length, 25); // one keyframe per frame, 0..24 inclusive
      // The base curve ramps 0 -> 10 over frames 0..5, then holds at 10;
      // wiggle(2, 10) jitters +/-10 around whatever that base is.
      expect((k.first['s'] as List).first, inInclusiveRange(-10, 10));
      expect((k.last['s'] as List).first, inInclusiveRange(0, 20));
    });

    test('an unresolvable cross-layer reference is reported, not guessed', () {
      final layer = _layer('Follower', {
        'p': {
          'a': 0,
          'k': [0, 0, 0],
          'x':
              "var \$bm_rt;\n\$bm_rt = thisComp.layer('Missing').transform.position;",
        },
      });
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 60,
        'layers': [layer],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.propertiesBaked, 0);
      expect(result.skippedExpressions, [
        "var \$bm_rt;\n\$bm_rt = thisComp.layer('Missing').transform.position;",
      ]);
    });

    test('is a no-op on a document with no expressions', () {
      final layer = _layer('plain', {
        'o': {'a': 0, 'k': 100},
      });
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 60,
        'layers': [layer],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.changed, isFalse);
    });

    test('if/else branches on time, switching the value at the boundary', () {
      final layer = _layer('conditional box', {
        'p': {
          'a': 0,
          'k': [100, 100, 0],
          'x':
              'var \$bm_rt;\n'
              'if (time < 1) {\n'
              '\$bm_rt = [40, 100, 0];\n'
              '} else {\n'
              '\$bm_rt = [160, 100, 0];\n'
              '}',
        },
      });
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 60,
        'layers': [layer],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.propertiesBaked, 1);
      final k = ((layer['ks']!['p'] as Map)['k'] as List)
          .cast<Map<String, dynamic>>();
      final byFrame = {for (final kf in k) kf['t'] as num: kf['s']};
      expect(byFrame[29], [40, 100, 0]);
      expect(byFrame[30], [160, 100, 0]); // t=30/30fr = 1.0s, else branch
      expect(byFrame[60], [160, 100, 0]);
    });

    test('Math.* namespace functions and constants are supported', () {
      final layer = _layer('pulsing box', {
        's': {
          'a': 0,
          'k': [100, 100, 100],
          'x':
              'var \$bm_rt;\n'
              'var s = 100 + Math.sin(time * Math.PI) * 30;\n'
              '\$bm_rt = [s, s, 100];',
        },
      });
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 60,
        'layers': [layer],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.propertiesBaked, 1);
      final k = ((layer['ks']!['s'] as Map)['k'] as List)
          .cast<Map<String, dynamic>>();
      // At t=0, sin(0) == 0, so s == 100.
      expect((k.first['s'] as List)[0], closeTo(100, 1e-9));
      expect((k.first['s'] as List)[2], 100); // untouched third component
      // Actually oscillates, not stuck at 100.
      final distinct = k.map((kf) => (kf['s'] as List)[0]).toSet();
      expect(distinct.length, greaterThan(1));
    });

    test('linear() ramps between two values over a time window', () {
      final layer = _layer('fading box', {
        'o': {
          'a': 0,
          'k': 100,
          'x': 'var \$bm_rt;\n\$bm_rt = linear(time, 0, 1, 0, 100);',
        },
      });
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 60,
        'layers': [layer],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.propertiesBaked, 1);
      final k = ((layer['ks']!['o'] as Map)['k'] as List)
          .cast<Map<String, dynamic>>();
      final byFrame = {
        for (final kf in k) kf['t'] as num: (kf['s'] as List).first,
      };
      expect(byFrame[0], closeTo(0, 1e-9));
      expect(byFrame[15], closeTo(50, 1e-9)); // halfway through the 1s ramp
      expect(byFrame[30], closeTo(100, 1e-9)); // t=1s, ramp complete
      expect(byFrame[60], closeTo(100, 1e-9)); // held past the ramp
    });

    test('add()/value combine to offset a property by a constant vector', () {
      final layer = _layer('offset box', {
        'p': {
          'a': 0,
          'k': [100, 100, 0],
          'x': 'var \$bm_rt;\n\$bm_rt = add(value, [0, -60, 0]);',
        },
      });
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 10,
        'layers': [layer],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.propertiesBaked, 1);
      final k = ((layer['ks']!['p'] as Map)['k'] as List)
          .cast<Map<String, dynamic>>();
      for (final kf in k) {
        expect(kf['s'], [100, 40, 0]);
      }
    });

    test('.valueAtTime(t) samples a cross-layer reference at a different time, '
        'not the current frame', () {
      final driver = _layer('Driver', {
        'p': {
          'a': 1,
          'k': [
            {
              't': 0,
              's': [40, 100, 0],
            },
            {
              't': 30,
              's': [160, 100, 0],
            },
          ],
        },
      });
      final follower = _layer('Follower', {
        'p': {
          'a': 0,
          'k': [40, 100, 0],
          'x':
              "var \$bm_rt;\n\$bm_rt = "
              "thisComp.layer('Driver').transform.position.valueAtTime(time - 0.3);",
        },
      });
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 60,
        'layers': [driver, follower],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.propertiesBaked, 1);
      final k = ((follower['ks']!['p'] as Map)['k'] as List)
          .cast<Map<String, dynamic>>();
      final byFrame = {for (final kf in k) kf['t'] as num: kf['s']};
      // 0.3s == 9 frames at 30fps: the follower should lag the driver by
      // exactly that many frames.
      expect(byFrame[9], [40, 100, 0]); // driver hasn't started moving yet
      expect(byFrame[10], [44.0, 100.0, 0.0]); // == driver's value at t=1
      expect(byFrame[39], [160, 100, 0]); // == driver's value at t=30
    });

    test('posterizeTime(fps) holds wiggle() to a fixed number of updates per '
        'second instead of interpolating every frame', () {
      final layer = _layer('stepped box', {
        'r': {
          'a': 0,
          'k': 0,
          'x': 'var \$bm_rt;\nposterizeTime(6);\n\$bm_rt = wiggle(3, 30);',
        },
      });
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 20,
        'layers': [layer],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.propertiesBaked, 1);
      final k = ((layer['ks']!['r'] as Map)['k'] as List)
          .cast<Map<String, dynamic>>();
      final byFrame = {
        for (final kf in k) kf['t'] as num: (kf['s'] as List).first,
      };
      // 30fps posterized to 6 updates/second == held for 5-frame windows.
      expect(byFrame[0], byFrame[1]);
      expect(byFrame[1], byFrame[2]);
      expect(byFrame[2], byFrame[3]);
      expect(byFrame[3], byFrame[4]);
      expect(byFrame[4], isNot(byFrame[5])); // next window, new value
      expect(byFrame[5], byFrame[9]);
    });

    test('wiggle()-only expression on a shape path wiggles each vertex '
        'independently, leaving tangents and closedness untouched', () {
      final pathProp = {
        'a': 0,
        'k': {
          'i': [
            [0, 0],
            [0, 0],
          ],
          'o': [
            [0, 0],
            [0, 0],
          ],
          'v': [
            [-40, 0],
            [40, 0],
          ],
          'c': false,
        },
        'x': 'var \$bm_rt;\n\$bm_rt = wiggle(2, 15);',
      };
      final layer = {
        'nm': 'wiggly path',
        'ty': 4,
        'ks': {
          'p': {
            'a': 0,
            'k': [0, 0, 0],
          },
        },
        'shapes': [
          {
            'ty': 'gr',
            'it': [
              {'ty': 'sh', 'ks': pathProp},
            ],
          },
        ],
      };
      final doc = {
        'fr': 30,
        'ip': 0,
        'op': 30,
        'layers': [layer],
      };

      final result = bakePropertyExpressions(doc);

      expect(result.propertiesBaked, 1);
      expect(pathProp.containsKey('x'), isFalse);
      expect(pathProp['a'], 1);
      final k = (pathProp['k'] as List).cast<Map<String, dynamic>>();
      expect(k.length, 31);
      for (final kf in k) {
        final shape = (kf['s'] as List).single as Map;
        expect(shape['c'], false);
        expect(shape['i'], [
          [0, 0],
          [0, 0],
        ]);
        expect(shape['o'], [
          [0, 0],
          [0, 0],
        ]);
        final v = (shape['v'] as List).cast<List>();
        expect(v.length, 2);
      }
      // Vertices actually move, and the two vertices don't move in lockstep
      // (each has its own seed).
      final firstVertexXs = k
          .map((kf) => ((kf['s'] as List).single as Map)['v'][0][0])
          .toSet();
      expect(firstVertexXs.length, greaterThan(1));
      expect(k.first['s'][0]['v'][0], isNot(k.first['s'][0]['v'][1]));
    });
  });
}
