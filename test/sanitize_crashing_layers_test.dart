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
      // Bug thật đã gặp: một layer preComp trỏ tới precomp rỗng (AE xuất
      // placeholder). Xoá asset đó vì "rỗng" để lại `refId` treo, crash
      // `composition.getPrecomps(refId)!` lúc dựng render tree — muộn hơn
      // và khác lỗi null-check `ks` của layer audio, chỉ lộ ra khi render
      // thật chứ không phải lúc parse JSON.
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
  });
}
