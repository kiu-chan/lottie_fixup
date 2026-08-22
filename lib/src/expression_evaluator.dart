/// A small evaluator for the tiny subset of After Effects/Bodymovin
/// expression syntax that [bakePropertyExpressions] needs to sample:
/// numeric arithmetic, `time`, `thisComp.layer('Name').transform.<prop>`
/// cross-layer references, and the `random`/`wiggle` builtins.
///
/// This is deliberately not a general JavaScript interpreter — no `if`,
/// loops, or user-defined functions — just enough grammar to cover the
/// value-producing expression Bodymovin emits after its own
/// `var $bm_rt; $bm_rt = <expr>;` boilerplate.
library;

import 'dart:math';

/// Thrown for anything this evaluator doesn't understand: an unknown
/// identifier/function, a malformed reference, or a syntax error. Callers
/// catch this and report the original expression as unsupported instead of
/// guessing.
class ExpressionEvalError implements Exception {
  ExpressionEvalError(this.message);
  final String message;
  @override
  String toString() => 'ExpressionEvalError: $message';
}

/// Extracts the value-producing expression from a raw `x` string, stripping
/// Bodymovin's `var $bm_rt;` boilerplate and taking the right-hand side of
/// the last assignment to `$bm_rt` (or, if there is none, the last bare
/// expression statement — matching how AE/Bodymovin's implicit "last value
/// wins" evaluation works). Returns null if nothing usable is found.
String? extractValueExpression(String raw) {
  final statements = raw
      .split(';')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final assignment = RegExp(r'^([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(.+)$');

  String? lastValue;
  String? bmRtValue;
  for (final statement in statements) {
    if (statement.startsWith('var ')) continue;
    final match = assignment.firstMatch(statement);
    if (match != null) {
      lastValue = match.group(2);
      if (match.group(1) == r'$bm_rt') bmRtValue = lastValue;
    } else {
      lastValue = statement;
    }
  }
  return bmRtValue ?? lastValue;
}

// --- AST -------------------------------------------------------------------

sealed class ExprNode {}

class NumNode extends ExprNode {
  NumNode(this.value);
  final num value;
}

class StrNode extends ExprNode {
  StrNode(this.value);
  final String value;
}

class IdentNode extends ExprNode {
  IdentNode(this.name);
  final String name;
}

class UnaryNode extends ExprNode {
  UnaryNode(this.operand);
  final ExprNode operand;
}

class BinaryNode extends ExprNode {
  BinaryNode(this.op, this.left, this.right);
  final String op;
  final ExprNode left;
  final ExprNode right;
}

class MemberNode extends ExprNode {
  MemberNode(this.target, this.name);
  final ExprNode target;
  final String name;
}

class CallNode extends ExprNode {
  CallNode(this.callee, this.args);
  final ExprNode callee;
  final List<ExprNode> args;
}

class IndexNode extends ExprNode {
  IndexNode(this.target, this.index);
  final ExprNode target;
  final ExprNode index;
}

// --- Tokenizer ---------------------------------------------------------

class _Token {
  _Token(this.type, this.text);
  final String type; // num, str, ident, punct, end
  final String text;
}

List<_Token> _tokenize(String src) {
  final tokens = <_Token>[];
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      i++;
    } else if (RegExp(r'[0-9]').hasMatch(c) ||
        (c == '.' &&
            i + 1 < src.length &&
            RegExp(r'[0-9]').hasMatch(src[i + 1]))) {
      final start = i;
      while (i < src.length && RegExp(r'[0-9.]').hasMatch(src[i])) {
        i++;
      }
      tokens.add(_Token('num', src.substring(start, i)));
    } else if (RegExp(r'[A-Za-z_$]').hasMatch(c)) {
      final start = i;
      while (i < src.length && RegExp(r'[A-Za-z0-9_$]').hasMatch(src[i])) {
        i++;
      }
      tokens.add(_Token('ident', src.substring(start, i)));
    } else if (c == "'" || c == '"') {
      final quote = c;
      final start = ++i;
      while (i < src.length && src[i] != quote) {
        i++;
      }
      tokens.add(_Token('str', src.substring(start, i)));
      i++; // closing quote
    } else if ('+-*/().,[]'.contains(c)) {
      tokens.add(_Token('punct', c));
      i++;
    } else {
      throw ExpressionEvalError('unexpected character "$c"');
    }
  }
  tokens.add(_Token('end', ''));
  return tokens;
}

// --- Parser --------------------------------------------------------------
//
// expr    := term (('+'|'-') term)*
// term    := unary (('*'|'/') unary)*
// unary   := '-' unary | postfix
// postfix := primary ( '.' ident | '(' args ')' | '[' expr ']' )*
// primary := num | str | ident | '(' expr ')'

class _Parser {
  _Parser(this._tokens);
  final List<_Token> _tokens;
  var _pos = 0;

  _Token get _current => _tokens[_pos];

  ExprNode parse() {
    final node = _expr();
    if (_current.type != 'end') {
      throw ExpressionEvalError(
        'unexpected trailing input near "${_current.text}"',
      );
    }
    return node;
  }

  _Token _expect(String type, [String? text]) {
    if (_current.type != type || (text != null && _current.text != text)) {
      throw ExpressionEvalError(
        'expected $type "${text ?? ''}", got "${_current.text}"',
      );
    }
    final t = _current;
    _pos++;
    return t;
  }

  bool _isPunct(String text) =>
      _current.type == 'punct' && _current.text == text;

  ExprNode _expr() {
    var node = _term();
    while (_isPunct('+') || _isPunct('-')) {
      final op = _current.text;
      _pos++;
      node = BinaryNode(op, node, _term());
    }
    return node;
  }

  ExprNode _term() {
    var node = _unary();
    while (_isPunct('*') || _isPunct('/')) {
      final op = _current.text;
      _pos++;
      node = BinaryNode(op, node, _unary());
    }
    return node;
  }

  ExprNode _unary() {
    if (_isPunct('-')) {
      _pos++;
      return UnaryNode(_unary());
    }
    return _postfix();
  }

  ExprNode _postfix() {
    var node = _primary();
    while (true) {
      if (_isPunct('.')) {
        _pos++;
        final name = _expect('ident').text;
        node = MemberNode(node, name);
      } else if (_isPunct('(')) {
        _pos++;
        final args = <ExprNode>[];
        if (!_isPunct(')')) {
          args.add(_expr());
          while (_isPunct(',')) {
            _pos++;
            args.add(_expr());
          }
        }
        _expect('punct', ')');
        node = CallNode(node, args);
      } else if (_isPunct('[')) {
        _pos++;
        final index = _expr();
        _expect('punct', ']');
        node = IndexNode(node, index);
      } else {
        break;
      }
    }
    return node;
  }

  ExprNode _primary() {
    if (_current.type == 'num') {
      final value = num.parse(_current.text);
      _pos++;
      return NumNode(value);
    }
    if (_current.type == 'str') {
      final value = _current.text;
      _pos++;
      return StrNode(value);
    }
    if (_current.type == 'ident') {
      final name = _current.text;
      _pos++;
      return IdentNode(name);
    }
    if (_isPunct('(')) {
      _pos++;
      final node = _expr();
      _expect('punct', ')');
      return node;
    }
    throw ExpressionEvalError('unexpected token "${_current.text}"');
  }
}

/// Parses [source] (already stripped of the `var $bm_rt;` wrapper via
/// [extractValueExpression]) into an [ExprNode] tree.
ExprNode parseExpression(String source) => _Parser(_tokenize(source)).parse();

// --- Evaluation context ---------------------------------------------------

/// Marks a resolved `thisComp` reference during evaluation. Only valid as
/// the target of a `.layer(...)` call.
class ThisCompRef {
  const ThisCompRef();
}

/// A layer resolved via `thisComp.layer(...)`, scoped to the same `layers`
/// array the referencing layer itself belongs to (root composition or the
/// same precomp asset — not a nested comp one level further down).
class LayerRef {
  LayerRef(this.layer);
  final Map<String, dynamic> layer;
}

/// `<layerRef>.transform`, holding the layer's `ks` transform map so a
/// following `.position`/`.rotation`/etc. can look up the right sub-property.
class TransformRef {
  TransformRef(this.ks);
  final Map<String, dynamic> ks;
}

const _transformAliasToKey = {
  'position': 'p',
  'rotation': 'r',
  'scale': 's',
  'opacity': 'o',
  'anchorPoint': 'a',
};

/// Per-property evaluation state: everything [evaluate] needs to resolve
/// `time`, cross-layer references, and the `random`/`wiggle` builtins for
/// one sampling pass. Reused across every frame sampled for the same
/// property so `random`/`wiggle` advance deterministically frame-by-frame.
class EvalContext {
  EvalContext({
    required this.layers,
    required this.fr,
    required this.targetDims,
    required this.baseValue,
    required int seed,
  }) : _rng = Random(seed);

  /// The layers array containing the layer this expression lives on —
  /// the scope `thisComp.layer(name)` searches.
  final List<Map<String, dynamic>> layers;

  /// Composition frame rate, for converting `time` (seconds) to the frame
  /// numbers keyframes are stored in.
  final num fr;

  /// Number of components the baked property's value needs (1 for a scalar
  /// like rotation/opacity, otherwise the length of its vector).
  final int targetDims;

  /// The property's original (pre-bake) static value, broadcast to
  /// [targetDims] components — the center that `wiggle()` jitters around.
  final List<num> baseValue;

  final Random _rng;
  final Map<int, List<num>> _wiggleKnots = {};

  /// Current sample time in frames; set by the caller before each
  /// [evaluate] call.
  num timeFrame = 0;

  num get timeSeconds => timeFrame / fr;
}

/// Finds a layer in [layers] by name (`nm`) or 1-based index (`ind`, AE's
/// `layer(index)` form), as referenced by `thisComp.layer(selector)`.
Map<String, dynamic>? findLayer(
  List<Map<String, dynamic>> layers,
  dynamic selector,
) {
  if (selector is String) {
    for (final layer in layers) {
      if (layer['nm'] == selector) return layer;
    }
    return null;
  }
  if (selector is num) {
    final index = selector.toInt();
    for (final layer in layers) {
      if (layer['ind'] == index) return layer;
    }
    if (index >= 1 && index <= layers.length) return layers[index - 1];
  }
  return null;
}

/// Samples a raw Lottie property map (`{"a":0,"k":...}` or `{"a":1,"k":[
/// keyframes]}`) at time [t] (in frames). Uses linear interpolation between
/// keyframes — not the original bezier easing — since this is only used to
/// resolve a cross-layer reference combined with other arithmetic; a bare
/// reference is copied exactly by [bakePropertyExpressions] instead of going
/// through this sampler.
List<num> sampleRawProperty(Map<String, dynamic> prop, num t) {
  final k = prop['k'];
  if (prop['a'] != 1 || k is! List || k.isEmpty || k.first is! Map) {
    return k is List ? k.cast<num>() : [k as num];
  }
  final keyframes = k.cast<Map<String, dynamic>>();
  List<num> valueOf(Map<String, dynamic> kf) =>
      kf['s'] is List ? (kf['s'] as List).cast<num>() : [kf['s'] as num];

  if (t <= (keyframes.first['t'] as num)) return valueOf(keyframes.first);
  if (t >= (keyframes.last['t'] as num)) return valueOf(keyframes.last);
  for (var i = 0; i < keyframes.length - 1; i++) {
    final a = keyframes[i];
    final b = keyframes[i + 1];
    final ta = a['t'] as num;
    final tb = b['t'] as num;
    if (t >= ta && t <= tb) {
      final f = tb == ta ? 0 : (t - ta) / (tb - ta);
      final sa = valueOf(a);
      final sb = valueOf(b);
      return [for (var d = 0; d < sa.length; d++) sa[d] + (sb[d] - sa[d]) * f];
    }
  }
  return valueOf(keyframes.last);
}

num _asNum(dynamic v) {
  if (v is num) return v;
  throw ExpressionEvalError('expected a number, got $v');
}

dynamic _applyBinary(String op, dynamic l, dynamic r) {
  if (l is num && r is num) {
    return switch (op) {
      '+' => l + r,
      '-' => l - r,
      '*' => l * r,
      '/' => l / r,
      _ => throw ExpressionEvalError('unknown operator $op'),
    };
  }
  if (l is List<num> && r is List<num>) {
    if (l.length != r.length) {
      throw ExpressionEvalError('vector length mismatch');
    }
    return [
      for (var i = 0; i < l.length; i++) _applyBinary(op, l[i], r[i]) as num,
    ];
  }
  if (l is List<num> && r is num) {
    return [for (final v in l) _applyBinary(op, v, r) as num];
  }
  if (l is num && r is List<num>) {
    return [for (final v in r) _applyBinary(op, l, v) as num];
  }
  throw ExpressionEvalError('unsupported operand types for $op');
}

/// Evaluates [node] against [ctx]. Returns a `num`, `List<num>`, `String`,
/// or one of [ThisCompRef]/[LayerRef]/[TransformRef] (only valid as an
/// intermediate value in a member/call chain — reaching the top of
/// evaluation with one of those left over is an error).
dynamic evaluate(ExprNode node, EvalContext ctx) {
  switch (node) {
    case NumNode n:
      return n.value;
    case StrNode s:
      return s.value;
    case IdentNode id:
      if (id.name == 'time') return ctx.timeSeconds;
      if (id.name == 'thisComp') return const ThisCompRef();
      if (id.name == 'PI') return pi;
      throw ExpressionEvalError('unknown identifier "${id.name}"');
    case UnaryNode u:
      return -_asNum(evaluate(u.operand, ctx));
    case BinaryNode b:
      return _applyBinary(b.op, evaluate(b.left, ctx), evaluate(b.right, ctx));
    case IndexNode ix:
      final target = evaluate(ix.target, ctx);
      final index = _asNum(evaluate(ix.index, ctx)).toInt();
      if (target is List) return target[index];
      throw ExpressionEvalError('cannot index a non-list value');
    case MemberNode m:
      return _resolveMember(evaluate(m.target, ctx), m.name, ctx);
    case CallNode c:
      return _resolveCall(c, ctx);
  }
}

dynamic _resolveMember(dynamic target, String name, EvalContext ctx) {
  if (target is LayerRef && name == 'transform') {
    final ks = target.layer['ks'];
    if (ks is! Map<String, dynamic>) {
      throw ExpressionEvalError('layer has no transform');
    }
    return TransformRef(ks);
  }
  if (target is TransformRef) {
    final key = _transformAliasToKey[name];
    if (key == null) {
      throw ExpressionEvalError('unknown transform property "$name"');
    }
    final prop = target.ks[key];
    if (prop is! Map<String, dynamic>) {
      throw ExpressionEvalError('layer is missing transform.$name');
    }
    return sampleRawProperty(prop, ctx.timeFrame);
  }
  throw ExpressionEvalError('cannot access ".$name" on this value');
}

dynamic _resolveCall(CallNode call, EvalContext ctx) {
  final callee = call.callee;
  if (callee is MemberNode && callee.name == 'layer') {
    final target = evaluate(callee.target, ctx);
    if (target is! ThisCompRef) {
      throw ExpressionEvalError('"layer" is only supported on thisComp');
    }
    if (call.args.length != 1) {
      throw ExpressionEvalError('layer() expects exactly one argument');
    }
    final selector = evaluate(call.args.single, ctx);
    final layer = findLayer(ctx.layers, selector);
    if (layer == null) {
      throw ExpressionEvalError('layer "$selector" not found');
    }
    return LayerRef(layer);
  }
  if (callee is IdentNode && callee.name == 'random') {
    final args = call.args.map((a) => _asNum(evaluate(a, ctx))).toList();
    final num min, max;
    switch (args.length) {
      case 0:
        min = 0;
        max = 1;
      case 1:
        min = 0;
        max = args[0];
      default:
        min = args[0];
        max = args[1];
    }
    return min + ctx._rng.nextDouble() * (max - min);
  }
  if (callee is IdentNode && callee.name == 'wiggle') {
    if (call.args.length < 2) {
      throw ExpressionEvalError('wiggle() expects at least (freq, amp)');
    }
    final freq = _asNum(evaluate(call.args[0], ctx));
    final amp = _asNum(evaluate(call.args[1], ctx));
    if (freq <= 0) {
      throw ExpressionEvalError('wiggle() frequency must be positive');
    }
    final knotPos = ctx.timeSeconds * freq;
    final index = knotPos.floor();
    final frac = knotPos - index;
    List<num> knotAt(int i) => ctx._wiggleKnots.putIfAbsent(i, () {
      return [
        for (var d = 0; d < ctx.targetDims; d++)
          ctx.baseValue[d] + (ctx._rng.nextDouble() * 2 - 1) * amp,
      ];
    });
    final a = knotAt(index);
    final b = knotAt(index + 1);
    final result = [
      for (var d = 0; d < a.length; d++) a[d] + (b[d] - a[d]) * frac,
    ];
    return ctx.targetDims == 1 ? result[0] : result;
  }
  throw ExpressionEvalError('unsupported function call');
}
