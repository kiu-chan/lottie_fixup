import 'dart:convert';

import 'package:lottie_fixup/lottie_fixup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fix applies both sanitize and bake, and settles after one pass', () {
    final doc = {
      'op': 24,
      'layers': [
        {'ty': 6, 'refId': 'audio_0'},
        {
          'ty': 4,
          'ks': {},
          'ks_wiggle': {
            'x': "loopOut('cycle')",
            'k': [
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
            ],
          },
        },
      ],
      'assets': [
        {'id': 'audio_0', 'p': 'tutti.wav'},
      ],
    };

    final first = fix(doc);
    expect(first.changed, isTrue);
    expect(first.sanitize.audioLayersRemoved, 1);
    expect(first.sanitize.unreferencedAssetsRemoved, 1);
    expect(first.bake.propertiesBaked, 1);

    final second = fix(doc);
    expect(second.changed, isFalse);
  });

  test('fix forwards options to bakePropertyExpressions', () {
    final doc = {
      'fr': 30,
      'ip': 0,
      'op': 60,
      'layers': [
        {
          'ty': 4,
          'ks': {
            'p': {
              'a': 0,
              'k': [100, 100, 0],
              'x': 'var \$bm_rt;\n\$bm_rt = wiggle(2, 40);',
            },
          },
        },
      ],
    };

    final result = fix(
      doc,
      options: const BakeOptions(bakeRandomAndWiggle: false),
    );

    expect(result.propertyBake.propertiesBaked, 0);
    expect(result.propertyBake.skippedExpressions, isNotEmpty);
  });

  test('fix orients a layer along the position the loop bake just baked', () {
    final doc =
        jsonDecode(
              jsonEncode({
                'op': 40,
                'layers': [
                  {
                    'ty': 3,
                    'nm': 'layer',
                    'ao': 1,
                    'ks': {
                      'p': {
                        'a': 1,
                        'x': "loopOut('cycle')",
                        'k': [
                          {
                            't': 0,
                            's': [0, 0],
                          },
                          {
                            't': 10,
                            's': [100, 0],
                          },
                        ],
                      },
                    },
                  },
                ],
              }),
            )
            as Map<String, dynamic>;

    final result = fix(doc);

    expect(result.bake.propertiesBaked, 1);
    expect(result.autoOrient.layersBaked, 1);
    expect(result.autoOrient.skippedLayers, isEmpty);
    // Always heading right: the loop's jump back to the start is a teleport,
    // not a heading, so the layer never turns around to face it.
    final r = ((doc['layers'] as List).single as Map)['ks']['r'] as Map;
    expect(r, {'a': 0, 'k': 0});
    expect(fix(doc).changed, isFalse);
  });

  test(
    'fix holds keyframes without an end value and strips ignored effects',
    () {
      final doc = {
        'op': 24,
        'layers': [
          {
            'ty': 4,
            'ks': {
              'r': {
                'a': 1,
                'k': [
                  {
                    't': 0,
                    's': [90],
                  },
                ],
              },
            },
            'ef': [
              {'ty': 5, 'nm': 'Speed', 'ef': <dynamic>[]},
            ],
          },
        ],
        'assets': <dynamic>[],
      };

      final first = fix(doc);
      expect(first.changed, isTrue);
      expect(first.sanitize.keyframesWithoutEndValueFixed, 1);
      expect(first.effects.effectsRemoved, 1);
      expect(first.effects.effectNames, ['Speed']);

      expect(fix(doc).changed, isFalse);
    },
  );
}
