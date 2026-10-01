import 'package:flutter_test/flutter_test.dart';
import 'package:lottie_fixup/lottie_fixup.dart';

Map<String, dynamic> _slider(String name) => {
  'ty': 5,
  'nm': name,
  'mn': 'ADBE Slider Control',
  'ef': [
    {
      'ty': 0,
      'nm': 'Slider',
      'v': {'a': 0, 'k': 1},
    },
  ],
};

void main() {
  group('stripUnsupportedEffects', () {
    test('removes expression controls and the emptied "ef" key', () {
      final doc = {
        'layers': [
          {
            'ty': 4,
            'ks': {},
            'ef': [_slider('Speed'), _slider('Amount')],
          },
        ],
        'assets': <dynamic>[],
      };

      final result = stripUnsupportedEffects(doc);

      expect(result.effectsRemoved, 2);
      expect(result.layersCleared, 1);
      expect(result.effectNames, ['Speed', 'Amount']);
      expect(result.changed, isTrue);
      expect((doc['layers'] as List).single, isNot(contains('ef')));
    });

    test('keeps blur and drop shadow, removing only the rest', () {
      final doc = {
        'layers': [
          {
            'ty': 4,
            'ks': {},
            'ef': [
              {'ty': 29, 'nm': 'Gaussian Blur', 'ef': <dynamic>[]},
              _slider('Speed'),
              {'ty': 25, 'nm': 'Drop Shadow', 'ef': <dynamic>[]},
            ],
          },
        ],
        'assets': <dynamic>[],
      };

      final result = stripUnsupportedEffects(doc);

      expect(result.effectsRemoved, 1);
      expect(result.layersCleared, 0);
      final ef = ((doc['layers'] as List).single as Map)['ef'] as List;
      expect(ef.map((e) => e['ty']), [29, 25]);
    });

    test('removes an "ef" key that is already empty', () {
      final doc = {
        'layers': [
          {'ty': 4, 'ks': {}, 'ef': <dynamic>[]},
        ],
        'assets': <dynamic>[],
      };

      final result = stripUnsupportedEffects(doc);

      expect(result.effectsRemoved, 0);
      expect(result.layersCleared, 1);
      expect(result.changed, isTrue);
    });

    test('strips layers inside precomp assets, and is idempotent', () {
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
                'ks': {},
                'ef': [_slider('Speed')],
              },
            ],
          },
        ],
      };

      final first = stripUnsupportedEffects(doc);
      final second = stripUnsupportedEffects(doc);

      expect(first.effectsRemoved, 1);
      expect(second.changed, isFalse);
    });

    test('leaves a layer with no effects untouched', () {
      final doc = {
        'layers': [
          {'ty': 4, 'ks': {}},
        ],
        'assets': <dynamic>[],
      };

      expect(stripUnsupportedEffects(doc).changed, isFalse);
    });
  });
}
