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
              {'t': 0, 's': [0]},
              {'t': 5, 's': [10]},
              {'t': 10, 's': [0]},
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
}
