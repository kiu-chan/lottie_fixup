/// A small interpreter for the subset of After Effects/Bodymovin expression
/// syntax that [bakePropertyExpressions] needs to sample: numeric arithmetic,
/// comparisons/booleans, `if`/`else`, local `var` bindings, `time`,
/// `thisComp.layer('Name').transform.<prop>` cross-layer references and
/// their same-layer equivalent (`thisLayer.transform.<prop>`, or bare
/// `transform.<prop>`) — both plus `.valueAtTime(t)` — the `Math.*`
/// namespace, `value` (the property's own pre-expression value), array
/// literals, and the `random`/`wiggle`/`linear`/`ease`/`easeIn`/`easeOut`/
/// `clamp`/`add`/`sub`/`mul`/`div`/`posterizeTime`/`seedRandom` builtins.
///
/// This is deliberately not a general JavaScript interpreter — no loops or
/// user-defined functions — just enough grammar to cover the statement
/// sequences Bodymovin emits after its own `var $bm_rt; ...; $bm_rt = <expr>;`
/// boilerplate, including any control-flow/helper statements that precede the
/// final assignment (e.g. `posterizeTime(6);`).
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

// --- Expression AST ---------------------------------------------------------

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

class ArrayNode extends ExprNode {
  ArrayNode(this.elements);
  final List<ExprNode> elements;
}

class UnaryNode extends ExprNode {
  UnaryNode(this.op, this.operand);
  final String op; // '-' or '!'
  final ExprNode operand;
}

class BinaryNode extends ExprNode {
  BinaryNode(this.op, this.left, this.right);
  final String op; // '+','-','*','/','%'
  final ExprNode left;
  final ExprNode right;
}

class CompareNode extends ExprNode {
  CompareNode(this.op, this.left, this.right);
  final String op; // '<','>','<=','>=','==','!='
  final ExprNode left;
  final ExprNode right;
}

class LogicalNode extends ExprNode {
  LogicalNode(this.op, this.left, this.right);
  final String op; // '&&' or '||'
  final ExprNode left;
  final ExprNode right;
}

class TernaryNode extends ExprNode {
  TernaryNode(this.cond, this.thenExpr, this.elseExpr);
  final ExprNode cond;
  final ExprNode thenExpr;
  final ExprNode elseExpr;
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

// --- Statement AST -----------------------------------------------------------

sealed class StmtNode {}

/// `var name;` or `var name = <init>;`.
class VarDeclStmt extends StmtNode {
  VarDeclStmt(this.name, this.init);
  final String name;
  final ExprNode? init;
}

/// `name = <value>;` — reassignment of a local variable or `$bm_rt`.
class AssignStmt extends StmtNode {
  AssignStmt(this.name, this.value);
  final String name;
  final ExprNode value;
}

/// A bare expression statement, e.g. `posterizeTime(6);` or (with no `$bm_rt`
/// wrapper at all) the entire body of a one-line expression like `time * 180`.
class ExprStmt extends StmtNode {
  ExprStmt(this.expr);
  final ExprNode expr;
}

class IfStmt extends StmtNode {
  IfStmt(this.cond, this.thenBranch, this.elseBranch);
  final ExprNode cond;
  final List<StmtNode> thenBranch;
  final List<StmtNode>? elseBranch;
}

/// A standalone `{ ... }` block (not attached to an `if`).
class GroupStmt extends StmtNode {
  GroupStmt(this.body);
  final List<StmtNode> body;
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
    } else if (c == '<' || c == '>' || c == '=' || c == '!') {
      final two = i + 1 < src.length ? src.substring(i, i + 2) : '';
      if (two == '<=' || two == '>=' || two == '==' || two == '!=') {
        tokens.add(_Token('punct', two));
        i += 2;
      } else {
        tokens.add(_Token('punct', c));
        i++;
      }
    } else if (c == '&' || c == '|') {
      final two = i + 1 < src.length ? src.substring(i, i + 2) : '';
      if (two == '&&' || two == '||') {
        tokens.add(_Token('punct', two));
        i += 2;
      } else {
        throw ExpressionEvalError('unexpected character "$c"');
      }
    } else if ('+-*/%().,[]{};?:'.contains(c)) {
      tokens.add(_Token('punct', c));
      i++;
    } else {
      throw ExpressionEvalError('unexpected character "$c"');
    }
  }
  tokens.add(_Token('end', ''));
  return tokens;
}

const _reservedWords = {'var', 'if', 'else'};

// --- Parser --------------------------------------------------------------
//
// program    := statement*
// statement  := varDecl | ifStmt | block | assign | exprStmt
// varDecl    := 'var' ident ('=' expr)? ';'?
// ifStmt     := 'if' '(' expr ')' (block | statement) ('else' (block | statement))?
// block      := '{' statement* '}'
// assign     := ident '=' expr ';'?
// exprStmt   := expr ';'?
//
// expr       := ternary
// ternary    := logicalOr ('?' expr ':' expr)?
// logicalOr  := logicalAnd ('||' logicalAnd)*
// logicalAnd := equality ('&&' equality)*
// equality   := relational (('=='|'!=') relational)*
// relational := additive (('<'|'>'|'<='|'>=') additive)*
// additive   := term (('+'|'-') term)*
// term       := unary (('*'|'/'|'%') unary)*
// unary      := ('-'|'!') unary | postfix
// postfix    := primary ( '.' ident | '(' args ')' | '[' expr ']' )*
// primary    := num | str | ident | '(' expr ')' | '[' (expr (',' expr)*)? ']'

class _Parser {
  _Parser(this._tokens);
  final List<_Token> _tokens;
  var _pos = 0;

  _Token get _current => _tokens[_pos];

  List<StmtNode> parseProgram() {
    final stmts = <StmtNode>[];
    while (_current.type != 'end') {
      stmts.add(_statement());
    }
    return stmts;
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

  bool _isKeyword(String text) =>
      _current.type == 'ident' && _current.text == text;

  void _consumeOptionalSemi() {
    if (_isPunct(';')) _pos++;
  }

  StmtNode _statement() {
    if (_isKeyword('var')) {
      _pos++;
      final name = _expect('ident').text;
      ExprNode? init;
      if (_isPunct('=')) {
        _pos++;
        init = _expr();
      }
      _consumeOptionalSemi();
      return VarDeclStmt(name, init);
    }
    if (_isKeyword('if')) {
      _pos++;
      _expect('punct', '(');
      final cond = _expr();
      _expect('punct', ')');
      final thenBranch = _blockOrSingle();
      List<StmtNode>? elseBranch;
      if (_isKeyword('else')) {
        _pos++;
        elseBranch = _blockOrSingle();
      }
      return IfStmt(cond, thenBranch, elseBranch);
    }
    if (_isPunct('{')) {
      return GroupStmt(_block());
    }
    if (_current.type == 'ident' && !_reservedWords.contains(_current.text)) {
      final savedPos = _pos;
      final name = _current.text;
      _pos++;
      if (_isPunct('=')) {
        _pos++;
        final value = _expr();
        _consumeOptionalSemi();
        return AssignStmt(name, value);
      }
      _pos = savedPos;
    }
    final expr = _expr();
    _consumeOptionalSemi();
    return ExprStmt(expr);
  }

  List<StmtNode> _blockOrSingle() {
    if (_isPunct('{')) return _block();
    return [_statement()];
  }

  List<StmtNode> _block() {
    _expect('punct', '{');
    final stmts = <StmtNode>[];
    while (!_isPunct('}')) {
      if (_current.type == 'end') {
        throw ExpressionEvalError('unterminated block');
      }
      stmts.add(_statement());
    }
    _pos++; // consume '}'
    return stmts;
  }

  ExprNode _expr() => _ternary();

  ExprNode _ternary() {
    final cond = _logicalOr();
    if (_isPunct('?')) {
      _pos++;
      final thenExpr = _expr();
      _expect('punct', ':');
      final elseExpr = _expr();
      return TernaryNode(cond, thenExpr, elseExpr);
    }
    return cond;
  }

  ExprNode _logicalOr() {
    var node = _logicalAnd();
    while (_isPunct('||')) {
      _pos++;
      node = LogicalNode('||', node, _logicalAnd());
    }
    return node;
  }

  ExprNode _logicalAnd() {
    var node = _equality();
    while (_isPunct('&&')) {
      _pos++;
      node = LogicalNode('&&', node, _equality());
    }
    return node;
  }

  ExprNode _equality() {
    var node = _relational();
    while (_isPunct('==') || _isPunct('!=')) {
      final op = _current.text;
      _pos++;
      node = CompareNode(op, node, _relational());
    }
    return node;
  }

  ExprNode _relational() {
    var node = _additive();
    while (_isPunct('<') || _isPunct('>') || _isPunct('<=') || _isPunct('>=')) {
      final op = _current.text;
      _pos++;
      node = CompareNode(op, node, _additive());
    }
    return node;
  }

  ExprNode _additive() {
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
    while (_isPunct('*') || _isPunct('/') || _isPunct('%')) {
      final op = _current.text;
      _pos++;
      node = BinaryNode(op, node, _unary());
    }
    return node;
  }

  ExprNode _unary() {
    if (_isPunct('-') || _isPunct('!')) {
      final op = _current.text;
      _pos++;
      return UnaryNode(op, _unary());
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
    if (_isPunct('[')) {
      _pos++;
      final elements = <ExprNode>[];
      if (!_isPunct(']')) {
        elements.add(_expr());
        while (_isPunct(',')) {
          _pos++;
          elements.add(_expr());
        }
      }
      _expect('punct', ']');
      return ArrayNode(elements);
    }
    throw ExpressionEvalError('unexpected token "${_current.text}"');
  }
}

/// Parses the full raw `x` expression body (already including any
/// `var $bm_rt;`/control-flow/helper statements) into a sequence of
/// statements, ready for [runProgram].
List<StmtNode> parseProgram(String source) =>
    _Parser(_tokenize(source)).parseProgram();

// --- Evaluation context ---------------------------------------------------

/// Marks a resolved `thisComp` reference during evaluation. Only valid as
/// the target of a `.layer(...)` call.
class ThisCompRef {
  const ThisCompRef();
}

/// Marks a resolved `Math` reference during evaluation. Only valid as the
/// target of a `Math.<const>` member access or `Math.<fn>(...)` call.
class MathRef {
  const MathRef();
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

/// A resolved-but-not-yet-sampled reference to a raw Lottie property map
/// (`<layerRef>.transform.position`, etc.). Kept lazy so `.valueAtTime(t)`
/// can sample it at an arbitrary time; anywhere else it's consumed, it's
/// forced to a concrete value at the context's current time.
class PropertyRef {
  PropertyRef(this.prop);
  final Map<String, dynamic> prop;
}

const _transformAliasToKey = {
  'position': 'p',
  'rotation': 'r',
  'scale': 's',
  'opacity': 'o',
  'anchorPoint': 'a',
  'skew': 'sk',
  'skewAxis': 'sa',
};

/// Per-property evaluation state: everything [runProgram] needs to resolve
/// `time`, cross-layer references, and the `random`/`wiggle` builtins for
/// one sampling pass. Reused across every frame sampled for the same
/// property so `random`/`wiggle` advance deterministically frame-by-frame.
class EvalContext {
  EvalContext({
    required this.layers,
    required this.selfLayer,
    required this.fr,
    required this.targetDims,
    required this.baseValue,
    required int seed,
  }) : _rng = Random(seed);

  /// The layers array containing the layer this expression lives on —
  /// the scope `thisComp.layer(name)` searches.
  final List<Map<String, dynamic>> layers;

  /// The layer this expression itself lives on — what `thisLayer` and bare
  /// `transform` (sugar for `thisLayer.transform`) resolve to.
  final Map<String, dynamic> selfLayer;

  /// Composition frame rate, for converting `time` (seconds) to the frame
  /// numbers keyframes are stored in.
  final num fr;

  /// Number of components the baked property's value needs (1 for a scalar
  /// like rotation/opacity, otherwise the length of its vector).
  final int targetDims;

  /// The property's own pre-expression value at the current frame,
  /// broadcast to [targetDims] components — the center that `wiggle()`
  /// jitters around and what the `value` identifier resolves to. Constant
  /// for a never-keyframed property; updated per-frame by the caller when
  /// the property already has real keyframes (an expression layered on top
  /// of them samples the original curve, matching how After Effects treats
  /// `value`).
  List<num> baseValue;

  /// Set by a `posterizeTime(fps)` call during the current run; quantizes
  /// [timeSeconds] to `fps` steps/second for the remainder of that run.
  /// Reset to null at the start of every [runProgram] call.
  num? posterizeFps;

  final Random _rng;

  /// Wiggle knots, keyed first by the source-level `wiggle(...)` call site
  /// (so two different calls in the same expression — e.g. layered octave
  /// noise like `wiggle(1,50) + wiggle(5,10)` — never collide just because
  /// their knot indices happen to coincide) and then by knot index. Safe to
  /// key by `CallNode` identity: `program` is parsed once and reused for
  /// every frame sampled for this property, so each call site's node is
  /// stable across the whole bake.
  final Map<CallNode, Map<int, List<num>>> _wiggleKnotsByCall = {};

  /// Current sample time in frames; set by the caller before each
  /// [runProgram] call.
  num timeFrame = 0;

  num get timeSeconds {
    final raw = timeFrame / fr;
    final fps = posterizeFps;
    if (fps == null || fps <= 0) return raw;
    return (raw * fps).floorToDouble() / fps;
  }
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

bool _truthy(dynamic v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  if (v is List) return v.isNotEmpty;
  return v != null;
}

bool _valueEquals(dynamic l, dynamic r) {
  if (l is List && r is List) {
    if (l.length != r.length) return false;
    for (var i = 0; i < l.length; i++) {
      if (!_valueEquals(l[i], r[i])) return false;
    }
    return true;
  }
  return l == r;
}

bool _compare(String op, dynamic l, dynamic r) {
  if (l is num && r is num) {
    return switch (op) {
      '<' => l < r,
      '>' => l > r,
      '<=' => l <= r,
      '>=' => l >= r,
      '==' => l == r,
      '!=' => l != r,
      _ => throw ExpressionEvalError('unknown comparison operator "$op"'),
    };
  }
  if (op == '==') return _valueEquals(l, r);
  if (op == '!=') return !_valueEquals(l, r);
  throw ExpressionEvalError('cannot compare these operand types with "$op"');
}

dynamic _applyBinary(String op, dynamic l, dynamic r) {
  if (l is num && r is num) {
    return switch (op) {
      '+' => l + r,
      '-' => l - r,
      '*' => l * r,
      '/' => l / r,
      '%' => l % r,
      _ => throw ExpressionEvalError('unknown operator "$op"'),
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
  throw ExpressionEvalError('unsupported operand types for "$op"');
}

dynamic _lerp(dynamic a, dynamic b, num f) {
  if (a is num && b is num) return a + (b - a) * f;
  if (a is List<num> && b is List<num>) {
    if (a.length != b.length) {
      throw ExpressionEvalError('vector length mismatch');
    }
    return [for (var i = 0; i < a.length; i++) a[i] + (b[i] - a[i]) * f];
  }
  throw ExpressionEvalError('mismatched operand shapes for interpolation');
}

/// `linear`/`ease`/`easeIn`/`easeOut`, either as `fn(t, val1, val2)` (t
/// implicitly clamped to `[0, 1]`) or `fn(t, tMin, tMax, val1, val2)`. `ease`
/// applies a smoothstep curve, `easeIn`/`easeOut` a quadratic one — an
/// approximation of AE's bezier-based easing, not a bit-exact match (the same
/// tradeoff this package already makes for `random`/`wiggle`).
dynamic _interpolate(String kind, List<dynamic> args) {
  final num t;
  final num tMin;
  final num tMax;
  final dynamic v1;
  final dynamic v2;
  if (args.length == 3) {
    t = _asNum(args[0]);
    tMin = 0;
    tMax = 1;
    v1 = args[1];
    v2 = args[2];
  } else if (args.length == 5) {
    t = _asNum(args[0]);
    tMin = _asNum(args[1]);
    tMax = _asNum(args[2]);
    v1 = args[3];
    v2 = args[4];
  } else {
    throw ExpressionEvalError('$kind() expects 3 or 5 arguments');
  }
  var f = tMax == tMin ? 1.0 : ((t - tMin) / (tMax - tMin));
  f = f.clamp(0.0, 1.0);
  f = switch (kind) {
    'linear' => f,
    'ease' => f * f * (3 - 2 * f),
    'easeIn' => f * f,
    'easeOut' => 1 - (1 - f) * (1 - f),
    _ => throw ExpressionEvalError('unknown interpolation "$kind"'),
  };
  return _lerp(v1, v2, f);
}

dynamic _clamp(dynamic value, dynamic minV, dynamic maxV) {
  num clampOne(num v, num lo, num hi) => v < lo ? lo : (v > hi ? hi : v);
  if (value is num) return clampOne(value, _asNum(minV), _asNum(maxV));
  if (value is List<num>) {
    List<num> broadcast(dynamic v) =>
        v is List<num> ? v : List<num>.filled(value.length, _asNum(v));
    final lo = broadcast(minV);
    final hi = broadcast(maxV);
    return [
      for (var i = 0; i < value.length; i++) clampOne(value[i], lo[i], hi[i]),
    ];
  }
  throw ExpressionEvalError('clamp() expects a number or vector value');
}

num _callMath(String name, List<num> args) {
  num arg(int i) => args[i];
  return switch (name) {
    'sin' => sin(arg(0)),
    'cos' => cos(arg(0)),
    'tan' => tan(arg(0)),
    'asin' => asin(arg(0)),
    'acos' => acos(arg(0)),
    'atan' => atan(arg(0)),
    'atan2' => atan2(arg(0), arg(1)),
    'abs' => arg(0).abs(),
    'sqrt' => sqrt(arg(0)),
    'pow' => pow(arg(0), arg(1)),
    'floor' => arg(0).floorToDouble(),
    'ceil' => arg(0).ceilToDouble(),
    'round' => arg(0).roundToDouble(),
    'max' => args.reduce((a, b) => a > b ? a : b),
    'min' => args.reduce((a, b) => a < b ? a : b),
    'log' => log(arg(0)),
    'exp' => exp(arg(0)),
    _ => throw ExpressionEvalError('unsupported Math.$name(...)'),
  };
}

/// Resolves a `PropertyRef` left over from a member-access chain into its
/// concrete sampled value at the context's current frame. Every consumer of
/// an evaluated expression forces its operands (arithmetic, comparisons,
/// array elements, function arguments, final statement values) except the
/// `.valueAtTime(t)` handler, which needs the still-lazy [PropertyRef] to
/// sample it at a caller-chosen time instead.
dynamic _force(dynamic v, EvalContext ctx) {
  if (v is PropertyRef) return sampleRawProperty(v.prop, ctx.timeFrame);
  return v;
}

/// Evaluates [node] against [ctx]/[vars]. Returns a `num`, `List<num>`,
/// `String`, `bool`, or one of [ThisCompRef]/[MathRef]/[LayerRef]/
/// [TransformRef]/[PropertyRef] (only valid as an intermediate value in a
/// member/call chain — reaching a place that needs a concrete value with one
/// of those left over is an error, [PropertyRef] excepted, which [_force]
/// resolves on demand).
dynamic _eval(ExprNode node, EvalContext ctx, Map<String, dynamic> vars) {
  switch (node) {
    case NumNode n:
      return n.value;
    case StrNode s:
      return s.value;
    case ArrayNode a:
      return [
        for (final e in a.elements) _asNum(_force(_eval(e, ctx, vars), ctx)),
      ];
    case IdentNode id:
      if (vars.containsKey(id.name)) return vars[id.name];
      switch (id.name) {
        case 'time':
          return ctx.timeSeconds;
        case 'thisComp':
          return const ThisCompRef();
        case 'thisLayer':
          return LayerRef(ctx.selfLayer);
        case 'transform':
          return _resolveMember(LayerRef(ctx.selfLayer), 'transform', ctx);
        case 'Math':
          return const MathRef();
        case 'PI':
          return pi;
        case 'value':
          return ctx.targetDims == 1
              ? ctx.baseValue[0]
              : List<num>.from(ctx.baseValue);
        case 'true':
          return true;
        case 'false':
          return false;
      }
      throw ExpressionEvalError('unknown identifier "${id.name}"');
    case UnaryNode u:
      final v = _force(_eval(u.operand, ctx, vars), ctx);
      return u.op == '!' ? !_truthy(v) : -_asNum(v);
    case BinaryNode b:
      return _applyBinary(
        b.op,
        _force(_eval(b.left, ctx, vars), ctx),
        _force(_eval(b.right, ctx, vars), ctx),
      );
    case CompareNode c:
      return _compare(
        c.op,
        _force(_eval(c.left, ctx, vars), ctx),
        _force(_eval(c.right, ctx, vars), ctx),
      );
    case LogicalNode l:
      final left = _force(_eval(l.left, ctx, vars), ctx);
      if (l.op == '&&') {
        return _truthy(left) && _truthy(_force(_eval(l.right, ctx, vars), ctx));
      }
      return _truthy(left) || _truthy(_force(_eval(l.right, ctx, vars), ctx));
    case TernaryNode t:
      final cond = _truthy(_force(_eval(t.cond, ctx, vars), ctx));
      return cond ? _eval(t.thenExpr, ctx, vars) : _eval(t.elseExpr, ctx, vars);
    case IndexNode ix:
      final target = _force(_eval(ix.target, ctx, vars), ctx);
      final index = _asNum(_force(_eval(ix.index, ctx, vars), ctx)).toInt();
      if (target is List) return target[index];
      throw ExpressionEvalError('cannot index a non-list value');
    case MemberNode m:
      return _resolveMember(_eval(m.target, ctx, vars), m.name, ctx);
    case CallNode c:
      return _resolveCall(c, ctx, vars);
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
    return PropertyRef(prop);
  }
  if (target is MathRef) {
    return switch (name) {
      'PI' => pi,
      'E' => e,
      _ => throw ExpressionEvalError('unknown "Math.$name"'),
    };
  }
  throw ExpressionEvalError('cannot access ".$name" on this value');
}

dynamic _resolveCall(
  CallNode call,
  EvalContext ctx,
  Map<String, dynamic> vars,
) {
  final callee = call.callee;
  if (callee is MemberNode) {
    final name = callee.name;
    if (name == 'layer') {
      final target = _eval(callee.target, ctx, vars);
      if (target is! ThisCompRef) {
        throw ExpressionEvalError('"layer" is only supported on thisComp');
      }
      if (call.args.length != 1) {
        throw ExpressionEvalError('layer() expects exactly one argument');
      }
      final selector = _force(_eval(call.args.single, ctx, vars), ctx);
      final layer = findLayer(ctx.layers, selector);
      if (layer == null) {
        throw ExpressionEvalError('layer "$selector" not found');
      }
      return LayerRef(layer);
    }
    if (name == 'valueAtTime') {
      final target = _eval(callee.target, ctx, vars);
      if (target is! PropertyRef) {
        throw ExpressionEvalError(
          'valueAtTime() is only supported on a transform property reference',
        );
      }
      if (call.args.length != 1) {
        throw ExpressionEvalError('valueAtTime() expects exactly one argument');
      }
      final tSeconds = _asNum(_force(_eval(call.args.single, ctx, vars), ctx));
      return sampleRawProperty(target.prop, tSeconds * ctx.fr);
    }
    final target = _eval(callee.target, ctx, vars);
    if (target is MathRef) {
      final args = call.args
          .map((a) => _asNum(_force(_eval(a, ctx, vars), ctx)))
          .toList();
      return _callMath(name, args);
    }
    throw ExpressionEvalError('unsupported method call ".$name(...)"');
  }
  if (callee is IdentNode) {
    switch (callee.name) {
      case 'random':
        {
          final args = call.args
              .map((a) => _asNum(_force(_eval(a, ctx, vars), ctx)))
              .toList();
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
      case 'wiggle':
        {
          if (call.args.length < 2) {
            throw ExpressionEvalError('wiggle() expects at least (freq, amp)');
          }
          final freq = _asNum(_force(_eval(call.args[0], ctx, vars), ctx));
          final amp = _asNum(_force(_eval(call.args[1], ctx, vars), ctx));
          if (freq <= 0) {
            throw ExpressionEvalError('wiggle() frequency must be positive');
          }
          final knotPos = ctx.timeSeconds * freq;
          final index = knotPos.floor();
          final frac = knotPos - index;
          final knots = ctx._wiggleKnotsByCall.putIfAbsent(call, () => {});
          List<num> knotAt(int i) => knots.putIfAbsent(i, () {
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
      case 'linear':
      case 'ease':
      case 'easeIn':
      case 'easeOut':
        {
          final args = call.args
              .map((a) => _force(_eval(a, ctx, vars), ctx))
              .toList();
          return _interpolate(callee.name, args);
        }
      case 'clamp':
        {
          if (call.args.length != 3) {
            throw ExpressionEvalError(
              'clamp() expects exactly three arguments',
            );
          }
          final value = _force(_eval(call.args[0], ctx, vars), ctx);
          final minV = _force(_eval(call.args[1], ctx, vars), ctx);
          final maxV = _force(_eval(call.args[2], ctx, vars), ctx);
          return _clamp(value, minV, maxV);
        }
      case 'add':
      case 'sub':
      case 'mul':
      case 'div':
        {
          if (call.args.length != 2) {
            throw ExpressionEvalError(
              '${callee.name}() expects exactly two arguments',
            );
          }
          final a = _force(_eval(call.args[0], ctx, vars), ctx);
          final b = _force(_eval(call.args[1], ctx, vars), ctx);
          final op = const {
            'add': '+',
            'sub': '-',
            'mul': '*',
            'div': '/',
          }[callee.name]!;
          return _applyBinary(op, a, b);
        }
      case 'posterizeTime':
        {
          if (call.args.length != 1) {
            throw ExpressionEvalError(
              'posterizeTime() expects exactly one argument',
            );
          }
          final fps = _asNum(_force(_eval(call.args[0], ctx, vars), ctx));
          ctx.posterizeFps = fps > 0 ? fps : null;
          return null;
        }
      case 'seedRandom':
        // This evaluator's random()/wiggle() seeding is already
        // deterministic and independent of AE's seedRandom() call, so
        // recognizing (rather than rejecting) it just avoids reporting an
        // otherwise fully-supported expression as unsupported.
        return null;
    }
    throw ExpressionEvalError(
      'unsupported function call "${callee.name}(...)"',
    );
  }
  throw ExpressionEvalError('unsupported function call');
}

/// Executes [program] against [ctx] and returns the resulting value: the
/// last value assigned to `$bm_rt` if there was one, else the value of the
/// last executed assignment/bare-expression statement (matching how a
/// simplified one-line expression with no `$bm_rt` wrapper, used in a few
/// tests/hand-written fixtures, still produces a value). Resets
/// [EvalContext.posterizeFps] at the start of the run.
dynamic runProgram(List<StmtNode> program, EvalContext ctx) {
  ctx.posterizeFps = null;
  final vars = <String, dynamic>{};
  dynamic lastValue;

  void exec(List<StmtNode> stmts) {
    for (final stmt in stmts) {
      switch (stmt) {
        case VarDeclStmt v:
          if (v.init != null) {
            vars[v.name] = _force(_eval(v.init!, ctx, vars), ctx);
          }
        case AssignStmt a:
          final value = _force(_eval(a.value, ctx, vars), ctx);
          vars[a.name] = value;
          lastValue = value;
        case ExprStmt e:
          lastValue = _force(_eval(e.expr, ctx, vars), ctx);
        case IfStmt f:
          if (_truthy(_force(_eval(f.cond, ctx, vars), ctx))) {
            exec(f.thenBranch);
          } else if (f.elseBranch != null) {
            exec(f.elseBranch!);
          }
        case GroupStmt g:
          exec(g.body);
      }
    }
  }

  exec(program);
  return vars.containsKey(r'$bm_rt') ? vars[r'$bm_rt'] : lastValue;
}
