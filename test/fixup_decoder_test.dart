import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lottie_fixup/lottie_fixup.dart';

void main() {
  test('fixes a raw, unbaked After Effects export at load time', () async {
    // Mô phỏng bản xuất Bodymovin thô: 1 shape layer dùng loopOut('cycle')
    // trên vị trí (chỉ có 2 keyframe cho 1 chu kỳ ngắn) + 1 layer audio
    // không có `ks` — đúng hai lỗi thực tế lottie_fixup xử lý.
    final raw = jsonEncode({
      'v': '5.5.2',
      'fr': 30,
      'ip': 0,
      'op': 60,
      'w': 200,
      'h': 200,
      'nm': 'raw export',
      'ddd': 0,
      'assets': <dynamic>[],
      'layers': [
        {
          'ddd': 0,
          'ind': 1,
          'ty': 4,
          'nm': 'shape',
          'sr': 1,
          'ks': {
            'o': {'a': 0, 'k': 100},
            'r': {'a': 0, 'k': 0},
            'p': {
              'a': 1,
              'x': "loopOut('cycle')",
              'k': [
                {
                  't': 0,
                  's': [0, 0, 0],
                },
                {
                  't': 30,
                  's': [100, 0, 0],
                },
              ],
            },
            'a': {
              'a': 0,
              'k': [0, 0, 0],
            },
            's': {
              'a': 0,
              'k': [100, 100, 100],
            },
          },
          'ao': 0,
          'shapes': [
            {
              'ty': 'rc',
              'p': {
                'a': 0,
                'k': [0, 0],
              },
              's': {
                'a': 0,
                'k': [50, 50],
              },
              'r': {'a': 0, 'k': 0},
            },
          ],
          'ip': 0,
          'op': 60,
          'st': 0,
          'bm': 0,
        },
        {
          'ddd': 0,
          'ind': 2,
          'ty': 6,
          'nm': 'audio',
          'sr': 1,
          'ip': 0,
          'op': 60,
          'st': 0,
          'bm': 0,
        },
      ],
    });

    final composition = await fixupLottieDecoder(utf8.encode(raw));

    expect(composition, isNotNull);
    // Không throw (layer audio thiếu `ks` không còn ở đó để làm crash parser)
    // và không còn cảnh báo "doesn't support expressions" (loopOut đã bake).
    expect(composition!.warnings, isEmpty);
    expect(composition.layers, hasLength(1)); // layer audio đã bị gỡ
  });

  test('is a no-op on an already-clean file', () async {
    final raw = jsonEncode({
      'v': '5.5.2',
      'fr': 30,
      'ip': 0,
      'op': 30,
      'w': 200,
      'h': 200,
      'nm': 'clean',
      'ddd': 0,
      'assets': <dynamic>[],
      'layers': [
        {
          'ddd': 0,
          'ind': 1,
          'ty': 4,
          'nm': 'shape',
          'sr': 1,
          'ks': {
            'o': {'a': 0, 'k': 100},
            'r': {'a': 0, 'k': 0},
            'p': {
              'a': 0,
              'k': [0, 0, 0],
            },
            'a': {
              'a': 0,
              'k': [0, 0, 0],
            },
            's': {
              'a': 0,
              'k': [100, 100, 100],
            },
          },
          'ao': 0,
          'shapes': [
            {
              'ty': 'rc',
              'p': {
                'a': 0,
                'k': [0, 0],
              },
              's': {
                'a': 0,
                'k': [50, 50],
              },
              'r': {'a': 0, 'k': 0},
            },
          ],
          'ip': 0,
          'op': 30,
          'st': 0,
          'bm': 0,
        },
      ],
    });

    final composition = await fixupLottieDecoder(utf8.encode(raw));

    expect(composition, isNotNull);
    expect(composition!.warnings, isEmpty);
    expect(composition.layers, hasLength(1));
  });
}
