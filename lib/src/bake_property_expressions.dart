/// Bakes the expressions `bakeLoopExpressions` doesn't handle — anything
/// other than a `loopOut`/`loopIn`/`loopOutDuration`/`loopInDuration` call —
/// by evaluating them at every frame in `[doc.ip, doc.op]` and writing the
/// result as real keyframes: continuous `time`-based motion (e.g.
/// `time * 180`), cross-layer links
/// (`thisComp.layer('Name').transform.position[.valueAtTime(t)]`), the
/// `Math.*` namespace, `linear()`/`ease()`/`easeIn()`/`easeOut()`/`clamp()`,
/// `add()`/`sub()`/`mul()`/`div()`, `if`/`else`, and the `random()`/
/// `wiggle()` builtins.
///
/// This runs on both never-keyframed properties (`"a": 0`, value stored
/// directly in `k`) and already-keyframed ones (`"a": 1`): for the latter,
/// the property's own original keyframe curve — sampled with linear
/// interpolation, not the authored bezier easing — becomes the per-frame
/// `value`/`wiggle()` base, matching how After Effects itself evaluates an
/// expression layered on top of real keyframes (the expression's result is
/// authoritative; the original keyframes are only "raw material" available
/// through `value`/`valueAtTime()`, not blended with the expression's
/// output).
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
/// (`thisComp.layer('Name').transform.<prop>`, nothing else, on a
/// never-keyframed target) is copied exactly — the referenced property's own
/// keyframes and easing, verbatim — since nothing needs sampling for that
/// case. Combined into a larger expression (e.g. added to a constant), it's
/// instead sampled like any other expression, using linear (not bezier)
/// interpolation of the referenced curve.
///
/// A `wiggle()`-only expression on a shape path's `ks` (a `{i,o,v,c}` map,
/// not a plain number/vector) gets its own dedicated bake: each vertex is
/// wiggled independently (its own seed, its own knots), leaving the `i`/`o`
/// tangent handles untouched since Lottie stores them as offsets relative to
/// `v`, not absolute points. General arithmetic on a path value isn't
/// supported — After Effects doesn't support it either.
///
/// Not supported (left untouched, reported via
/// [PropertyBakeResult.skippedExpressions]): references into a nested comp
/// or to `effect(...)`, any expression using syntax this evaluator doesn't
/// understand, and any non-`wiggle()` expression on a shape path.
///
/// Baking `random()`/`wiggle()`, an expression on an already-keyframed
/// property, `wiggle()` on a shape path, and `ease()`/`easeIn()`/
/// `easeOut()` are each individually approximations or judgment calls
/// rather than an exact match to After Effects — pass a [BakeOptions] to opt
/// out of any of them; see its doc comments for what each one changes.
library;

import 'bake_options.dart';
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

  /// Expressions found that were left untouched: unresolvable references, or
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

/// Walks [doc] and bakes every supported non-loop expression found, mutating
/// [doc] in place. Meant to run after `bakeLoopExpressions` in the same
/// document, so loop expressions it already handled are gone by the time
/// this pass sees the tree.
PropertyBakeResult bakePropertyExpressions(
  Map<String, dynamic> doc, {
  BakeOptions options = const BakeOptions(),
}) {
  final fr = (doc['fr'] as num?) ?? 30;
  final start = (doc['ip'] as num?) ?? 0;
  final end = doc['op'] as num? ?? start;
  var baked = 0;
  final skipped = <String>[];

  void walkLayers(List<dynamic> rawLayers) {
    final layers = rawLayers.whereType<Map<String, dynamic>>().toList();
    for (final layer in layers) {
      _walkNode(layer, layer, layers, fr, start, end, options, (didBake) {
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
  BakeOptions options,
  void Function(bool baked) report,
  List<String> skipped,
) {
  if (node is Map<String, dynamic>) {
    final expr = node['x'];
    if (expr is String) {
      final ok = _tryBake(node, expr, layer, layers, fr, start, end, options);
      report(ok);
      if (!ok) skipped.add(expr);
    }
    for (final value in node.values.toList()) {
      _walkNode(value, layer, layers, fr, start, end, options, report, skipped);
    }
  } else if (node is List) {
    for (final value in node) {
      _walkNode(value, layer, layers, fr, start, end, options, report, skipped);
    }
  }
}

/// Whether `k` is a never-keyframed raw value (a plain number, or a plain
/// list of numbers).
bool _isRawValue(dynamic k) {
  if (k is num) return true;
  if (k is List) return k.every((v) => v is num);
  return false;
}

/// Whether `k` is an already-keyframed numeric property (a list of keyframe
/// objects whose `s` is a plain numeric list) — position/scale/rotation/
/// opacity/anchorPoint, not a shape path.
bool _isNumericKeyframeList(dynamic k) {
  if (k is! List || k.isEmpty) return false;
  for (final kf in k) {
    if (kf is! Map || kf['s'] is! List) return false;
    if ((kf['s'] as List).any((v) => v is! num)) return false;
  }
  return true;
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
  BakeOptions options,
) {
  final k = node['k'];
  if (k is Map<String, dynamic> && k['v'] is List) {
    if (!options.bakeShapePathWiggle || !options.bakeRandomAndWiggle) {
      return false;
    }
    return _tryBakeShapePath(node, k, expr, layer, fr, start, end);
  }
  return _tryBakeNumeric(node, k, expr, layer, layers, fr, start, end, options);
}

bool _tryBakeNumeric(
  Map<String, dynamic> node,
  dynamic k,
  String expr,
  Map<String, dynamic> layer,
  List<Map<String, dynamic>> layers,
  num fr,
  num start,
  num end,
  BakeOptions options,
) {
  final isRaw = _isRawValue(k);
  final isKeyframed = !isRaw && _isNumericKeyframeList(k);
  if (!isRaw && !isKeyframed) return false; // e.g. a shape path handled above
  if (isKeyframed && !options.bakeOnKeyframedProperties) return false;

  final List<StmtNode> program;
  try {
    program = parseProgram(expr);
  } on ExpressionEvalError {
    return false;
  }

  if (!options.bakeRandomAndWiggle &&
      (_programCallsFunction(program, 'random') ||
          _programCallsFunction(program, 'wiggle'))) {
    return false;
  }
  if (!options.bakeApproximateEasing &&
      (_programCallsFunction(program, 'ease') ||
          _programCallsFunction(program, 'easeIn') ||
          _programCallsFunction(program, 'easeOut'))) {
    return false;
  }

  if (isRaw) {
    final bareRef = _extractBareRefFromProgram(program);
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
  }

  final int targetDims;
  final List<num> initialBaseValue;
  final Map<String, dynamic>? originalKeyframedProp;
  if (isRaw) {
    targetDims = k is List ? k.length : 1;
    initialBaseValue = k is List ? k.cast<num>() : [k as num];
    originalKeyframedProp = null;
  } else {
    final keyframes = (k as List).cast<Map<String, dynamic>>();
    targetDims = (keyframes.first['s'] as List).length;
    originalKeyframedProp = {'a': 1, 'k': _deepClone(keyframes)};
    initialBaseValue = sampleRawProperty(
      originalKeyframedProp,
      keyframes.first['t'] as num,
    );
  }

  final seedKey =
      '${layer['nm'] ?? layer['ind'] ?? layers.indexOf(layer)}::$expr';
  final ctx = EvalContext(
    layers: layers,
    fr: fr,
    targetDims: targetDims,
    baseValue: initialBaseValue,
    seed: _stableSeed(seedKey),
  );
  final isHold = _programCallsFunction(program, 'random');

  final keyframes = <Map<String, dynamic>>[];
  try {
    for (var f = start.ceil(); f <= end.floor(); f++) {
      ctx.timeFrame = f;
      if (originalKeyframedProp != null) {
        ctx.baseValue = sampleRawProperty(originalKeyframedProp, f);
      }
      final value = runProgram(program, ctx);
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

/// Bakes a `wiggle(freq, amp)`-only expression on a shape path (`k` shaped
/// `{i, o, v, c}`): wiggles each vertex independently (its own seed derived
/// from the vertex index, so points don't all jitter in lockstep), leaving
/// the `i`/`o` tangent handles as-is since Lottie stores them as offsets
/// relative to `v`. Any other expression on a path is left unsupported —
/// arithmetic directly on a path value isn't something After Effects
/// supports either.
bool _tryBakeShapePath(
  Map<String, dynamic> node,
  Map<String, dynamic> k,
  String expr,
  Map<String, dynamic> layer,
  num fr,
  num start,
  num end,
) {
  final vRaw = k['v'];
  final iRaw = k['i'];
  final oRaw = k['o'];
  if (vRaw is! List || iRaw is! List || oRaw is! List) return false;
  if (vRaw.any((p) => p is! List || p.length != 2)) return false;

  final List<StmtNode> program;
  try {
    program = parseProgram(expr);
  } on ExpressionEvalError {
    return false;
  }
  final valueExpr = _finalValueExpr(program);
  if (valueExpr is! CallNode ||
      valueExpr.callee is! IdentNode ||
      (valueExpr.callee as IdentNode).name != 'wiggle') {
    return false;
  }

  final vertices = vRaw.map((p) => (p as List).cast<num>()).toList();
  final layers = [layer];
  final seedKey = '${layer['nm'] ?? layer['ind']}::$expr';
  final contexts = [
    for (var i = 0; i < vertices.length; i++)
      EvalContext(
        layers: layers,
        fr: fr,
        targetDims: 2,
        baseValue: vertices[i],
        seed: _stableSeed('$seedKey::v$i'),
      ),
  ];

  final keyframes = <Map<String, dynamic>>[];
  try {
    for (var f = start.ceil(); f <= end.floor(); f++) {
      final newVerts = <List<num>>[];
      for (final vertexCtx in contexts) {
        vertexCtx.timeFrame = f;
        newVerts.add(_toVector(runProgram(program, vertexCtx), 2));
      }
      keyframes.add({
        't': f,
        's': [
          {'i': iRaw, 'o': oRaw, 'v': newVerts, 'c': k['c']},
        ],
      });
    }
  } on ExpressionEvalError {
    return false;
  }
  if (keyframes.isEmpty) return false;

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

/// If [program] is (ignoring `var $bm_rt;`) a single statement assigning or
/// evaluating exactly `thisComp.layer(<selector>).transform.<prop>` with
/// nothing else combined in, returns the literal selector and the matching
/// `ks` key (`p`/`r`/`s`/`o`/`a`) so the caller can copy that property
/// verbatim instead of sampling it.
(dynamic, String)? _extractBareRefFromProgram(List<StmtNode> program) {
  final expr = _finalValueExpr(program);
  return expr == null ? null : _matchBareLayerRef(expr);
}

/// The value-producing expression of [program]'s last assignment/bare
/// statement — mirroring how a simplified AE expression's "returned" value
/// works — or null if [program] uses any control flow (`if`/a standalone
/// block), which the fast-path checks that consume this can't safely
/// pattern-match through. `var` declarations (with or without an
/// initializer) never change the candidate, matching how they're
/// side-effect-only for this purpose.
ExprNode? _finalValueExpr(List<StmtNode> program) {
  ExprNode? candidate;
  for (final stmt in program) {
    switch (stmt) {
      case VarDeclStmt _:
        continue;
      case AssignStmt a:
        candidate = a.value;
      case ExprStmt e:
        candidate = e.expr;
      default:
        return null;
    }
  }
  return candidate;
}

bool _programCallsFunction(List<StmtNode> program, String name) {
  var found = false;
  void visitExpr(ExprNode node) {
    if (found) return;
    switch (node) {
      case CallNode c:
        if (c.callee is IdentNode && (c.callee as IdentNode).name == name) {
          found = true;
          return;
        }
        visitExpr(c.callee);
        for (final a in c.args) {
          visitExpr(a);
        }
      case BinaryNode b:
        visitExpr(b.left);
        visitExpr(b.right);
      case CompareNode c:
        visitExpr(c.left);
        visitExpr(c.right);
      case LogicalNode l:
        visitExpr(l.left);
        visitExpr(l.right);
      case TernaryNode t:
        visitExpr(t.cond);
        visitExpr(t.thenExpr);
        visitExpr(t.elseExpr);
      case UnaryNode u:
        visitExpr(u.operand);
      case MemberNode m:
        visitExpr(m.target);
      case IndexNode ix:
        visitExpr(ix.target);
        visitExpr(ix.index);
      case ArrayNode arr:
        for (final e in arr.elements) {
          visitExpr(e);
        }
      case NumNode _:
      case StrNode _:
      case IdentNode _:
        break;
    }
  }

  void visitStmt(StmtNode stmt) {
    if (found) return;
    switch (stmt) {
      case VarDeclStmt v:
        if (v.init != null) visitExpr(v.init!);
      case AssignStmt a:
        visitExpr(a.value);
      case ExprStmt e:
        visitExpr(e.expr);
      case IfStmt f:
        visitExpr(f.cond);
        for (final s in f.thenBranch) {
          visitStmt(s);
        }
        for (final s in f.elseBranch ?? const []) {
          visitStmt(s);
        }
      case GroupStmt g:
        for (final s in g.body) {
          visitStmt(s);
        }
    }
  }

  for (final stmt in program) {
    visitStmt(stmt);
    if (found) break;
  }
  return found;
}

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
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key as String: _deepClone(entry.value),
    };
  }
  if (value is List) {
    return [for (final v in value) _deepClone(v)];
  }
  return value;
}
