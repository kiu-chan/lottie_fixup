import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lottie_fixup/lottie_fixup.dart';

/// An animated time remap playing [fromSeconds] to [toSeconds] over frames
/// 0 to 50.
Map<String, dynamic> _remap(num fromSeconds, num toSeconds) => {
  'a': 1,
  'k': [
    {
      't': 0,
      's': [fromSeconds],
    },
    {
      't': 50,
      's': [toSeconds],
    },
  ],
};

Map<String, dynamic> _layer(String name, num ip, num op) => {
  'ty': 4,
  'nm': name,
  'ks': <String, dynamic>{},
  'ip': ip,
  'op': op,
  'st': 0,
};

/// A 25fps document whose root plays precomp "cycle" through [tm] (omitted
/// when null), with [layers] inside it.
Map<String, dynamic> _doc(
  List<Map<String, dynamic>> layers, {
  Map<String, dynamic>? tm,
  List<Map<String, dynamic>> extraRootLayers = const [],
}) => {
  'fr': 25,
  'ip': 0,
  'op': 100,
  'layers': [
    {
      'ty': 0,
      'nm': 'cycle layer',
      'refId': 'cycle',
      'ks': <String, dynamic>{},
      'ip': 0,
      'op': 100,
      'st': 0,
      'tm': ?tm,
    },
    ...extraRootLayers,
  ],
  'assets': [
    {'id': 'cycle', 'layers': layers},
  ],
};

Map<String, dynamic> _inner(Map<String, dynamic> doc, int index) =>
    ((doc['assets'] as List).single['layers'] as List)[index]
        as Map<String, dynamic>;

void main() {
  group('closeTimeRemapGaps', () {
    test('moves an in point one frame late back to the start of the range', () {
      // 0s-2s at 25fps: the precomp plays frames 0-50.
      final doc = _doc([
        _layer('A', 0, 51),
        _layer('B', 1, 52),
        _layer('blink', 10, 13),
      ], tm: _remap(0, 2));

      final result = closeTimeRemapGaps(doc);

      expect(result.layersExtended, 1);
      expect(result.skippedLayers, isEmpty);
      expect(result.changed, isTrue);
      expect(_inner(doc, 0)['ip'], 0);
      expect(_inner(doc, 1)['ip'], 0);
      expect(_inner(doc, 1)['op'], 52);
      // Shorter than the cycle, so meant to show only for a moment.
      expect(_inner(doc, 2)['ip'], 10);

      expect(closeTimeRemapGaps(doc).changed, isFalse);
    });

    test('moves an out point that ends early past the end of the range', () {
      // 0s-2.02s: frames 0-50.5.
      final doc = _doc([_layer('A', 0, 50)], tm: _remap(0, 2.02));

      final result = closeTimeRemapGaps(doc);

      expect(result.layersExtended, 1);
      expect(_inner(doc, 0)['ip'], 0);
      expect(_inner(doc, 0)['op'], 51);
    });

    test('reports a gap wider than one frame instead of closing it', () {
      final doc = _doc([_layer('A', 5, 60)], tm: _remap(0, 2));

      final result = closeTimeRemapGaps(doc);

      expect(result.layersExtended, 0);
      expect(result.changed, isFalse);
      expect(result.skippedLayers, [
        'ty=4 nm=A: visible from frame 5 to 60, but its precomp "cycle" is '
            'remapped across frames 0-50',
      ]);
      expect(_inner(doc, 0)['ip'], 5);
    });

    test('leaves a precomp without a time remap alone', () {
      final doc = _doc([_layer('A', 1, 52)]);

      expect(closeTimeRemapGaps(doc).changed, isFalse);
      expect(_inner(doc, 0)['ip'], 1);
    });

    test('leaves a static time remap alone', () {
      final doc = _doc([_layer('A', 1, 52)], tm: {'a': 0, 'k': 0});

      expect(closeTimeRemapGaps(doc).changed, isFalse);
      expect(_inner(doc, 0)['ip'], 1);
    });

    test('leaves a precomp also played without a remap alone', () {
      final doc = _doc(
        [_layer('A', 1, 52)],
        tm: _remap(0, 2),
        extraRootLayers: [
          {
            'ty': 0,
            'nm': 'plain',
            'refId': 'cycle',
            'ks': <String, dynamic>{},
            'ip': 0,
            'op': 100,
            'st': 0,
          },
        ],
      );

      expect(closeTimeRemapGaps(doc).changed, isFalse);
      expect(_inner(doc, 0)['ip'], 1);
    });

    test('uses the union of the ranges of every remapping layer', () {
      // One reference plays frames 0-50, the other 2-60: the union is 0-60.
      final doc = _doc(
        [_layer('A', 1, 61)],
        tm: _remap(0, 2),
        extraRootLayers: [
          {
            'ty': 0,
            'nm': 'second',
            'refId': 'cycle',
            'ks': <String, dynamic>{},
            'ip': 0,
            'op': 100,
            'st': 0,
            'tm': _remap(0.08, 2.4),
          },
        ],
      );

      expect(closeTimeRemapGaps(doc).layersExtended, 1);
      expect(_inner(doc, 0)['ip'], 0);
      expect(_inner(doc, 0)['op'], 61);
    });

    test('checks precomps nested inside other precomps', () {
      final doc = {
        'fr': 25,
        'layers': [
          {
            'ty': 0,
            'refId': 'outer',
            'ks': <String, dynamic>{},
            'ip': 0,
            'op': 100,
          },
        ],
        'assets': [
          {
            'id': 'outer',
            'layers': [
              {
                'ty': 0,
                'refId': 'inner',
                'ks': <String, dynamic>{},
                'ip': 0,
                'op': 100,
                'tm': _remap(0, 2),
              },
            ],
          },
          {
            'id': 'inner',
            'layers': [_layer('A', 1, 52)],
          },
        ],
      };

      expect(closeTimeRemapGaps(doc).layersExtended, 1);
      final inner = (doc['assets'] as List)[1]['layers'] as List;
      expect(inner.single['ip'], 0);
    });
  });

  test('fix closes the gap after baking a looping time remap', () {
    final doc = _doc(
      [_layer('A', 1, 52)],
      tm: {..._remap(0, 2), 'x': "loopOut('cycle')"},
    );

    final first = fix(doc);
    expect(first.changed, isTrue);
    expect(first.bake.propertiesBaked, 1);
    expect(first.timeRemapGaps.layersExtended, 1);
    expect(_inner(doc, 0)['ip'], 0);

    expect(fix(doc).changed, isFalse);
  });

  test('diagnose reports layers to extend and gaps it leaves', () {
    final doc = _doc([
      _layer('A', 1, 52),
      _layer('B', 5, 60),
    ], tm: _remap(0, 2));
    final raw = jsonEncode(doc);

    final report = diagnose(raw, doc);

    expect(report.hasIssues, isTrue);
    expect(report.timeRemapGaps.layersExtended, 1);
    expect(report.timeRemapGaps.skippedLayers, hasLength(1));
    expect(_inner(doc, 0)['ip'], 1);
  });
}
