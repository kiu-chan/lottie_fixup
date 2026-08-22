/// Bakes the expressions `bakeLoopExpressions` doesn't handle — anything
/// other than a `loopOut`/`loopIn`/`loopOutDuration`/`loopInDuration` call —
/// on a property that was never manually keyframed (`"a": 0`): continuous
/// `time`-based motion (e.g. `time * 180`), cross-layer links
/// (`thisComp.layer('Name').transform.position`), and the `random()`/
/// `wiggle()` builtins.
///
/// A never-keyframed property stores its value directly in `k` (a plain
/// number or a plain numeric list), so unlike loop expressions there's no
/// existing segment to repeat — baking means evaluating the expression at
/// every frame in `[doc.ip, doc.op]` and writing the result as a real
/// keyframe.
///
/// `random()`/`wiggle()` can't be reproduced bit-for-bit — After Effects'
/// noise/PRNG is proprietary — so this bakes a plausible approximation
/// instead: `random(min, max)` draws a fresh uniform value every frame
/// (held, not interpolated, matching AE's per-frame flicker), and
/// `wiggle(freq, amp)` linearly interpolates between random knots placed
/// `1/freq` seconds apart. Both use a seed derived from the layer and
/// expression text, so baking the same file twice produces the same result.
///
/// A cross-layer reference that is the *entire* expression
/// (`thisComp.layer('Name').transform.<prop>`, nothing else) is copied
/// exactly — the referenced property's own keyframes and easing, verbatim —
/// since nothing needs sampling for that case. Combined into a larger
/// expression (e.g. added to a constant), it's instead sampled like any
/// other expression, using linear (not bezier) interpolation of the
/// referenced curve.
///
/// Not supported (left untouched, reported via
/// [PropertyBakeResult.skippedExpressions]): anything on a property that
/// *is* already keyframed (that shape belongs to `bakeLoopExpressions`,
/// which reports it if unsupported), references into a nested comp or to
/// `effect(...)`, and any expression using syntax this evaluator doesn't
/// understand.
library;

import 'expression_evaluator.dart';

/// Result of baking property expressions in one document.
class PropertyBakeResult {
  const PropertyBakeResult({
    required this.propertiesBaked,
    required this.skippedExpressions,
  });

  /// How many properties had an expression baked into real keyframes or
  /// (for a bare cross-layer reference) an exact keyframe copy.
  final int propertiesBaked;

  /// Expressions found that were left untouched: already-keyframed
  /// properties (not this pass's concern), unresolvable references, or
  /// syntax this evaluator doesn't understand.
  final List<String> skippedExpressions;

  bool get changed => propertiesBaked > 0;
}

const _aliasToKey = {
  'position': 'p',
  'rotation': 'r',
  'scale': 's',
  'opacity': 'o',
  'anchorPoint': 'a',
};

/// Walks [doc] and bakes every supported non-loop expression found on a
/// never-keyframed property, mutating [doc] in place. Meant to run after
/// `bakeLoopExpressions` in the same document, so loop expressions it
/// already handled are gone by the time this pass sees the tree.
PropertyBakeResult bakePropertyExpressions(Map<String, dynamic> doc) {
  final fr = (doc['fr'] as num?) ?? 30;
  final start = (doc['ip'] as num?) ?? 0;
  final end = doc['op'] as num? ?? start;
  var baked = 0;
  final skipped = <String>[];

  void walkLayers(List<dynamic> rawLayers) {
    final layers = rawLayers.whereType<Map<String, dynamic>>().toList();
    for (final layer in layers) {
      _walkNode(layer, layer, layers, fr, start, end, (didBake) {
        if (didBake) {
          baked++;
        }
      }, skipped);
    }
  }

  walkLayers((doc['layers'] as List?) ?? const []);
  for (final asset in (doc['assets'] as List? ?? const [])) {
    if (asset is Map && asset['layers'] is List) {
      walkLayers(asset['layers'] as List);
    }
  }

  return PropertyBakeResult(
    propertiesBaked: baked,
    skippedExpressions: skipped,
  );
}

void _walkNode(
  dynamic node,
  Map<String, dynamic> layer,
  List<Map<String, dynamic>> layers,
  num fr,
  num start,
  num end,
  void Function(bool baked) report,
  List<String> skipped,
) {
  if (node is Map<String, dynamic>) {
    final expr = node['x'];
    if (expr is String) {
      final ok = _tryBake(node, expr, layer, layers, fr, start, end);
      report(ok);
      if (!ok) skipped.add(expr);
    }
    for (final value in node.values.toList()) {
      _walkNode(value, layer, layers, fr, start, end, report, skipped);
    }
  } else if (node is List) {
    for (final value in node) {
      _walkNode(value, layer, layers, fr, start, end, report, skipped);
    }
  }
}

/// Whether `k` is a never-keyframed raw value (a plain number, or a plain
/// list of numbers) — the shape this pass targets. A keyframed `"a": 1`
/// property (`k` a list of keyframe objects) is `bakeLoopExpressions`'
/// concern, not this one.
bool _isRawValue(dynamic k) {
  if (k is num) return true;
  if (k is List) return k.every((v) => v is num);
  return false;
}

int _stableSeed(String key) {
  var h = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    h ^= unit;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

bool _tryBake(
  Map<String, dynamic> node,
  String expr,
  Map<String, dynamic> layer,
  List<Map<String, dynamic>> layers,
  num fr,
  num start,
  num end,
) {
  final k = node['k'];
  if (!_isRawValue(k)) return false; // already keyframed; not our concern

  final text = extractValueExpression(expr);
  if (text == null || text.isEmpty) return false;

  final ExprNode ast;
  try {
    ast = parseExpression(text);
  } on ExpressionEvalError {
    return false;
  }

  final bareRef = _matchBareLayerRef(ast);
  if (bareRef != null) {
    final selector = bareRef.$1;
    final key = bareRef.$2;
    final source = findLayer(layers, selector);
    final sourceProp = source == null ? null : (source['ks'] as Map?)?[key];
    if (sourceProp is Map<String, dynamic>) {
      node['a'] = sourceProp['a'];
      node['k'] = _deepClone(sourceProp['k']);
      node.remove('x');
      return true;
    }
    return false;
  }

  final targetDims = k is List ? k.length : 1;
  final baseValue = k is List ? k.cast<num>() : [k as num];
  final seedKey =
      '${layer['nm'] ?? layer['ind'] ?? layers.indexOf(layer)}::$expr';
  final ctx = EvalContext(
    layers: layers,
    fr: fr,
    targetDims: targetDims,
    baseValue: baseValue,
    seed: _stableSeed(seedKey),
  );
  final isHold = text.contains('random(');

  final keyframes = <Map<String, dynamic>>[];
  try {
    for (var f = start.ceil(); f <= end.floor(); f++) {
      ctx.timeFrame = f;
      final value = evaluate(ast, ctx);
      final sVal = targetDims == 1
          ? [_toNum(value)]
          : _toVector(value, targetDims);
      keyframes.add({'t': f, 's': sVal, if (isHold) 'h': 1});
    }
  } on ExpressionEvalError {
    return false;
  }
  if (keyframes.isEmpty) return false;
  if (isHold) keyframes.last.remove('h');

  node['a'] = 1;
  node['k'] = keyframes;
  node.remove('x');
  return true;
}

num _toNum(dynamic v) {
  if (v is num) return v;
  if (v is List && v.length == 1 && v.first is num) return v.first as num;
  throw ExpressionEvalError('expected a scalar result');
}

List<num> _toVector(dynamic v, int dims) {
  if (v is num) return [for (var i = 0; i < dims; i++) v];
  if (v is List) {
    final nums = v.cast<num>();
    if (nums.length == dims) return nums;
  }
  throw ExpressionEvalError('expected a $dims-component result');
}

/// If [ast] is exactly `thisComp.layer(<selector>).transform.<prop>` with
/// nothing else combined in, returns the literal selector and the matching
/// `ks` key (`p`/`r`/`s`/`o`/`a`) so the caller can copy that property
/// verbatim instead of sampling it.
(dynamic, String)? _matchBareLayerRef(ExprNode ast) {
  if (ast is! MemberNode) return null;
  final key = _aliasToKey[ast.name];
  if (key == null) return null;
  final transformCall = ast.target;
  if (transformCall is! MemberNode || transformCall.name != 'transform') {
    return null;
  }
  final layerCall = transformCall.target;
  if (layerCall is! CallNode || layerCall.args.length != 1) return null;
  final callee = layerCall.callee;
  if (callee is! MemberNode || callee.name != 'layer') return null;
  if (callee.target is! IdentNode ||
      (callee.target as IdentNode).name != 'thisComp') {
    return null;
  }
  final selectorNode = layerCall.args.single;
  final dynamic selector = switch (selectorNode) {
    StrNode s => s.value,
    NumNode n => n.value,
    _ => null,
  };
  if (selector == null) return null;
  return (selector, key);
}

dynamic _deepClone(dynamic value) {
  if (value is Map) {
    return {
      for (final entry in value.entries) entry.key: _deepClone(entry.value),
    };
  }
  if (value is List) {
    return [for (final v in value) _deepClone(v)];
  }
  return value;
}
