/// Read-only inspection of a Lottie document, without mutating it.
library;

/// Report of issues found in a Lottie document, without fixing anything.
class Diagnosis {
  const Diagnosis({
    required this.audioLayers,
    required this.emptyPrecomps,
    required this.loopOutOccurrences,
  });

  /// Audio layers (`ty: 6`) across the root and all precomp assets. These
  /// crash the `lottie` Flutter package's layer parser.
  final int audioLayers;

  /// Precomp assets with an empty `layers` list.
  final int emptyPrecomps;

  /// Occurrences of the substring `loopOut` in the raw file — a rough count
  /// of expressions the `lottie` package will silently ignore, freezing the
  /// property after its last keyframe.
  final int loopOutOccurrences;

  bool get hasIssues => audioLayers > 0 || emptyPrecomps > 0 || loopOutOccurrences > 0;
}

/// Inspects a decoded Lottie [doc] (and its [rawJson] source, used to count
/// `loopOut` occurrences) without changing anything.
Diagnosis diagnose(String rawJson, Map<String, dynamic> doc) {
  var audioLayers = 0;
  var emptyPrecomps = 0;

  int countAudioLayers(List<dynamic> layers) =>
      layers.whereType<Map>().where((l) => l['ty'] == 6).length;

  audioLayers += countAudioLayers((doc['layers'] as List?) ?? const []);
  for (final asset in (doc['assets'] as List? ?? const [])) {
    if (asset is Map && asset['layers'] is List) {
      final layers = asset['layers'] as List;
      audioLayers += countAudioLayers(layers);
      if (layers.isEmpty) emptyPrecomps++;
    }
  }

  return Diagnosis(
    audioLayers: audioLayers,
    emptyPrecomps: emptyPrecomps,
    loopOutOccurrences: 'loopOut'.allMatches(rawJson).length,
  );
}
