import 'package:flutter_test/flutter_test.dart';
import 'package:lottie_fixup/lottie_fixup.dart';

/// A one-layer document whose transform is [ks] (plus [shapes], if given).
Map<String, dynamic> _docWith(
  Map<String, dynamic> ks, {
  List<dynamic>? shapes,
}) => {
  'layers': [
    {
      'ty': 4,
      'nm': 'shape',
      'ks': ks,
      'shapes': [...?shapes],
    },
  ],
  'assets': <dynamic>[],
};

Map _layer(Map<String, dynamic> doc) => (doc['layers'] as List).single as Map;

void main() {
  group('sanitizeCrashingLayers: keyframes without an end value', () {
    test('holds a lone keyframe that has no "e"', () {
      final doc = _docWith({
        'o': {
          'a': 1,
          'k': [
            {
              't': 10,
              's': [0],
            },
          ],
        },
      });

      final result = sanitizeCrashingLayers(doc);

      expect(result.keyframesWithoutEndValueFixed, 1);
      expect(result.changed, isTrue);
      final kf = (_layer(doc)['ks']['o']['k'] as List).single as Map;
      expect(kf['h'], 1);
      expect(kf['s'], [0]);
    });

    test('is idempotent', () {
      final doc = _docWith({
        'o': {
          'a': 1,
          'k': [
            {
              't': 10,
              's': [0],
            },
          ],
        },
      });

      sanitizeCrashingLayers(doc);
      final second = sanitizeCrashingLayers(doc);

      expect(second.keyframesWithoutEndValueFixed, 0);
      expect(second.changed, isFalse);
    });

    test('leaves a lone keyframe that has an "e" or is already a hold', () {
      final doc = _docWith({
        'o': {
          'a': 1,
          'k': [
            {
              't': 0,
              's': [0],
              'e': [100],
            },
          ],
        },
        'r': {
          'a': 1,
          'k': [
            {
              't': 0,
              's': [45],
              'h': 1,
            },
          ],
        },
      });

      final result = sanitizeCrashingLayers(doc);

      expect(result.keyframesWithoutEndValueFixed, 0);
      expect(result.changed, isFalse);
    });

    test('leaves a normal export whose last keyframe has no "e"', () {
      // Every keyframe but the last borrows its end value from the next
      // keyframe's `s`; lottie drops the last one, which only marks where
      // the previous segment ends.
      final doc = _docWith({
        'p': {
          'a': 1,
          'k': [
            {
              't': 0,
              's': [0, 0, 0],
            },
            {
              't': 10,
              's': [100, 0, 0],
            },
            {
              't': 20,
              's': [100, 100, 0],
            },
          ],
        },
      });

      final result = sanitizeCrashingLayers(doc);

      expect(result.keyframesWithoutEndValueFixed, 0);
    });

    test('holds a keyframe whose next keyframe has no "s" to borrow', () {
      final doc = _docWith({
        's': {
          'a': 1,
          'k': [
            {
              't': 0,
              's': [100, 100, 100],
            },
            {'t': 10},
          ],
        },
      });

      final result = sanitizeCrashingLayers(doc);

      expect(result.keyframesWithoutEndValueFixed, 1);
      final kfs = _layer(doc)['ks']['s']['k'] as List;
      expect(kfs.first, containsPair('h', 1));
      expect(kfs.last, isNot(contains('h')));
    });

    test('finds properties nested in shape groups and split positions', () {
      final doc = _docWith(
        {
          'p': {
            's': true,
            'x': {
              'a': 1,
              'k': [
                {
                  't': 0,
                  's': [50],
                },
              ],
            },
            'y': {'a': 0, 'k': 50},
          },
        },
        shapes: [
          {
            'ty': 'gr',
            'it': [
              {
                'ty': 'tm',
                's': {
                  'a': 1,
                  'k': [
                    {
                      't': 5,
                      's': [0],
                    },
                  ],
                },
                'e': {
                  'a': 1,
                  'k': [
                    {
                      't': 5,
                      's': [100],
                    },
                  ],
                },
                'o': {'a': 0, 'k': 0},
              },
            ],
          },
        ],
      );

      final result = sanitizeCrashingLayers(doc);

      expect(result.keyframesWithoutEndValueFixed, 3);
    });

    test('fixes layers inside a precomp asset', () {
      final doc = {
        'layers': [
          {'ty': 0, 'refId': 'comp_0', 'ks': {}},
        ],
        'assets': [
          {
            'id': 'comp_0',
            'layers': [
              {
                'ty': 4,
                'ks': {
                  'o': {
                    'a': 1,
                    'k': [
                      {
                        't': 0,
                        's': [50],
                      },
                    ],
                  },
                },
              },
            ],
          },
        ],
      };

      final result = sanitizeCrashingLayers(doc);

      expect(result.keyframesWithoutEndValueFixed, 1);
    });

    test('leaves text-document keyframes alone', () {
      final doc = {
        'layers': [
          {
            'ty': 5,
            'ks': {},
            't': {
              'd': {
                'k': [
                  {
                    't': 0,
                    's': {'t': 'Hello', 's': 40, 'f': 'Sans'},
                  },
                ],
              },
            },
          },
        ],
        'assets': <dynamic>[],
      };

      final result = sanitizeCrashingLayers(doc);

      expect(result.keyframesWithoutEndValueFixed, 0);
      expect(result.changed, isFalse);
    });
  });
}
