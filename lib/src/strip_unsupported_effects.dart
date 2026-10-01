/// Removes layer effects (`ef`) the `lottie` Flutter package never renders,
/// so a composition loads without its "Lottie doesn't support layer effects"
/// warning.
///
/// `lottie`'s layer parser reads only two effect types out of a layer's
/// `ef` list — Gaussian Blur (`"ty": 29`) and Drop Shadow (`"ty": 25`) — and
/// skips every other entry. But it adds the warning for *any* `ef` key, even
/// one holding nothing but those two. The usual culprits are After Effects
/// Expression Controls (Slider/Angle/Checkbox/Color/Point/Layer Control,
/// exported as `"ty": 5` groups) that a rig's expressions read their
/// parameters from, plus effects `lottie` can't draw (Brightness & Contrast,
/// Tint, Fill...). None of them change what `lottie` renders, so removing
/// them is lossless for it.
///
/// Blur and Drop Shadow entries are kept. A layer left with an empty `ef`
/// list has the key removed entirely, since the empty list alone still
/// triggers the warning. Runs after expression baking, so any expression
/// reading an effect's value has already been baked (or reported as
/// unsupported) by the time its effect goes.
library;

/// `lottie`-supported layer effect types: Drop Shadow and Gaussian Blur.
const Set<int> _supportedEffectTypes = {25, 29};

/// Result of one [stripUnsupportedEffects] call.
class EffectStripResult {
  const EffectStripResult({
    required this.effectsRemoved,
    required this.layersCleared,
    required this.effectNames,
  });

  /// Top-level `ef` entries removed, across the root and every precomp.
  final int effectsRemoved;

  /// Layers whose `ef` key was removed entirely — every entry in it was
  /// unsupported, or it was already empty (or not a list) on input.
  final int layersCleared;

  /// The `nm` of every removed entry (with repeats), for reporting.
  final List<String> effectNames;

  bool get changed => effectsRemoved > 0 || layersCleared > 0;
}

/// Removes every layer effect `lottie` ignores from [doc] in place, across
/// the root layers and every precomp asset's layers.
EffectStripResult stripUnsupportedEffects(Map<String, dynamic> doc) {
  var removed = 0;
  var cleared = 0;
  final names = <String>[];

  void strip(List<dynamic> layers) {
    for (final l in layers) {
      if (l is! Map || !l.containsKey('ef')) continue;
      final ef = l['ef'];
      if (ef is List) {
        ef.removeWhere((e) {
          if (e is Map && _supportedEffectTypes.contains(e['ty'])) {
            return false;
          }
          removed++;
          names.add(e is Map ? '${e['nm']}' : '$e');
          return true;
        });
        if (ef.isNotEmpty) continue;
      }
      l.remove('ef');
      cleared++;
    }
  }

  strip((doc['layers'] as List?) ?? const []);
  for (final asset in (doc['assets'] as List? ?? const [])) {
    if (asset is Map && asset['layers'] is List) {
      strip(asset['layers'] as List);
    }
  }

  return EffectStripResult(
    effectsRemoved: removed,
    layersCleared: cleared,
    effectNames: names,
  );
}
