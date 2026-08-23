import 'package:lottie_fixup/lottie_fixup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeCrashingLayers', () {
    test('removes a root audio layer', () {
      final doc = {
        'layers': [
          {'ty': 4, 'nm': 'shape', 'ks': {}},
          {'ty': 6, 'nm': 'audio', 'refId': 'audio_0'},
        ],
        'assets': <dynamic>[],
      };

      final result = sanitizeCrashingLayers(doc);

      expect(result.audioLayersRemoved, 1);
      expect((doc['layers'] as List).length, 1);
      expect((doc['layers'] as List).single, containsPair('ty', 4));
    });

    test('removes an unreferenced empty precomp asset', () {
      final doc = {
        'layers': <dynamic>[],
        'assets': [
          {'id': 'comp_0', 'layers': <dynamic>[]},
        ],
      };

      final result = sanitizeCrashingLayers(doc);

      expect(result.emptyPrecompsRemoved, 1);
      expect(doc['assets'], isEmpty);
    });

    test('keeps an empty precomp asset still refId-ed by a layer', () {
      // Real bug encountered: a preComp layer points to an empty precomp (AE
      // exports a placeholder). Removing that asset for being "empty" leaves
      // a dangling `refId`, crashing `composition.getPrecomps(refId)!` while
      // building the render tree — later, and different from the audio
      // layer's `ks` null-check error, only surfacing at actual render
      // time rather than at JSON parse time.
      final doc = {
        'layers': [
          {'ty': 0, 'nm': 'placeholder', 'refId': 'comp_7', 'ks': {}},
        ],
        'assets': [
          {'id': 'comp_7', 'layers': <dynamic>[]},
        ],
      };

      final result = sanitizeCrashingLayers(doc);

      expect(result.changed, isFalse);
      expect(doc['assets'], hasLength(1));
    });

    test('prunes an asset only referenced by the removed audio layer', () {
      final doc = {
        'layers': [
          {'ty': 6, 'refId': 'audio_0'},
        ],
        'assets': [
          {
            'id': 'audio_0',
            'p': 'tutti.wav',
          }, // no `layers` field: an audio asset, not a precomp
        ],
      };

      final result = sanitizeCrashingLayers(doc);

      expect(result.audioLayersRemoved, 1);
      expect(result.unreferencedAssetsRemoved, 1);
      expect(doc['assets'], isEmpty);
    });

    test('keeps assets still reachable through a nested precomp', () {
      final doc = {
        'layers': [
          {'ty': 0, 'refId': 'comp_0', 'ks': {}},
        ],
        'assets': [
          {
            'id': 'comp_0',
            'layers': [
              {'ty': 4, 'refId': 'comp_1', 'ks': {}},
            ],
          },
          {
            'id': 'comp_1',
            'layers': [
              {'ty': 4, 'ks': {}},
            ],
          },
        ],
      };

      final result = sanitizeCrashingLayers(doc);

      expect(result.changed, isFalse);
      expect((doc['assets'] as List).length, 2);
    });

    test(
      'flags a non-audio layer still missing a transform, without removing it',
      () {
        final doc = {
          'layers': [
            {'ty': 4, 'nm': 'broken'}, // no `ks`, not audio -> not auto-removed
          ],
          'assets': <dynamic>[],
        };

        final result = sanitizeCrashingLayers(doc);

        expect(result.changed, isFalse);
        expect((doc['layers'] as List).length, 1);
        expect(result.layersMissingTransform, hasLength(1));
        expect(result.layersMissingTransform.single, contains('ty=4'));
      },
    );

    test('is a no-op on an already-clean document', () {
      final doc = {
        'layers': [
          {'ty': 4, 'ks': {}},
        ],
        'assets': <dynamic>[],
      };

      sanitizeCrashingLayers(doc);
      final second = sanitizeCrashingLayers(doc);

      expect(second.changed, isFalse);
    });

    test(
      'removes a precomp layer whose refId does not resolve to any asset',
      () {
        final doc = {
          'layers': [
            {'ty': 0, 'nm': 'dangling', 'refId': 'missing_comp', 'ks': {}},
            {'ty': 4, 'nm': 'shape', 'ks': {}},
          ],
          'assets': <dynamic>[],
        };

        final result = sanitizeCrashingLayers(doc);

        expect(result.precompLayersWithBadRefRemoved, 1);
        expect((doc['layers'] as List).length, 1);
        expect((doc['layers'] as List).single, containsPair('ty', 4));
      },
    );

    test('removes a precomp layer with no refId at all', () {
      final doc = {
        'layers': [
          {'ty': 0, 'nm': 'no ref', 'ks': {}},
        ],
        'assets': <dynamic>[],
      };

      final result = sanitizeCrashingLayers(doc);

      expect(result.precompLayersWithBadRefRemoved, 1);
      expect(doc['layers'], isEmpty);
    });

    test('removes a text layer missing t or t.d', () {
      final doc = {
        'layers': [
          {
            'ty': 5,
            'nm': 'caption',
            'ks': {},
            't': {
              'd': {
                'k': {'s': 'hello'},
              },
            },
          },
          {'ty': 5, 'nm': 'no t at all', 'ks': {}},
          {
            'ty': 5,
            'nm': 't without d',
            'ks': {},
            't': {'a': <dynamic>[]},
          },
        ],
        'assets': <dynamic>[],
      };

      final result = sanitizeCrashingLayers(doc);

      expect(result.textLayersMissingDataRemoved, 2);
      expect((doc['layers'] as List).length, 1);
      expect((doc['layers'] as List).single, containsPair('nm', 'caption'));
    });

    test('removes an asset entry with no usable id, keeps a numeric one', () {
      final doc = {
        'layers': <dynamic>[],
        'assets': [
          {'layers': <dynamic>[]}, // no id at all
          {'id': 42, 'layers': <dynamic>[]}, // numeric: lottie coerces fine
        ],
      };

      final result = sanitizeCrashingLayers(doc);

      expect(result.assetsMissingIdRemoved, 1);
      expect((doc['assets'] as List).length, 1);
      expect((doc['assets'] as List).single, containsPair('id', 42));
    });

    test('removes a masksProperties entry missing mode/pt/o', () {
      final doc = {
        'layers': [
          {
            'ty': 4,
            'nm': 'masked',
            'ks': {},
            'masksProperties': [
              {
                'mode': 'a',
                'pt': {'a': 0, 'k': {}},
                'o': {'a': 0, 'k': 100},
              },
              {
                'mode': 'a',
                'pt': {'a': 0, 'k': {}},
              }, // missing 'o'
            ],
          },
        ],
        'assets': <dynamic>[],
      };

      final result = sanitizeCrashingLayers(doc);

      expect(result.maskEntriesRemoved, 1);
      final layer = (doc['layers'] as List).single as Map;
      expect((layer['masksProperties'] as List).length, 1);
    });

    test('removes shape content missing required gradient/stroke fields, '
        'recursing into groups', () {
      final doc = {
        'layers': [
          {
            'ty': 4,
            'nm': 'shapes',
            'ks': {},
            'shapes': [
              {
                'ty': 'gr',
                'it': [
                  {
                    'ty': 'st',
                    'c': {
                      'a': 0,
                      'k': [1, 0, 0, 1],
                    },
                    'w': {'a': 0, 'k': 2},
                  }, // valid
                  {
                    'ty': 'st',
                    'w': {'a': 0, 'k': 2},
                  }, // missing 'c'
                ],
              },
              {
                'ty': 'gf',
                'g': {
                  'p': 2,
                  'k': {'a': 0, 'k': <dynamic>[]},
                },
                's': {
                  'a': 0,
                  'k': [0, 0],
                },
                // missing 'e'
              },
            ],
          },
        ],
        'assets': <dynamic>[],
      };

      final result = sanitizeCrashingLayers(doc);

      expect(result.malformedShapeContentRemoved, 2);
      final layer = (doc['layers'] as List).single as Map;
      final shapes = layer['shapes'] as List;
      final group = shapes.first as Map;
      expect((group['it'] as List).length, 1); // only the valid 'st'
      expect(shapes.length, 1); // the malformed top-level 'gf' is gone
    });

    test(
      'clears an out-of-range lc/lj instead of removing the whole stroke',
      () {
        final doc = {
          'layers': [
            {
              'ty': 4,
              'nm': 'stroke',
              'ks': {},
              'shapes': [
                {
                  'ty': 'st',
                  'c': {
                    'a': 0,
                    'k': [0, 0, 0, 1],
                  },
                  'w': {'a': 0, 'k': 2},
                  'lc': 9, // out of the valid 1..3 range
                },
              ],
            },
          ],
          'assets': <dynamic>[],
        };

        final result = sanitizeCrashingLayers(doc);

        expect(result.invalidStrokeCapsOrJoinsFixed, 1);
        expect(result.malformedShapeContentRemoved, 0);
        final layer = (doc['layers'] as List).single as Map;
        final shape = (layer['shapes'] as List).single as Map;
        expect(shape.containsKey('lc'), isFalse);
        expect(shape.containsKey('c'), isTrue); // rest untouched
      },
    );

    test(
      'flags (without touching) an animatable value with empty keyframes',
      () {
        final doc = {
          'layers': [
            {
              'ty': 4,
              'nm': 'broken opacity',
              'ks': {
                'o': {'a': 1, 'k': <dynamic>[]}, // animated, no keyframes
              },
            },
          ],
          'assets': <dynamic>[],
        };

        final result = sanitizeCrashingLayers(doc);

        expect(result.changed, isFalse); // diagnostic only
        expect(result.propertiesWithEmptyKeyframes, hasLength(1));
        expect(result.propertiesWithEmptyKeyframes.single, contains('ks.o'));
      },
    );
  });
}
