/// Strips or patches pieces of a Lottie document shaped in a way that
/// crashes the `lottie` Flutter package's parser or render-tree builder —
/// layers, assets, masks, and shape content the JSON schema allows but
/// `lottie`'s own code doesn't defensively guard — and prunes assets that
/// become unreferenced as a result.
///
/// Every check here is grounded in a specific, confirmed crash in the
/// `lottie` package's source: a non-null assertion (`!`) or an unassigned
/// `late` field reached by a plausible-if-unusual JSON shape (a hand-edited
/// or non-After-Effects-authored file, not just a normal Bodymovin export).
/// This is a different concern from unexecuted expressions
/// (`bakeLoopExpressions`/`bakePropertyExpressions`), which `lottie` parses
/// fine but never evaluates.
library;

/// Lottie layer type for audio layers (`"ty": 6`).
const int audioLayerType = 6;

/// Lottie layer type for precomp layers (`"ty": 0`).
const int _precompLayerType = 0;

/// Lottie layer type for text layers (`"ty": 5`).
const int _textLayerType = 5;

/// Result of one [sanitizeCrashingLayers] call.
class SanitizeResult {
  const SanitizeResult({
    required this.audioLayersRemoved,
    required this.emptyPrecompsRemoved,
    required this.unreferencedAssetsRemoved,
    required this.layersMissingTransform,
    this.precompLayersWithBadRefRemoved = 0,
    this.textLayersMissingDataRemoved = 0,
    this.assetsMissingIdRemoved = 0,
    this.maskEntriesRemoved = 0,
    this.malformedShapeContentRemoved = 0,
    this.invalidStrokeCapsOrJoinsFixed = 0,
    this.propertiesWithEmptyKeyframes = const [],
  });

  /// Audio layers (`ty: 6`) removed. These ship without a transform block
  /// (`ks`); the `lottie` package's layer parser does a non-null assertion
  /// on it and throws `Null check operator used on a null value`, replacing
  /// the whole widget with a red error screen.
  final int audioLayersRemoved;

  /// Precomp assets with an empty `layers` list — after audio layers were
  /// stripped out of them, or already empty on input — that were also
  /// unreferenced, so safe to drop. An empty precomp still `refId`'d by a
  /// layer is *not* counted here: it's kept, since removing it would leave
  /// that layer's `refId` dangling (see [unreferencedAssetsRemoved]).
  final int emptyPrecompsRemoved;

  /// Assets no longer reachable from the root layers (or from a still
  /// reachable precomp) via `refId`, once crashing layers were stripped.
  final int unreferencedAssetsRemoved;

  /// Diagnostics only, not auto-fixed: layers (of any type) still missing a
  /// `ks` transform block after the automatic cleanup above. Any such layer
  /// will crash the same way audio layers do; investigate by hand before
  /// shipping the file.
  final List<String> layersMissingTransform;

  /// Precomp layers (`ty: 0`) removed because their `refId` didn't resolve
  /// to any asset — missing, not a string, or no `assets[].id` matched.
  /// `composition.getPrecomps(refId)!` throws building the render tree for
  /// exactly this shape. Unlike a `refId` this package's own asset pruning
  /// might otherwise dangle (already guarded against by only ever removing
  /// unreachable assets), this can be present in the input file itself —
  /// a hand-edited or merged file, for example.
  final int precompLayersWithBadRefRemoved;

  /// Text layers (`ty: 5`) removed because they're missing `t` or `t.d`
  /// (the document-data block): `lottie`'s text layer unconditionally
  /// null-checks it while being constructed, so a text layer without one
  /// crashes as soon as the composition is displayed.
  final int textLayersMissingDataRemoved;

  /// Asset entries removed because they have no usable `id` — missing,
  /// `null`, a bool, an array, or an object (a number is fine; `lottie`'s
  /// own JSON reader coerces it to a string with no error). Such an asset
  /// can never legitimately be referenced by any `refId`, and `lottie`'s
  /// parser crashes reading its own `id` while parsing the asset list —
  /// before any layer is even looked at.
  final int assetsMissingIdRemoved;

  /// Individual `masksProperties` entries removed for missing `mode`, `pt`,
  /// or `o`. Each is read into a variable with no fallback, so a mask
  /// missing one crashes while the *mask* is being built — not just later,
  /// when it would actually be applied.
  final int maskEntriesRemoved;

  /// Individual shape-content items (`gf`/`gs`/`st` — gradient fill,
  /// gradient stroke, solid stroke) removed for missing a required
  /// companion field (gradient colors/start/end point, or stroke
  /// color/width). `lottie`'s own source confirms this is a real shape a
  /// non-After-Effects Lottie producer ships: a code comment there
  /// specifically calls out Telegram omitting the sibling opacity field in
  /// these same objects.
  final int malformedShapeContentRemoved;

  /// Out-of-range `lc`/`lj` (line cap/line join) values cleared from
  /// `gs`/`st` content items, leaving the rest of that stroke untouched —
  /// the valid range is `1..3`; anything else indexes `lottie`'s internal
  /// enum list out of bounds. A missing `lc`/`lj` is already safe (an
  /// absent key never reaches this code at all); only a present-but-invalid
  /// value does.
  final int invalidStrokeCapsOrJoinsFixed;

  /// Diagnostics only, not auto-fixed: animatable-value-shaped objects
  /// (`{"a":.., "k":..}`, or a gradient's `{"p":.., "k":..}`) found with a
  /// missing or empty `k`. `lottie` crashes indexing the last element of an
  /// empty keyframe list — but there's no principled default value to
  /// inject for an arbitrary property (unlike the fixes above, which each
  /// have one obvious safe outcome: drop the one broken piece), so this is
  /// reported for hand investigation, the same way [layersMissingTransform]
  /// is. Each entry is `"<layer descriptor>: <dotted property path>"`.
  final List<String> propertiesWithEmptyKeyframes;

  bool get changed =>
      audioLayersRemoved > 0 ||
      emptyPrecompsRemoved > 0 ||
      unreferencedAssetsRemoved > 0 ||
      precompLayersWithBadRefRemoved > 0 ||
      textLayersMissingDataRemoved > 0 ||
      assetsMissingIdRemoved > 0 ||
      maskEntriesRemoved > 0 ||
      malformedShapeContentRemoved > 0 ||
      invalidStrokeCapsOrJoinsFixed > 0;
}

/// Removes crashing/dead layers, assets, masks, and shape content from
/// [doc] in place, and prunes assets left unreferenced by that removal.
SanitizeResult sanitizeCrashingLayers(Map<String, dynamic> doc) {
  // Mutated in place throughout (rather than rebuilt and reassigned):
  // callers may pass a document with a more narrowly-typed nested list than
  // plain `List<dynamic>` (any `jsonDecode` output is fine, but a
  // hand-built Map literal, e.g. in tests, can infer a stricter generic
  // type), and assigning a freshly built `List<...>` back into e.g.
  // `doc['assets']` would then fail Dart's runtime covariant-generic check.
  final assets = (doc['assets'] as List?) ?? [];

  // Asset ids usable enough for `lottie`'s own parser to read without
  // crashing: a String, or a num (its JSON reader coerces a numeric id to
  // a string with no error) -- anything else means the `late String id`
  // local in its asset parser is never assigned.
  final validAssetIds = <Object>{
    for (final a in assets)
      if (a is Map && (a['id'] is String || a['id'] is num)) a['id'] as Object,
  };
  // Only String ids are usable as a `refId` match, matching this file's
  // own `_collectRefIds`/`_reachableAssetIds` strictness elsewhere: a
  // numeric asset id can never actually be reached, since `refId` is always
  // read as a string.
  final validStringAssetIds = validAssetIds.whereType<String>().toSet();

  var audioRemoved = 0;
  var precompBadRefRemoved = 0;
  var textMissingDataRemoved = 0;
  void stripCrashingLayers(List<dynamic> layers) {
    layers.removeWhere((l) {
      if (l is! Map) return false;
      if (l['ty'] == audioLayerType) {
        audioRemoved++;
        return true;
      }
      if (l['ty'] == _precompLayerType) {
        final refId = l['refId'];
        if (refId is! String || !validStringAssetIds.contains(refId)) {
          precompBadRefRemoved++;
          return true;
        }
      }
      if (l['ty'] == _textLayerType) {
        final t = l['t'];
        if (t is! Map || !t.containsKey('d')) {
          textMissingDataRemoved++;
          return true;
        }
      }
      return false;
    });
  }

  _forEachLayerList(doc, assets, stripCrashingLayers);

  var assetsMissingIdRemoved = 0;
  assets.removeWhere((a) {
    if (a is Map && a['id'] is! String && a['id'] is! num) {
      assetsMissingIdRemoved++;
      return true;
    }
    return false;
  });

  // Only remove an asset once no layer refId's it anymore — even if it's
  // empty: a preComp layer may intentionally point to an empty precomp (an
  // AE-exported placeholder). Wrongly removing a still-referenced asset
  // leaves a dangling `refId`, causing `composition.getPrecomps(refId)!` to
  // crash while building the render tree — later, and quite different from
  // the audio layer's null-check error, so it doesn't surface at parse
  // time but only when actually rendering.
  final reachable = _reachableAssetIds(_layersOf(doc), assets);
  var emptyPrecompsRemoved = 0;
  var unreferencedRemoved = 0;
  assets.removeWhere((a) {
    if (a is! Map || a['id'] is! String || reachable.contains(a['id'])) {
      return false;
    }
    if (a['layers'] is List && (a['layers'] as List).isEmpty) {
      emptyPrecompsRemoved++;
    } else {
      unreferencedRemoved++;
    }
    return true;
  });

  var maskEntriesRemoved = 0;
  _forEachLayerList(doc, assets, (layers) {
    for (final l in layers) {
      if (l is Map && l['masksProperties'] is List) {
        final masks = l['masksProperties'] as List;
        final before = masks.length;
        masks.removeWhere(
          (m) =>
              !(m is Map &&
                  m.containsKey('mode') &&
                  m.containsKey('pt') &&
                  m.containsKey('o')),
        );
        maskEntriesRemoved += before - masks.length;
      }
    }
  });

  var malformedShapeContentRemoved = 0;
  var invalidStrokeCapsOrJoinsFixed = 0;
  void pruneShapeContent(List<dynamic> items) {
    items.removeWhere((item) {
      if (item is! Map) return false;
      // Groups are the only nesting shape in the schema; recurse into
      // their own items before deciding anything about the group itself.
      if (item['ty'] == 'gr' && item['it'] is List) {
        pruneShapeContent(item['it'] as List);
      }
      if (!_hasRequiredShapeContentFields(item)) {
        malformedShapeContentRemoved++;
        return true;
      }
      if (_clearInvalidCapOrJoin(item)) {
        invalidStrokeCapsOrJoinsFixed++;
      }
      return false;
    });
  }

  _forEachLayerList(doc, assets, (layers) {
    for (final l in layers) {
      if (l is Map && l['shapes'] is List) {
        pruneShapeContent(l['shapes'] as List);
      }
    }
  });

  final missingTransform = <String>[];
  void scanMissingTransform(List<dynamic> layers, String where) {
    for (final l in layers) {
      if (l is Map && !l.containsKey('ks')) {
        missingTransform.add('$where: ty=${l['ty']} nm=${l['nm']}');
      }
    }
  }

  scanMissingTransform(_layersOf(doc), 'root');
  for (final asset in assets) {
    if (asset is Map && asset['layers'] is List) {
      scanMissingTransform(asset['layers'] as List, 'asset ${asset['id']}');
    }
  }

  final emptyKeyframes = <String>[];
  _forEachLayerList(doc, assets, (layers) {
    for (final l in layers) {
      if (l is Map) {
        _scanEmptyKeyframes(
          l,
          '',
          'ty=${l['ty']} nm=${l['nm']}',
          emptyKeyframes,
        );
      }
    }
  });

  return SanitizeResult(
    audioLayersRemoved: audioRemoved,
    emptyPrecompsRemoved: emptyPrecompsRemoved,
    unreferencedAssetsRemoved: unreferencedRemoved,
    layersMissingTransform: missingTransform,
    precompLayersWithBadRefRemoved: precompBadRefRemoved,
    textLayersMissingDataRemoved: textMissingDataRemoved,
    assetsMissingIdRemoved: assetsMissingIdRemoved,
    maskEntriesRemoved: maskEntriesRemoved,
    malformedShapeContentRemoved: malformedShapeContentRemoved,
    invalidStrokeCapsOrJoinsFixed: invalidStrokeCapsOrJoinsFixed,
    propertiesWithEmptyKeyframes: emptyKeyframes,
  );
}

List<dynamic> _layersOf(Map<String, dynamic> doc) =>
    (doc['layers'] as List?) ?? [];

/// Runs [action] once for the root `layers` array and once for every
/// precomp asset's own `layers` array — the same "root plus every precomp"
/// scope every per-layer pass in this file needs.
void _forEachLayerList(
  Map<String, dynamic> doc,
  List<dynamic> assets,
  void Function(List<dynamic> layers) action,
) {
  action(_layersOf(doc));
  for (final asset in assets) {
    if (asset is Map && asset['layers'] is List) {
      action(asset['layers'] as List);
    }
  }
}

Set<String> _collectRefIds(List<dynamic> layers) {
  final ids = <String>{};
  for (final l in layers) {
    if (l is Map && l['refId'] is String) ids.add(l['refId'] as String);
  }
  return ids;
}

/// Asset ids reachable by following `refId` from the root layers, then
/// transitively through the layers of every reachable precomp asset.
Set<String> _reachableAssetIds(List<dynamic> rootLayers, List<dynamic> assets) {
  final assetsById = <String, dynamic>{
    for (final a in assets)
      if (a is Map && a['id'] is String) a['id'] as String: a,
  };
  final reachable = <String>{};
  final queue = [..._collectRefIds(rootLayers)];
  while (queue.isNotEmpty) {
    final id = queue.removeLast();
    if (!reachable.add(id)) continue;
    final asset = assetsById[id];
    if (asset is Map && asset['layers'] is List) {
      queue.addAll(_collectRefIds(asset['layers'] as List));
    }
  }
  return reachable;
}

/// Whether a shape-content item has every field its own `ty` requires to
/// parse without crashing. Only `gf`/`gs`/`st` have a known requirement;
/// every other content type (including `gr`, whose own nested items are
/// checked separately) is left alone.
bool _hasRequiredShapeContentFields(Map item) {
  switch (item['ty']) {
    case 'gf':
      return _hasGradientColorField(item) &&
          item.containsKey('s') &&
          item.containsKey('e');
    case 'gs':
      return _hasGradientColorField(item) &&
          item.containsKey('s') &&
          item.containsKey('e') &&
          item.containsKey('w');
    case 'st':
      return item.containsKey('c') && item.containsKey('w');
    default:
      return true;
  }
}

/// Whether a `gf`/`gs` item's gradient-color container (`g`) is present
/// with its own `k` — the two-level shape `lottie`'s gradient-color parser
/// needs to ever assign a non-null value.
bool _hasGradientColorField(Map item) {
  final g = item['g'];
  return g is Map && g.containsKey('k');
}

/// Clears an out-of-range `lc`/`lj` from a `gs`/`st` shape-content item (the
/// valid range is `1..3`), leaving the rest of the item untouched. Returns
/// whether anything was cleared.
bool _clearInvalidCapOrJoin(Map item) {
  if (item['ty'] != 'gs' && item['ty'] != 'st') return false;
  var fixed = false;
  final lc = item['lc'];
  if (lc is num && (lc < 1 || lc > 3)) {
    item.remove('lc');
    fixed = true;
  }
  final lj = item['lj'];
  if (lj is num && (lj < 1 || lj > 3)) {
    item.remove('lj');
    fixed = true;
  }
  return fixed;
}

/// Recursively finds every animatable-value-shaped object under [node] —
/// `{"a":.., "k":..}` or a gradient's `{"p":.., "k":..}` — whose `k` is
/// missing or an empty list, and records `"<layerDescriptor>: <path>"` into
/// [found]. [path] accumulates as a dotted/bracketed property path relative
/// to the layer root (e.g. `ks.r`, `shapes[0].it[1].o`).
void _scanEmptyKeyframes(
  dynamic node,
  String path,
  String layerDescriptor,
  List<String> found,
) {
  if (node is Map) {
    if ((node.containsKey('a') || node.containsKey('p')) &&
        node.containsKey('k')) {
      final k = node['k'];
      if (k == null || (k is List && k.isEmpty)) {
        found.add('$layerDescriptor: $path');
      }
    }
    for (final entry in node.entries) {
      final childPath = path.isEmpty ? '${entry.key}' : '$path.${entry.key}';
      _scanEmptyKeyframes(entry.value, childPath, layerDescriptor, found);
    }
  } else if (node is List) {
    for (var i = 0; i < node.length; i++) {
      _scanEmptyKeyframes(node[i], '$path[$i]', layerDescriptor, found);
    }
  }
}
