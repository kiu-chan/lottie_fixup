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

    test('an expression on an already-keyframed property is left to '
        'bakeLoopExpressions and reported here as unsupported', () {
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

      expect(result.propertiesBaked, 0);
      expect(result.skippedExpressions, ['wiggle(2, 10)']);
      expect((layer['ks']!['o'] as Map).containsKey('x'), isTrue);
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
  });
}
