import 'dart:convert';

import 'package:lottie_fixup/lottie_fixup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('diagnose', () {
    test(
      'reports audio layers, empty precomps and bakeable loop expressions',
      () {
        final doc = {
          'op': 24,
          'layers': [
            {'ty': 6, 'refId': 'audio_0'},
            {
              'ty': 4,
              'ks': {
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
                ],
              },
            },
          ],
          'assets': [
            {'id': 'precomp_0', 'layers': <dynamic>[]},
          ],
        };
        final raw = jsonEncode(doc);

        final report = diagnose(raw, doc);

        expect(report.hasIssues, isTrue);
        expect(report.audioLayers, 1);
        expect(report.emptyPrecomps, 1);
        expect(report.loopExpressionsToBake, 1);
        expect(report.unsupportedExpressions, isEmpty);
      },
    );

    test('reports a wiggle() layered on real keyframes as bakeable, not '
        'unsupported', () {
      final doc = {
        'op': 24,
        'layers': [
          {
            'ty': 4,
            'ks': {
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
          },
        ],
      };
      final raw = jsonEncode(doc);

      final report = diagnose(raw, doc);

      expect(report.hasIssues, isTrue);
      expect(report.loopExpressionsToBake, 0);
      expect(report.propertyExpressionsToBake, 1);
      expect(report.unsupportedExpressions, isEmpty);
    });

    test('reports a truly unsupported expression without baking it', () {
      final doc = {
        'op': 24,
        'layers': [
          {
            'ty': 4,
            'ks': {'x': 'effect("Slider Control")("Slider")', 'k': 100},
          },
        ],
      };
      final raw = jsonEncode(doc);

      final report = diagnose(raw, doc);

      expect(report.hasIssues, isTrue);
      expect(report.propertyExpressionsToBake, 0);
      expect(report.unsupportedExpressions, [
        'effect("Slider Control")("Slider")',
      ]);
    });

    test('does not mutate the caller-provided doc', () {
      final doc = {
        'op': 24,
        'layers': [
          {
            'ty': 4,
            'ks': {
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
              ],
            },
          },
        ],
      };
      final raw = jsonEncode(doc);

      diagnose(raw, doc);

      final ks = doc['layers'] as List;
      final firstLayer = ks.first as Map;
      expect((firstLayer['ks'] as Map).containsKey('x'), isTrue);
    });

    test('no issues on a clean document', () {
      final doc = {
        'op': 24,
        'layers': [
          {'ty': 4, 'ks': <String, dynamic>{}},
        ],
      };
      final raw = jsonEncode(doc);

      final report = diagnose(raw, doc);

      expect(report.hasIssues, isFalse);
    });

    test('surfaces sanitizeCrashingLayers findings via report.sanitize', () {
      final doc = {
        'op': 24,
        'layers': [
          {'ty': 6, 'refId': 'audio_0'},
          {'ty': 4, 'nm': 'broken'}, // no ks
        ],
        'assets': <dynamic>[],
      };
      final raw = jsonEncode(doc);

      final report = diagnose(raw, doc);

      expect(report.sanitize.audioLayersRemoved, 1);
      expect(report.sanitize.layersMissingTransform, hasLength(1));
      expect(report.hasIssues, isTrue);
    });

    test('sanitize findings never change the bake counts, even when sanitize '
        'would remove a layer that also carries an expression', () {
      final doc = {
        'op': 24,
        'layers': [
          {
            'ty': 0,
            // Dangling: sanitize would remove this layer (see
            // sanitize_crashing_layers_test.dart), since it points at an
            // asset that doesn't exist.
            'refId': 'missing_comp',
            'ks': {
              'r': {'a': 0, 'k': 0, 'x': 'time * 180'},
            },
          },
        ],
        'assets': <dynamic>[],
      };
      final raw = jsonEncode(doc);

      final report = diagnose(raw, doc);

      // sanitize (its own separate decode) reports the dangling precomp.
      expect(report.sanitize.precompLayersWithBadRefRemoved, 1);
      // The bake passes (their own shared decode, untouched by sanitize)
      // still see and report the expression on that same layer.
      expect(report.propertyExpressionsToBake, 1);
    });
  });
}
