/// Strips Lottie layers that After Effects/Bodymovin exports but the
/// `lottie` Flutter package can't handle, and prunes assets that become
/// unreferenced as a result.
library;

/// Lottie layer type for audio layers (`"ty": 6`).
const int audioLayerType = 6;

/// Result of one [sanitizeCrashingLayers] call.
class SanitizeResult {
  const SanitizeResult({
    required this.audioLayersRemoved,
    required this.emptyPrecompsRemoved,
    required this.unreferencedAssetsRemoved,
    required this.layersMissingTransform,
  });

  /// Audio layers (`ty: 6`) removed. These ship without a transform block
  /// (`ks`); the `lottie` package's layer parser does a non-null assertion
  /// on it and throws `Null check operator used on a null value`, replacing
  /// the whole widget with a red error screen.
  final int audioLayersRemoved;

  /// Precomp assets left with an empty `layers` list after audio layers
  /// were stripped out of them (or already empty on input). Harmless to
  /// render, just dead weight.
  final int emptyPrecompsRemoved;

  /// Assets no longer reachable from the root layers (or from a still
  /// reachable precomp) via `refId`, once the above were removed.
  final int unreferencedAssetsRemoved;

  /// Diagnostics only, not auto-fixed: layers (of any type) still missing a
  /// `ks` transform block after the automatic cleanup above. Any such layer
  /// will crash the same way audio layers do; investigate by hand before
  /// shipping the file.
  final List<String> layersMissingTransform;

  bool get changed =>
      audioLayersRemoved > 0 ||
      emptyPrecompsRemoved > 0 ||
      unreferencedAssetsRemoved > 0;
}

/// Removes crashing/dead layers from [doc] in place and prunes assets left
/// unreferenced by that removal.
SanitizeResult sanitizeCrashingLayers(Map<String, dynamic> doc) {
  var audioRemoved = 0;
  void stripAudioLayers(List<dynamic> layers) {
    final before = layers.length;
    layers.removeWhere((l) => l is Map && l['ty'] == audioLayerType);
    audioRemoved += before - layers.length;
  }

  stripAudioLayers(_layersOf(doc));
  // Mutated in place (removeWhere on the very list `doc['assets']` already
  // holds) rather than rebuilt and reassigned: callers may pass a document
  // with a more narrowly-typed nested list than plain `List<dynamic>` (any
  // `jsonDecode` output is fine, but a hand-built Map literal, e.g. in
  // tests, can infer a stricter generic type), and assigning a freshly
  // built `List<...>` back into `doc['assets']` would then fail Dart's
  // runtime covariant-generic check.
  final assets = (doc['assets'] as List?) ?? [];
  for (final asset in assets) {
    if (asset is Map && asset['layers'] is List) {
      stripAudioLayers(asset['layers'] as List);
    }
  }

  final beforeEmpty = assets.length;
  assets.removeWhere(
    (a) => a is Map && a['layers'] is List && (a['layers'] as List).isEmpty,
  );
  final emptyPrecompsRemoved = beforeEmpty - assets.length;

  final reachable = _reachableAssetIds(_layersOf(doc), assets);
  final beforeUnref = assets.length;
  assets.removeWhere(
    (a) => a is Map && a['id'] is String && !reachable.contains(a['id']),
  );
  final unreferencedRemoved = beforeUnref - assets.length;

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

  return SanitizeResult(
    audioLayersRemoved: audioRemoved,
    emptyPrecompsRemoved: emptyPrecompsRemoved,
    unreferencedAssetsRemoved: unreferencedRemoved,
    layersMissingTransform: missingTransform,
  );
}

List<dynamic> _layersOf(Map<String, dynamic> doc) => (doc['layers'] as List?) ?? [];

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
