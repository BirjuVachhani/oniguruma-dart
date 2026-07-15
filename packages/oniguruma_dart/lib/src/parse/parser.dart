/// Recursive-descent parser (`regparse.c`): pattern bytes → [Node] AST.
///
/// Mirrors the C `prs_*` call chain: [_prsRegexp] → [_prsAlts] → [_prsBranch]
/// → [_prsExp], with [_prsBag] for groups and [_prsCc] for character classes.
/// Uses C's single-token lookahead model: [_tok] always holds the current
/// unconsumed token; [_fetchToken] advances. Metacharacters are gated on the
/// active [OnigSyntax] flags exactly as in the C source.
library;

import 'dart:typed_data';

import '../compile/operation.dart' show SaveType, UpdateVarType;
import '../encoding/encoding.dart';
import '../onig_errors.dart';
import '../onig_types.dart';
import '../syntax.dart';
import '../unicode/unicode.dart' as uni;
import 'node.dart';
import 'token.dart';

/// Default parse depth limit (`DEFAULT_PARSE_DEPTH_LIMIT`).
const int parseDepthLimit = 4096;

/// Sentinel ctype id for the `.` anychar node (a `CtypeNode`).
const int ctAnychar = -1;

/// Sentinel ctype id for `\X` extended grapheme cluster (a `CtypeNode`).
const int ctGrapheme = -2;

/// Thrown internally to unwind on a parse error; carries an `ONIGERR_*` code.
class ParseError implements Exception {
  final int code;
  final String? detail;
  ParseError(this.code, [this.detail]);
  @override
  String toString() => 'ParseError($code): ${onigErrorCodeToStr(code)}';
}

/// Result of parsing: the AST root plus discovered group metadata.
class ParseResult {
  final Node? root;
  final int numMem;
  final int numNamed;
  final Map<String, List<int>> nameTable;
  final List<BagNode?> memNodes;

  /// Whole-pattern option bits from `(?I/L/C)` to OR into `reg.options`.
  final int wholeOptions;
  ParseResult(
    this.root,
    this.numMem,
    this.numNamed,
    this.nameTable,
    this.memNodes,
    this.wholeOptions,
  );
}

/// Parse [pattern] (`[0, end)`) under [enc]/[syntax]/[options]; returns the AST.
ParseResult parseTree(
  Uint8List pattern,
  int end,
  OnigEncoding enc,
  OnigSyntax syntax,
  int options,
  int caseFoldFlag,
) {
  final parser = _Parser(pattern, end, enc, syntax, options, caseFoldFlag);
  final root = parser.parse();
  return ParseResult(
    root,
    parser.numMem,
    parser.numNamed,
    parser.nameTable,
    parser.memNodes,
    parser.wholeOptions,
  );
}

// ASCII byte constants.
const int _cBackslash = 0x5c;

class _Parser {
  final Uint8List s;
  final int end;
  final OnigEncoding enc;
  final OnigSyntax syn;
  final int caseFoldFlag;

  int p = 0; // cursor into s
  int _pprev = 0; // position of the char most recently fetched (`PPREV`)
  int options;
  int parseDepth = 0;

  int numMem = 0;
  int numNamed = 0;
  int numCall = 0;
  int numCallout = 0;
  bool _hasCallZero =
      false; // a `\g<0>` call → wrap the whole pattern (group 0)
  bool _hasWholeOptions = false; // a `(?I/L/C)` whole-pattern option seen
  int _wholeOptions = 0; // whole-pattern option bits to OR into reg.options
  int _groupOpenPos = 0; // byte offset of the current group's '('
  bool _ccInRangeHi = false; // reading the HI of a class range `lo-\x{…}`
  int get wholeOptions => _wholeOptions;
  final List<BagNode?> memNodes = <BagNode?>[null];
  final Map<String, List<int>> nameTable = <String, List<int>>{};

  final PToken _tok = PToken();

  _Parser(
    this.s,
    this.end,
    this.enc,
    this.syn,
    this.options,
    this.caseFoldFlag,
  );

  // --- byte / char reading -------------------------------------------------

  bool get _pend => p >= end;

  /// Decode one char at [p] and advance; returns its code point.
  int _fetchChar() {
    _pprev = p;
    final len = enc.length(s, p, end);
    final code = enc.mbcToCode(s, p, end);
    p += len;
    return code;
  }

  /// Code point at [p] without advancing (-1 at end). Encoding-aware so the
  /// syntax layer works for wide encodings (UTF-16/32) where ASCII
  /// metacharacters and digits occupy several bytes.
  int _peekCode() => _pend ? -1 : enc.mbcToCode(s, p, end);

  /// Code point of the char *after* the current one (-1 if none).
  int _peekCode2() {
    if (_pend) return -1;
    final n = enc.length(s, p, end);
    if (p + n >= end) return -1;
    return enc.mbcToCode(s, p + n, end);
  }

  /// Advance [p] past one char.
  void _skipCode() {
    if (!_pend) p += enc.length(s, p, end);
  }

  ParseError _err(int code, [String? d]) => ParseError(code, d);

  /// Is [code] the syntax's escape metacharacter (`IS_MC_ESC_CODE`)?
  bool _isMcEsc(int code) =>
      code == _cBackslash && !syn.isOp2(SynOp2.ineffectiveEscape);

  /// BRE: is the `^` at byte [caret] the head of a (sub)expression, i.e. at
  /// pattern start or right after `\(` / `\|`? (`is_head_of_bre_subexp`.)
  bool _isHeadOfBreSubexp(int caret) {
    const start = 0;
    if (caret <= start) return true;
    var q = enc.leftAdjustCharHead(s, start, caret - 1); // char before '^'
    if (q > start) {
      var code = enc.mbcToCode(s, q, end);
      if (code == 0x28 /* ( */ ||
          (code == 0x7c /* | */ && syn.isOp(SynOp.escVbarAlt))) {
        q = enc.leftAdjustCharHead(s, start, q - 1); // char before '(' / '|'
        code = enc.mbcToCode(s, q, end);
        if (_isMcEsc(code)) {
          var count = 0;
          while (q > start) {
            q = enc.leftAdjustCharHead(s, start, q - 1);
            code = enc.mbcToCode(s, q, end);
            if (!_isMcEsc(code)) break;
            count++;
          }
          return count % 2 == 0;
        }
      }
    }
    return false;
  }

  /// BRE: is the position [q] (just after `$`) the end of a (sub)expression,
  /// i.e. at pattern end or right before `\)` / `\|`? (`is_end_of_bre_subexp`.)
  bool _isEndOfBreSubexp(int q) {
    if (q >= end) return true;
    var code = enc.mbcToCode(s, q, end);
    if (_isMcEsc(code)) {
      q += enc.length(s, q, end);
      if (q < end) {
        code = enc.mbcToCode(s, q, end);
        if (code == 0x29 /* ) */ ||
            (code == 0x7c /* | */ && syn.isOp(SynOp.escVbarAlt))) {
          return true;
        }
      }
    }
    return false;
  }

  void _incDepth() {
    if (++parseDepth > parseDepthLimit) throw _err(OnigErr.parseDepthLimitOver);
  }

  void _decDepth() => parseDepth--;

  bool _opton(int f) => (options & f) != 0;

  /// ASCII-mode for a ctype under the current options (`OPTON_IS_ASCII_MODE_CTYPE`).
  bool _ctypeAsciiMode(int ctype) {
    const posix = OnigOption.posixIsAscii;
    switch (ctype) {
      case CType.word:
        return _opton(OnigOption.wordIsAscii | posix);
      case CType.digit:
        return _opton(OnigOption.digitIsAscii | posix);
      case CType.space:
        return _opton(OnigOption.spaceIsAscii | posix);
      default:
        return ctype >= 0 && ctype < CType.ascii && _opton(posix);
    }
  }

  // --- top level -----------------------------------------------------------

  Node? parse() {
    // `onig_parse_tree`: the raw pattern must be a valid MBC string.
    if (!enc.isValidMbcString(s, 0, end)) {
      throw _err(OnigErr.invalidCodePointValue); // INVALID_WIDE_CHAR_VALUE
    }
    _fetchToken();
    var root = _prsAlts(TokenType.subexpClose, topLevel: true);
    if (_tok.type != TokenType.eot) {
      // leftover ')' or similar
      if (_tok.type == TokenType.subexpClose) {
        throw _err(OnigErr.unmatchedCloseParenthesis);
      }
      throw _err(OnigErr.parserBug);
    }
    // `disable_noname_group_capture`: with named groups present (and the
    // CAPTURE_ONLY_NAMED_GROUP syntax, no CAPTURE_GROUP option), unnamed
    // groups become non-capturing and named ones are renumbered 1..N.
    if (numNamed > 0 &&
        numNamed != numMem &&
        syn.isBehavior(SynBv.captureOnlyNamedGroup) &&
        !_opton(OnigOption.captureGroup)) {
      root = _disableNonameGroupCapture(root);
    }
    // `\g<0>`: wrap the whole pattern in an implicit group 0 so it can be
    // called recursively (`make_call_zero_body`).
    if (_hasCallZero) {
      final zero = BagNode(BagType.memory)..regNum = 0;
      zero.body = root;
      root?.parent = zero;
      if (memNodes.isEmpty) {
        memNodes.add(zero);
      } else {
        memNodes[0] = zero;
      }
      root = zero;
    }
    // `check_whole_options_position`: a scoped `(?I:…)` whole-option must span
    // the entire pattern — if it sits in a list beside other content, reject.
    if (_hasWholeOptions && root != null) _checkWholeOptionsPosition(root);
    return root;
  }

  /// `disable_noname_group_capture`: rewrite the AST so only named groups
  /// capture (renumbered 1..N), then remap back-references, calls, `memNodes`
  /// and the name table.
  Node? _disableNonameGroupCapture(Node? root) {
    final map = <int, int>{}; // old regnum → new regnum
    final counter = [0];
    root = _mkNamedMap(root, map, counter);
    _renumberRefs(root, map);
    final newMem = <BagNode?>[null];
    for (var i = 1; i <= numMem; i++) {
      final nn = map[i];
      if (nn == null) continue;
      while (newMem.length <= nn) {
        newMem.add(null);
      }
      newMem[nn] = i < memNodes.length ? memNodes[i] : null;
    }
    memNodes
      ..clear()
      ..addAll(newMem);
    final newNames = <String, List<int>>{};
    nameTable.forEach((name, nums) {
      newNames[name] = [for (final n in nums) map[n] ?? n];
    });
    nameTable
      ..clear()
      ..addAll(newNames);
    numMem = numNamed;
    return root;
  }

  /// `make_named_capture_number_map`: drop unnamed memory groups (keep body),
  /// renumber named ones in traversal order.
  Node? _mkNamedMap(Node? node, Map<int, int> map, List<int> counter) {
    if (node == null) return null;
    switch (node) {
      case ListNode():
        final items = <Node>[];
        Node? cur = node;
        while (cur is ListNode) {
          final r = _mkNamedMap(cur.car, map, counter);
          if (r != null) items.add(r);
          cur = cur.cdr;
        }
        if (cur != null) {
          final r = _mkNamedMap(cur, map, counter);
          if (r != null) items.add(r);
        }
        return nodeNewListFrom(items) ?? _emptyNode();
      case AltNode():
        final items = <Node>[];
        Node? cur = node;
        while (cur is AltNode) {
          items.add(_mkNamedMap(cur.car, map, counter) ?? _emptyNode());
          cur = cur.cdr;
        }
        if (cur != null) {
          items.add(_mkNamedMap(cur, map, counter) ?? _emptyNode());
        }
        Node? tail;
        for (var i = items.length - 1; i >= 0; i--) {
          tail = AltNode(items[i], tail);
        }
        return tail;
      case QuantNode():
        node.body = _mkNamedMap(node.body, map, counter);
        return node;
      case AnchorNode():
        node.body = _mkNamedMap(node.body, map, counter);
        return node;
      case BagNode():
        if (node.type == BagType.memory && node.regNum != 0) {
          if (node.st(NdSt.namedGroup)) {
            counter[0]++;
            map[node.regNum] = counter[0];
            node.regNum = counter[0];
            node.body = _mkNamedMap(node.body, map, counter);
            return node;
          }
          // unnamed → replace with its (now non-capturing) body
          return _mkNamedMap(node.body, map, counter);
        }
        node.body = _mkNamedMap(node.body, map, counter);
        if (node.type == BagType.ifElse) {
          node.then_ = _mkNamedMap(node.then_, map, counter);
          node.else_ = _mkNamedMap(node.else_, map, counter);
        }
        return node;
      default:
        return node;
    }
  }

  void _renumberRefs(Node? node, Map<int, int> map) {
    if (node == null) return;
    switch (node) {
      case BackRefNode():
        node.back = [for (final b in node.back) map[b] ?? b];
      case CallNode():
        if (node.byNumber && node.calledGnum > 0) {
          node.calledGnum = map[node.calledGnum] ?? node.calledGnum;
        }
      case QuantNode():
        _renumberRefs(node.body, map);
      case AnchorNode():
        _renumberRefs(node.body, map);
      case BagNode():
        _renumberRefs(node.body, map);
        _renumberRefs(node.then_, map);
        _renumberRefs(node.else_, map);
      case ListNode():
        Node? c = node;
        while (c is ListNode) {
          _renumberRefs(c.car, map);
          c = c.cdr;
        }
        if (c != null) _renumberRefs(c, map);
      case AltNode():
        Node? c = node;
        while (c is AltNode) {
          _renumberRefs(c.car, map);
          c = c.cdr;
        }
        if (c != null) _renumberRefs(c, map);
      default:
        break;
    }
  }

  void _checkWholeOptionsPosition(Node root) {
    var node = root;
    // Skip the implicit group-0 wrapper (`make_call_zero_body`).
    if (_hasCallZero &&
        node is BagNode &&
        node.type == BagType.memory &&
        node.regNum == 0 &&
        node.body != null) {
      node = node.body!;
    }
    var isList = false;
    while (node is ListNode) {
      if (node.cdr != null) isList = true;
      node = node.car;
    }
    if (node is BagNode &&
        node.type == BagType.option &&
        node.st(NdSt.wholeOptions) &&
        isList &&
        node.body != null) {
      throw _err(OnigErr.invalidGroupOption);
    }
  }

  /// `prs_alts` — one or more `|`-separated branches. [term] is the closing
  /// token expected by the caller ([TokenType.eot] at top level).
  Node? _prsAlts(TokenType term, {bool topLevel = false}) {
    _incDepth();
    // `prs_alts`: env->options is restored only at the END, not between
    // branches — so an isolated `(?s)` in one branch leaks into the following
    // branches (ONIG_SYN_ISOLATED_OPTION_CONTINUE_BRANCH).
    final savedOptions = options;
    final branches = <Node>[_prsBranch(term) ?? _emptyNode()];
    while (_tok.type == TokenType.alt) {
      _fetchToken();
      branches.add(_prsBranch(term) ?? _emptyNode());
    }
    options = savedOptions;
    _decDepth();

    if (branches.length == 1) return branches.first;
    Node? tail;
    for (var i = branches.length - 1; i >= 0; i--) {
      tail = AltNode(branches[i], tail);
    }
    return tail;
  }

  /// `prs_branch` — concatenation of expressions up to `|` / [term] / EOT.
  Node? _prsBranch(TokenType term) {
    _incDepth();
    final items = <Node>[];
    while (_tok.type != TokenType.eot &&
        _tok.type != TokenType.alt &&
        !(term == TokenType.subexpClose &&
            _tok.type == TokenType.subexpClose)) {
      final node = _prsExp(term);
      if (node != null) _appendSequence(items, node);
    }
    _decDepth();
    if (items.isEmpty) return _emptyNode();
    if (items.length == 1) return items.first;
    return nodeNewListFrom(items);
  }

  /// Splice a list-node's cells inline (matches C `prs_branch` list handling).
  void _appendSequence(List<Node> items, Node node) {
    if (node is ListNode) {
      Node? cur = node;
      while (cur is ListNode) {
        items.add(cur.car);
        cur = cur.cdr;
      }
      if (cur != null) items.add(cur);
    } else {
      items.add(node);
    }
  }

  Node _emptyNode() => StrNode();

  // --- expression ----------------------------------------------------------

  /// `prs_exp` — one element plus any trailing quantifiers. Enters with [_tok]
  /// holding the element's first token; returns with [_tok] at the lookahead.
  Node? _prsExp(TokenType term) {
    _incDepth();
    try {
      Node node;
      switch (_tok.type) {
        case TokenType.eot:
        case TokenType.alt:
        case TokenType.subexpClose:
          return _emptyNode();

        case TokenType.subexpOpen:
          final prevOptions = options;
          final grp = _prsBag();
          if (grp == null) {
            // Option-only group `(?flags)`. `_parseOptionGroup` set `options`
            // to the new value.
            final optNew = options;
            _fetchToken();
            if (syn.isBehavior(SynBv.isolatedOptionContinueBranch)) {
              // Isolated: options persist for the rest of the branch only.
              return _emptyNode();
            }
            // Default (Oniguruma/Ruby): the option scopes to the end of the
            // enclosing alternation — wrap the remainder in an option group.
            final rest = _prsAlts(term) ?? _emptyNode();
            options = prevOptions;
            final bag = BagNode(BagType.option)..options = optNew;
            bag.body = rest;
            rest.parent = bag;
            return bag;
          }
          node = grp;
          _fetchToken();

        case TokenType.openCc:
          node = _prsCc();
          _fetchToken();

        case TokenType.anychar:
          node = _anycharNode(env: false);
          _fetchToken();

        case TokenType.anycharAnytime:
          // `.*` shortcut
          final an = _anycharNode(env: false);
          final q = QuantNode(0, infiniteRepeat, greedy: true);
          q.body = an;
          an.parent = q;
          _fetchToken();
          return q;

        case TokenType.trueAnychar:
          node = _anycharNode(env: false, trueAny: true);
          _fetchToken();

        case TokenType.charType:
          // `\w`/`\W` stay a ctype op (OP_WORD); `\d`/`\s`/`\h` become a
          // character class so their full Unicode ranges apply by default
          // (regparse.c TK_CHAR_TYPE: node_new_cclass + add_ctype_to_cc).
          if (_tok.propCtype == CType.word) {
            node = CtypeNode(
              CType.word,
              not: _tok.propNot,
              asciiMode: _ctypeAsciiMode(CType.word),
            );
          } else {
            final cc = CClassNode();
            _ccAddCtype(cc, _tok.propCtype, false); // positive ranges
            if (_tok.propNot) cc.setNot();
            node = cc;
          }
          _fetchToken();

        case TokenType.charProperty:
          node = _charPropertyNode(_tok.propName, _tok.propNot);
          _fetchToken();

        case TokenType.generalNewline:
          node = _generalNewlineNode();
          _fetchToken();

        case TokenType.noNewline:
          node = CtypeNode(ctAnychar); // no multiline: never matches \n
          _fetchToken();

        case TokenType.keep:
          node = GimmickNode(GimmickType.save);
          _fetchToken();

        case TokenType.textSegment:
          node = CtypeNode(ctGrapheme); // \X extended grapheme cluster
          if (_opton(OnigOption.textSegmentWord)) {
            node.setSt(NdSt.textSegmentWord);
          }
          _fetchToken();

        case TokenType.call:
          node = CallNode(
            byNumber: _tok.callByNumber,
            calledGnum: _tok.callGnum ?? -1,
            name: _tok.callByNumber ? null : _tok.propName,
          );
          _fetchToken();

        case TokenType.anchor:
          final an = AnchorNode(_tok.anchorSubtype)
            ..asciiMode = _tok.anchorAsciiMode;
          if ((_tok.anchorSubtype == Anchor.textSegmentBoundary ||
                  _tok.anchorSubtype == Anchor.noTextSegmentBoundary) &&
              _opton(OnigOption.textSegmentWord)) {
            an.setSt(NdSt.textSegmentWord);
          }
          node = an;
          _fetchToken();

        case TokenType.backref:
          node = BackRefNode(_tok.backrefRefs ?? [_tok.backrefRef1])
            ..nestLevel = _tok.backrefLevel
            ..hasLevel = _tok.backrefExistLevel
            ..ignoreCase = _opton(OnigOption.ignoreCase);
          if (_tok.backrefByName) node.setSt(NdSt.byName);
          _fetchToken();

        case TokenType.crudeByte:
          // `\xHH` / octal raw bytes form one MBC that must be well-formed
          // (regparse.c TK_CRUDE_BYTE handling): gather enough bytes, else
          // -206; validate the sequence, else -400.
          node = _assembleCrudeMbc();

        case TokenType.char:
        case TokenType.codePoint:
          node = _assembleString();
        // _assembleString leaves _tok at the lookahead already.

        case TokenType.repeat:
        case TokenType.interval:
          // A repeat operator with no preceding target (regcomp `prs_exp`).
          if (syn.isBehavior(SynBv.contextIndepRepeatOps)) {
            if (syn.isBehavior(SynBv.contextInvalidRepeatOps)) {
              throw _err(OnigErr.targetOfRepeatOperatorNotSpecified);
            }
            node = _emptyNode(); // repeat applies to an empty target
          } else {
            // treat the operator as a literal character
            node = StrNode()..catByte(_tok.byteVal);
            _fetchToken();
          }

        default:
          throw _err(OnigErr.parserBug);
      }

      return _maybeQuantify(node, term);
    } finally {
      _decDepth();
    }
  }

  /// Assemble consecutive char/codepoint/byte tokens into one [StrNode],
  /// leaving [_tok] at the first non-string token.
  Node _assembleString() {
    final str = StrNode();
    _appendTokenChar(str);
    while (true) {
      _fetchToken();
      if (_tok.type == TokenType.char || _tok.type == TokenType.codePoint) {
        _appendTokenChar(str);
      } else {
        break;
      }
    }
    if (_opton(OnigOption.ignoreCase)) str.setSt(NdSt.ignoreCase);
    return str;
  }

  /// Gather one raw-byte MBC (`\xHH` / `\NNN`) and validate it. The lead byte
  /// fixes the expected byte count; each subsequent byte must also be a crude
  /// byte (else `-206`), and the whole sequence must be a valid MBC (else
  /// `-400`). Leaves [_tok] at the lookahead.
  Node _assembleCrudeMbc() {
    final str = StrNode()..setCrude();
    final firstByte = _tok.byteVal;
    str.catByte(firstByte);
    final expect = enc.lengthByFirstByte(firstByte);
    var len = 1;
    while (len < expect) {
      _fetchToken();
      if (_tok.type != TokenType.crudeByte) {
        throw _err(OnigErr.tooShortMultiByteString);
      }
      str.catByte(_tok.byteVal);
      len++;
    }
    _fetchToken(); // lookahead
    if (!enc.isValidMbcString(str.bytes, 0, str.len)) {
      throw _err(
        OnigErr.invalidCodePointValue,
      ); // ONIGERR_INVALID_WIDE_CHAR_VALUE
    }
    if (_opton(OnigOption.ignoreCase)) str.setSt(NdSt.ignoreCase);
    return str;
  }

  void _appendTokenChar(StrNode str) {
    if (_tok.type == TokenType.crudeByte) {
      str.catByte(_tok.byteVal);
      str.setCrude();
    } else if (_tok.codePoints != null) {
      // Extended `\x{a b c}` — append each code point.
      final buf = Uint8List(enc.maxLength);
      for (final cp in _tok.codePoints!) {
        final n = enc.codeToMbc(cp, buf, 0);
        if (n < 0) throw _err(OnigErr.invalidCodePointValue);
        str.catBytes(buf, 0, n);
      }
    } else {
      final buf = Uint8List(enc.maxLength);
      final n = enc.codeToMbc(_tok.code, buf, 0);
      if (n < 0) throw _err(OnigErr.invalidCodePointValue);
      str.catBytes(buf, 0, n);
    }
  }

  Node _anycharNode({required bool env, bool trueAny = false}) {
    final n = CtypeNode(ctAnychar);
    if (_opton(OnigOption.multiLine) || trueAny) n.setSt(NdSt.multiLine);
    if (trueAny) n.setSt(NdSt.superNd);
    return n;
  }

  /// Handle trailing quantifiers (`repeat:` / `re_entry:` loop), including the
  /// `{1,1}` drop and the `/abc+/` string-split. [prefix] holds the concatenated
  /// part peeled off by string splits; further quantifiers apply to [target]
  /// (the split-off last char) only — e.g. `ax{2}*a` = `a(x{2})*a`.
  Node? _maybeQuantify(Node node, TokenType term) {
    var target = node;
    Node? prefix;
    while (_tok.type == TokenType.repeat || _tok.type == TokenType.interval) {
      if (_isInvalidQuantifierTarget(target)) {
        throw _err(OnigErr.targetOfRepeatOperatorInvalid);
      }
      _incDepth();
      final byNumber = _tok.type == TokenType.interval;
      final q = QuantNode(
        _tok.repeatLower,
        _tok.repeatUpper,
        greedy: _tok.repeatGreedy,
        byNumber: byNumber,
      );
      final possessive = _tok.repeatPossessive;
      _fetchToken();

      // `onig_reduce_nested_quantifier`: two nested FIXED intervals (`x{a}{b}`)
      // merge into `x{a*b}`; the product overflowing int → -201.
      if (!possessive &&
          target is QuantNode &&
          (byNumber || target.isByNumber) &&
          q.lower == q.upper &&
          target.lower == target.upper &&
          q.upper != infiniteRepeat &&
          target.upper != infiniteRepeat) {
        final n = _posIntMultiply(q.lower, target.lower);
        if (n < 0) throw _err(OnigErr.tooBigNumberForRepeatRange);
        target.lower = target.upper = n; // target already holds the body
        _decDepth();
        continue;
      }

      final r = _assignQuantifierBody(q, target);
      Node quant = q;
      if (possessive) {
        final atomic = BagNode(BagType.stopBacktrack)..body = q;
        q.parent = atomic;
        quant = atomic;
      }

      if (r == 0) {
        target = quant;
      } else if (r == 1) {
        // {1,1}: drop the quantifier, keep target unchanged.
        // (possessive over {1,1} is also a no-op)
      } else {
        // r == 2: split case /abc+/. `target` is now the string prefix (last
        // char removed); the quantifier applies to the split-off char only.
        prefix = prefix == null ? target : _seqConcat(prefix, target);
        target = quant;
      }
      _decDepth();
    }
    return prefix == null ? target : _seqConcat(prefix, target);
  }

  /// Concatenate [a] and [b] into a flat list node.
  Node _seqConcat(Node a, Node b) {
    final items = <Node>[];
    _appendSequence(items, a);
    _appendSequence(items, b);
    return nodeNewListFrom(items) ?? a;
  }

  /// `onig_positive_int_multiply`: x*y, or -1 on 32-bit-int overflow.
  int _posIntMultiply(int x, int y) {
    if (x == 0 || y == 0) return 0;
    const intMax = 0x7fffffff;
    if (x < intMax ~/ y) return x * y;
    return -1;
  }

  bool _isInvalidQuantifierTarget(Node n) {
    if (n is AnchorNode) return true;
    if (n is GimmickNode) return true;
    return false;
  }

  /// `assign_quantifier_body`: 0 = attached, 1 = drop `{1,1}`, 2 = string split.
  int _assignQuantifierBody(QuantNode q, Node target) {
    if (q.lower == 1 && q.upper == 1) return 1;
    if (target is StrNode && !target.isCrude) {
      // Split off the last char so the quantifier applies to it only.
      final split = _strSplitLastChar(target);
      if (split != null) {
        q.body = split;
        split.parent = q;
        return 2;
      }
    }
    // NOTE: nested-quantifier reduction (target is QuantNode) is an
    // optimization/warning only and is deferred; correctness is preserved by
    // attaching directly (empty-checks prevent infinite loops).
    q.body = target;
    target.parent = q;
    return 0;
  }

  /// Split the final character off [str], returning a new [StrNode] holding it
  /// (and shrinking [str]); null if [str] has ≤1 char.
  StrNode? _strSplitLastChar(StrNode str) {
    if (str.len <= 1) return null;
    // Find the head byte of the last char.
    final head = enc.leftAdjustCharHead(str.buf, 0, str.len - 1);
    if (head <= 0) return null;
    final last = StrNode();
    last.catBytes(str.buf, head, str.len);
    last.flag = str.flag;
    last.status = str.status;
    str.len = head;
    return last;
  }

  // ======================================================================
  //  Tokenizer  (fetch_token)
  // ======================================================================

  /// `fetch_token` — read the next token into [_tok] (outside a char class).
  void _fetchToken() {
    _skipCommentsAndExtended();
    _tok.backp = p;
    _tok.codePoints = null; // reset extended \x{..} list per token
    if (_pend) {
      _tok.type = TokenType.eot;
      return;
    }

    final c = _fetchChar();
    _tok.escaped = false;

    if (c == _cBackslash && !syn.isOp2(SynOp2.ineffectiveEscape)) {
      _fetchTokenEscape();
      return;
    }

    _tok.byteVal = c;
    _tok.code = c;

    switch (c) {
      case 0x2a: // '*'
        if (syn.isOp(SynOp.asteriskZeroInf)) {
          _setRepeat(0, infiniteRepeat);
          return;
        }
      case 0x2b: // '+'
        if (syn.isOp(SynOp.plusOneInf)) {
          _setRepeat(1, infiniteRepeat);
          return;
        }
      case 0x3f: // '?'
        if (syn.isOp(SynOp.qmarkZeroOne)) {
          _setRepeat(0, 1);
          return;
        }
      case 0x7b: // '{'
        if (syn.isOp(SynOp.braceInterval)) {
          if (_tryInterval()) return;
        }
      case 0x7c: // '|'
        if (syn.isOp(SynOp.vbarAlt)) {
          _tok.type = TokenType.alt;
          return;
        }
      case 0x28: // '('
        if (syn.isOp(SynOp.lparenSubexp)) {
          _tok.type = TokenType.subexpOpen;
          return;
        }
      case 0x29: // ')'
        if (syn.isOp(SynOp.lparenSubexp)) {
          _tok.type = TokenType.subexpClose;
          return;
        }
      case 0x5e: // '^'
        if (syn.isOp(SynOp.lineAnchor) &&
            (!syn.isBehavior(SynBv.breAnchorAtEdgeOfSubexp) ||
                _isHeadOfBreSubexp(_pprev))) {
          _tok.type = TokenType.anchor;
          _tok.anchorSubtype = _opton(OnigOption.singleLine)
              ? Anchor.beginBuf
              : Anchor.beginLine;
          return;
        }
      case 0x24: // '$'
        if (syn.isOp(SynOp.lineAnchor) &&
            (!syn.isBehavior(SynBv.breAnchorAtEdgeOfSubexp) ||
                _isEndOfBreSubexp(p))) {
          _tok.type = TokenType.anchor;
          _tok.anchorSubtype = _opton(OnigOption.singleLine)
              ? Anchor.semiEndBuf
              : Anchor.endLine;
          return;
        }
      case 0x2e: // '.'
        if (syn.isOp(SynOp.dotAnychar)) {
          _tok.type = TokenType.anychar;
          return;
        }
      case 0x5b: // '['
        if (syn.isOp(SynOp.bracketCc)) {
          _tok.type = TokenType.openCc;
          return;
        }
      case 0x5d: // ']'
        // literal ']' outside class
        break;
    }

    _tok.type = TokenType.char;
  }

  /// Skip `(?#...)` comments and, in extended mode, whitespace + `#` comments.
  void _skipCommentsAndExtended() {
    if (!_opton(OnigOption.extend)) return;
    while (!_pend) {
      final b = _peekCode();
      if (b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d || b == 0x0b) {
        _skipCode();
      } else if (b == 0x23) {
        // '#': skip to end of line
        _skipCode();
        while (!_pend) {
          final n = _fetchChar();
          if (n == 0x0a) break;
        }
      } else {
        break;
      }
    }
  }

  void _setRepeat(int lower, int upper) {
    _tok.type = TokenType.repeat;
    _tok.repeatLower = lower;
    _tok.repeatUpper = upper;
    _tok.repeatGreedy = true;
    _tok.repeatPossessive = false;
    _readGreedyPossessiveSuffix();
  }

  /// After a repeat operator, read `?` (lazy) / `+` (possessive) suffix.
  /// A `?` or `+` is only a modifier when the operator isn't already possessive
  /// (regparse.c greedy_check2: guarded by `possessive == 0`). When [allowLazy]
  /// is false (a fixed `{n}` under FIXED_INTERVAL_IS_GREEDY_ONLY), a following
  /// `?` is left for a separate quantifier instead of meaning lazy.
  void _readGreedyPossessiveSuffix({bool allowLazy = true}) {
    if (_pend || _tok.repeatPossessive) return;
    final b = _peekCode();
    if (allowLazy && b == 0x3f && syn.isOp(SynOp.qmarkNonGreedy)) {
      // '?'
      _skipCode();
      _tok.repeatGreedy = false;
    } else if (b == 0x2b) {
      // '+'
      final isInterval = _tok.type == TokenType.interval;
      final ok = isInterval
          ? syn.isOp2(SynOp2.plusPossessiveInterval)
          : syn.isOp2(SynOp2.plusPossessiveRepeat);
      if (ok) {
        _skipCode();
        _tok.repeatPossessive = true;
      }
    }
  }

  /// Try to read a `{n,m}` interval at the current position (after `{`).
  /// Returns true and sets the token if a valid interval was read.
  bool _tryInterval() {
    final save = p;
    var lower = 0;
    var upper = 0;
    var hasLower = false;
    var hasUpper = false;
    var fixedN = false;

    // lower
    while (!_pend && _isDigit(_peekCode())) {
      lower = lower * 10 + (_fetchChar() - 0x30);
      hasLower = true;
      if (lower > 100000) throw _err(OnigErr.tooBigNumberForRepeatRange);
    }
    if (_pend) {
      p = save;
      return false;
    }
    var b = _peekCode();
    if (b == 0x2c) {
      // ','
      _skipCode();
      if (!_pend && _isDigit(_peekCode())) {
        while (!_pend && _isDigit(_peekCode())) {
          upper = upper * 10 + (_fetchChar() - 0x30);
          hasUpper = true;
          if (upper > 100000) throw _err(OnigErr.tooBigNumberForRepeatRange);
        }
      } else {
        upper = infiniteRepeat;
      }
    } else {
      upper = lower; // {n} — exact/fixed form (no comma)
      hasUpper = true;
      fixedN = true;
    }
    if (_pend || _peekCode() != 0x7d) {
      // not a '}' — invalid; treat '{' as a literal
      p = save;
      return false;
    }
    _skipCode(); // consume '}'

    if (!hasLower && !hasUpper) {
      // `{,}` (neither bound) is never a quantifier — treat `{` as literal.
      p = save;
      return false;
    }
    if (!hasLower && upper == infiniteRepeat) {
      // {,} with abbrev allowed → 0..inf ; else invalid
      if (!syn.isBehavior(SynBv.allowIntervalLowAbbrev)) {
        p = save;
        return false;
      }
    }
    if (!hasLower) lower = 0;
    var swappedPossessive = false;
    if (upper != infiniteRepeat && hasUpper && upper < lower) {
      // `{m,n}` with m>n: an error only where `a{n,m}+` possessive intervals
      // exist; otherwise swap the bounds and make it possessive (fetch_interval).
      if (syn.isOp2(SynOp2.plusPossessiveInterval)) {
        throw _err(OnigErr.upperSmallerThanLowerInRepeatRange);
      }
      final t = lower;
      lower = upper;
      upper = t;
      swappedPossessive = true;
    }

    _tok.type = TokenType.interval;
    _tok.repeatLower = lower;
    _tok.repeatUpper = upper;
    _tok.repeatGreedy = true;
    _tok.repeatPossessive = swappedPossessive;
    // FIXED_INTERVAL_IS_GREEDY_ONLY: a fixed `{n}` is greedy-only, so a trailing
    // `?` is a separate optional quantifier — `a{n}?` == `(?:a{n})?`.
    final greedyOnly =
        fixedN && syn.isBehavior(SynBv.fixedIntervalIsGreedyOnly);
    _readGreedyPossessiveSuffix(allowLazy: !greedyOnly);
    return true;
  }

  bool _isDigit(int b) => b >= 0x30 && b <= 0x39;
  bool _isHex(int b) =>
      _isDigit(b) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66);
  int _hexVal(int b) => b <= 0x39 ? b - 0x30 : (b | 0x20) - 0x61 + 10;

  /// Escape-sequence tokenizer (`fetch_token`, escape branch).
  void _fetchTokenEscape() {
    if (_pend) throw _err(OnigErr.endPatternAtEscape);
    _tok.escaped = true;
    final c = _fetchChar();
    _tok.byteVal = c;
    _tok.code = c;

    switch (c) {
      // --- character types ---
      case 0x64: // \d
        return _setCharType(CType.digit, false);
      case 0x44: // \D
        return _setCharType(CType.digit, true);
      case 0x77: // \w
        return _setCharType(CType.word, false);
      case 0x57: // \W
        return _setCharType(CType.word, true);
      case 0x73: // \s
        return _setCharType(CType.space, false);
      case 0x53: // \S
        return _setCharType(CType.space, true);
      case 0x68: // \h  (xdigit) — ONIG_SYN_OP2_ESC_H_XDIGIT
        if (syn.isOp2(SynOp2.escHXdigit)) {
          return _setCharType(CType.xdigit, false);
        }
      case 0x48: // \H
        if (syn.isOp2(SynOp2.escHXdigit)) {
          return _setCharType(CType.xdigit, true);
        }

      // --- anchors ---
      case 0x41: // \A
        if (syn.isOp(SynOp.escAzBufAnchor)) return _setAnchor(Anchor.beginBuf);
      case 0x5a: // \Z
        // Python: \Z means end-of-string (== \z), not semi-end.
        if (syn.isBehavior(SynBv.python)) return _setAnchor(Anchor.endBuf);
        if (syn.isOp(SynOp.escAzBufAnchor)) {
          return _setAnchor(Anchor.semiEndBuf);
        }
      case 0x7a: // \z
        // Python: \z is not a defined operator.
        if (syn.isBehavior(SynBv.python)) throw _err(OnigErr.undefinedOperator);
        if (syn.isOp(SynOp.escAzBufAnchor)) return _setAnchor(Anchor.endBuf);
      case 0x47: // \G
        if (syn.isOp(SynOp.escCapitalGBeginAnchor)) {
          return _setAnchor(Anchor.beginPosition);
        }
      case 0x62: // \b
        if (syn.isOp(SynOp.escBWordBound)) {
          _tok.type = TokenType.anchor;
          _tok.anchorSubtype = Anchor.wordBoundary;
          _tok.anchorAsciiMode = _opton(
            OnigOption.wordIsAscii | OnigOption.posixIsAscii,
          );
          return;
        }
      case 0x42: // \B
        if (syn.isOp(SynOp.escBWordBound)) {
          _tok.type = TokenType.anchor;
          _tok.anchorSubtype = Anchor.noWordBoundary;
          _tok.anchorAsciiMode = _opton(
            OnigOption.wordIsAscii | OnigOption.posixIsAscii,
          );
          return;
        }
      case 0x52: // \R general newline
        if (syn.isOp2(SynOp2.escCapitalRGeneralNewline)) {
          _tok.type = TokenType.generalNewline;
          return;
        }
      case 0x4e: // \N no-newline
        if (syn.isOp2(SynOp2.escCapitalNOSuperDot)) {
          _tok.type = TokenType.noNewline;
          return;
        }
      case 0x4f: // \O true anychar
        if (syn.isOp2(SynOp2.escCapitalNOSuperDot)) {
          _tok.type = TokenType.trueAnychar;
          return;
        }
      case 0x4b: // \K keep
        if (syn.isOp2(SynOp2.escCapitalKKeep)) {
          _tok.type = TokenType.keep;
          return;
        }
      case 0x58: // \X extended grapheme cluster
        if (syn.isOp2(SynOp2.escXYTextSegment)) {
          _tok.type = TokenType.textSegment;
          return;
        }
      case 0x79: // \y text-segment boundary
        if (syn.isOp2(SynOp2.escXYTextSegment)) {
          _tok.type = TokenType.anchor;
          _tok.anchorSubtype = Anchor.textSegmentBoundary;
          return;
        }
      case 0x59: // \Y not text-segment boundary
        if (syn.isOp2(SynOp2.escXYTextSegment)) {
          _tok.type = TokenType.anchor;
          _tok.anchorSubtype = Anchor.noTextSegmentBoundary;
          return;
        }
      case 0x67: // \g<name> subexp call
        if (syn.isOp2(SynOp2.escGSubexpCall)) {
          _fetchCall();
          return;
        }
      case 0x6b: // \k<name> named backref
        if (syn.isOp2(SynOp2.escKNamedBackref)) {
          _fetchNamedBackref();
          return;
        }

      // --- escaped operators (GNU / BRE syntaxes: \( \) \| \{ \* \+ \?) ---
      case 0x28: // \(
        if (syn.isOp(SynOp.escLparenSubexp)) {
          _tok.type = TokenType.subexpOpen;
          return;
        }
      case 0x29: // \)
        if (syn.isOp(SynOp.escLparenSubexp)) {
          _tok.type = TokenType.subexpClose;
          return;
        }
      case 0x7c: // \|
        if (syn.isOp(SynOp.escVbarAlt)) {
          _tok.type = TokenType.alt;
          return;
        }
      case 0x2a: // \*
        if (syn.isOp(SynOp.escAsteriskZeroInf)) {
          _setRepeat(0, infiniteRepeat);
          return;
        }
      case 0x2b: // \+
        if (syn.isOp(SynOp.escPlusOneInf)) {
          _setRepeat(1, infiniteRepeat);
          return;
        }
      case 0x3f: // \?
        if (syn.isOp(SynOp.escQmarkZeroOne)) {
          _setRepeat(0, 1);
          return;
        }
      case 0x7b: // \{
        if (syn.isOp(SynOp.escBraceInterval)) {
          if (_tryInterval()) return;
        }

      // --- escape chars ---
      case 0x6e: // \n
        return _setChar(0x0a);
      case 0x74: // \t
        return _setChar(0x09);
      case 0x72: // \r
        return _setChar(0x0d);
      case 0x66: // \f
        return _setChar(0x0c);
      case 0x61: // \a
        return _setChar(0x07);
      case 0x65: // \e
        return _setChar(0x1b);
      case 0x76: // \v
        if (syn.isOp2(SynOp2.escVVtab)) return _setChar(0x0b);

      case 0x30: // \0.. octal
      case 0x31:
      case 0x32:
      case 0x33:
      case 0x34:
      case 0x35:
      case 0x36:
      case 0x37:
      case 0x38:
      case 0x39:
        return _fetchBackrefOrOctal(c);

      case 0x78: // \xHH or \x{...}
        return _fetchHex();
      case 0x75: // \uHHHH
        if (syn.isOp2(SynOp2.escUHex4)) return _fetchU4();

      case 0x6f: // \o{...} braced octal
        if (syn.isOp(SynOp.escOBraceOctal) && !_pend && _peekCode() == 0x7b) {
          return _fetchOctalBrace();
        }

      case 0x43: // \C-x control
        if (syn.isOp2(SynOp2.escCapitalCBarControl)) {
          if (_pend) throw _err(OnigErr.endPatternAtControl);
          if (_fetchChar() != 0x2d) throw _err(OnigErr.controlCodeSyntax);
          return _setChar(_fetchControlValue());
        }
      case 0x63: // \cx control
        if (syn.isOp(SynOp.escCControl)) {
          return _setChar(_fetchControlValue());
        }
      case 0x4d: // \M-x meta
        if (syn.isOp2(SynOp2.escCapitalMBarMeta)) {
          if (_pend) throw _err(OnigErr.endPatternAtMeta);
          if (_fetchChar() != 0x2d) throw _err(OnigErr.metaCodeSyntax);
          if (_pend) throw _err(OnigErr.endPatternAtMeta);
          var v = _fetchChar();
          if (v == _cBackslash) v = _fetchEscapedValueRaw();
          return _setChar((v & 0xff) | 0x80);
        }

      case 0x70: // \p{...}
      case 0x50: // \P{...}
        if (syn.isOp2(SynOp2.escPBraceCharProperty)) {
          return _fetchCharProperty(c == 0x50);
        }
    }

    // default: escaped literal char
    _tok.type = TokenType.char;
    _tok.code = c;
  }

  /// `\cx` / `\C-x` control value: `x & 0x9f`, or `\c?` → 0x7f, esc recurses.
  int _fetchControlValue() {
    if (_pend) throw _err(OnigErr.endPatternAtControl);
    var c = _fetchChar();
    if (c == 0x3f) return 0x7f; // '?'
    if (c == _cBackslash) c = _fetchEscapedValueRaw();
    return c & 0x9f;
  }

  /// `fetch_escaped_value_raw` — used by `\M-`/`\C-` recursion.
  int _fetchEscapedValueRaw() {
    if (_pend) throw _err(OnigErr.endPatternAtEscape);
    final c = _fetchChar();
    if (c == 0x4d && syn.isOp2(SynOp2.escCapitalMBarMeta)) {
      if (_pend) throw _err(OnigErr.endPatternAtMeta);
      if (_fetchChar() != 0x2d) throw _err(OnigErr.metaCodeSyntax);
      if (_pend) throw _err(OnigErr.endPatternAtMeta);
      var v = _fetchChar();
      if (v == _cBackslash) v = _fetchEscapedValueRaw();
      return (v & 0xff) | 0x80;
    }
    if (c == 0x43 && syn.isOp2(SynOp2.escCapitalCBarControl)) {
      if (_pend) throw _err(OnigErr.endPatternAtControl);
      if (_fetchChar() != 0x2d) throw _err(OnigErr.controlCodeSyntax);
      return _fetchControlValue();
    }
    if (c == 0x63 && syn.isOp(SynOp.escCControl)) return _fetchControlValue();
    return _convBackslashValue(c);
  }

  /// `conv_backslash_value` — `\n \t \r \f \a \e \v \b` → code, else identity.
  int _convBackslashValue(int c) {
    if (!syn.isOp(SynOp.escControlChars)) return c;
    switch (c) {
      case 0x6e:
        return 0x0a; // n
      case 0x74:
        return 0x09; // t
      case 0x72:
        return 0x0d; // r
      case 0x66:
        return 0x0c; // f
      case 0x61:
        return 0x07; // a
      case 0x65:
        return 0x1b; // e
      case 0x76:
        return 0x0b; // v
      case 0x62:
        return 0x08; // b
      default:
        return c;
    }
  }

  /// `\o{ooo ooo ...}` braced octal — one or more code points (cursor at `{`).
  void _fetchOctalBrace() {
    _skipCode(); // '{'
    final cps = _readBracedCodePoints(8);
    if (cps.isEmpty) throw _err(OnigErr.invalidCodePointValue);
    _tok.type = TokenType.codePoint;
    _tok.code = cps.first;
    _tok.codePoints = cps.length > 1 ? cps : null;
  }

  /// Digit value of [c] in [base] (8 or 16), or -1 if not a digit of that base.
  int _digitOfBase(int c, int base) {
    if (base == 16) return _isHex(c) ? _hexVal(c) : -1;
    return (c >= 0x30 && c <= 0x37) ? c - 0x30 : -1; // octal
  }

  /// `scan_number_of_base` — read up to [maxDigits] digits of [base] (≥ 1).
  /// A further digit after the max signals `TOO_LONG_WIDE_CHAR_VALUE`.
  int _scanBaseDigits(int base, int maxDigits) {
    var val = 0;
    var n = 0;
    while (!_pend && n < maxDigits) {
      final d = _digitOfBase(_peekCode(), base);
      if (d < 0) break;
      val = val * base + d;
      _skipCode();
      n++;
    }
    if (n == 0) throw _err(OnigErr.invalidCodePointValue);
    if (!_pend && _digitOfBase(_peekCode(), base) >= 0) {
      throw _err(OnigErr.tooLongWideCharValue);
    }
    return val;
  }

  /// `check_code_point_sequence` — read `{ v (SP|NL v)* }` in [base]; cursor is
  /// just past `{`. Dividers are space (0x20) and newline (0x0a).
  List<int> _readBracedCodePoints(int base) {
    final cps = <int>[];
    while (true) {
      if (_pend) throw _err(OnigErr.invalidCodePointValue);
      final c = _peekCode();
      if (c == 0x7d) {
        _skipCode(); // '}'
        return cps;
      }
      if (c == 0x20 || c == 0x0a) {
        _skipCode();
        continue;
      }
      final v = _scanBaseDigits(base, base == 16 ? 8 : 11);
      if (enc.codeToMbcLen(v) < 0) throw _err(OnigErr.invalidCodePointValue);
      cps.add(v);
    }
  }

  void _setCharType(int ctype, bool not) {
    _tok.type = TokenType.charType;
    _tok.propCtype = ctype;
    _tok.propNot = not;
  }

  void _setAnchor(int subtype) {
    _tok.type = TokenType.anchor;
    _tok.anchorSubtype = subtype;
    _tok.anchorAsciiMode = false;
  }

  void _setChar(int code) {
    _tok.type = TokenType.char;
    _tok.code = code;
    _tok.byteVal = code;
  }

  /// `\NNN` octal or `\N` decimal backref.
  void _fetchBackrefOrOctal(int first) {
    if (first == 0x30) {
      // \0 always octal escape
      return _fetchOctal(first);
    }
    if (syn.isOp(SynOp.decimalBackref)) {
      // Read a decimal number; if it references an existing/plausible group,
      // it's a backref.
      var num = first - 0x30;
      final save = p;
      while (!_pend && _isDigit(_peekCode())) {
        num = num * 10 + (_fetchChar() - 0x30);
        if (num > 1000000) break;
      }
      // Ruby/Oniguruma: \1..\9 are backrefs; multi-digit if <= numMem.
      if (num <= 9 || num <= numMem) {
        _tok.type = TokenType.backref;
        _tok.backrefRef1 = num;
        _tok.backrefRefs = null;
        _tok.backrefByName = false;
        _tok.backrefLevel = 0;
        _tok.backrefExistLevel = false;
        return;
      }
      p = save;
    }
    // fall back to octal
    _fetchOctal(first);
  }

  void _fetchOctal(int first) {
    var val = first - 0x30;
    var count = 1;
    while (count < 3 && !_pend) {
      final b = _peekCode();
      if (b < 0x30 || b > 0x37) break;
      val = (val << 3) | (b - 0x30);
      _skipCode();
      count++;
    }
    _tok.type = TokenType.crudeByte;
    _tok.byteVal = val & 0xff;
  }

  void _fetchHex() {
    if (_peekCode() == 0x7b && syn.isOp(SynOp.escXBraceHex8)) {
      // \x{ h... [ (SP|NL) h... ]* } — one or more code points.
      _skipCode();
      final cps = _readBracedCodePoints(16);
      if (cps.isEmpty) throw _err(OnigErr.invalidCodePointValue);
      _tok.type = TokenType.codePoint;
      _tok.code = cps.first;
      _tok.codePoints = cps.length > 1 ? cps : null;
      return;
    }
    if (syn.isOp(SynOp.escXHex2)) {
      var val = 0;
      var digits = 0;
      while (digits < 2 && _isHex(_peekCode())) {
        val = (val << 4) | _hexVal(_fetchChar());
        digits++;
      }
      _tok.type = TokenType.crudeByte;
      _tok.byteVal = val & 0xff;
      return;
    }
    _setChar(0x78); // literal 'x'
  }

  void _fetchU4() {
    var val = 0;
    var digits = 0;
    while (digits < 4 && _isHex(_peekCode())) {
      val = (val << 4) | _hexVal(_fetchChar());
      digits++;
    }
    // `\uHHHH` requires exactly 4 hex digits (scan_hexadecimal_number minlen).
    if (digits < 4) throw _err(OnigErr.invalidCodePointValue);
    _tok.type = TokenType.codePoint;
    _tok.code = val;
  }

  /// Read a `<name>` / `'name'` / `<n>` / `<name+L>` delimited reference.
  /// Returns (name-or-number-string, level) and consumes through the close.
  /// Decode pattern bytes `[start, endPos)` into a String of **code points**
  /// (not raw bytes) — used for group names, `\g`/`\k` targets, `(?(name))`
  /// checkers, and `\p{}` property names so ASCII names/numbers parse correctly
  /// under multi-byte encodings (regparse.c reads names through the encoding).
  /// Single-byte encodings keep the exact byte-wise form; definitions and every
  /// reference use this same decoding, so name-table keys stay consistent.
  String _decodeName(int start, int endPos) {
    if (enc.isSingleByte) return String.fromCharCodes(s.sublist(start, endPos));
    final sb = StringBuffer();
    var q = start;
    while (q < endPos) {
      sb.writeCharCode(enc.mbcToCode(s, q, endPos));
      q += enc.length(s, q, endPos);
    }
    return sb.toString();
  }

  (String, int) _readNameRef() {
    if (_pend) throw _err(OnigErr.invalidBackref);
    final open = _peekCode();
    final int close;
    if (open == 0x3c) {
      close = 0x3e; // < >
    } else if (open == 0x27) {
      close = 0x27; // ' '
    } else {
      throw _err(OnigErr.invalidBackref);
    }
    _skipCode();
    final start = p;
    while (!_pend && _peekCode() != close) {
      _skipCode();
    }
    if (_pend) throw _err(OnigErr.endPatternInGroup);
    var body = _decodeName(start, p);
    _skipCode(); // close
    var level = 0;
    var hasLevel = false;
    // optional +N / -N nesting level — only when a name/number precedes it, so
    // a bare `\g<-1>` / `\g<+2>` stays a (relative) reference, not a level.
    final m = RegExp(r'^(.+?)([+-]\d+)$').firstMatch(body);
    if (m != null) {
      level = int.parse(m.group(2)!);
      body = m.group(1)!;
      hasLevel = true;
    }
    _tok.backrefExistLevel = hasLevel;
    return (body, level);
  }

  /// `\k<name>` / `\k'name'` / `\k<n>` named/numbered back-reference.
  void _fetchNamedBackref() {
    final (name, level) = _readNameRef();
    _tok.type = TokenType.backref;
    _tok.backrefLevel = level;
    final asNum = int.tryParse(name);
    if (asNum != null) {
      _tok.backrefRefs = [asNum];
      _tok.backrefRef1 = asNum;
      _tok.backrefByName = false;
    } else {
      final nums = nameTable[name];
      if (nums == null) throw _err(OnigErr.undefinedNameReference, name);
      _tok.backrefRefs = List<int>.of(nums);
      _tok.backrefRef1 = nums.first;
      _tok.backrefByName = true;
    }
  }

  /// `\g<name>` / `\g<n>` / `\g<0>` subexpression call.
  void _fetchCall() {
    final (name, _) = _readNameRef();
    _tok.type = TokenType.call;
    // Relative `\g<-N>` / `\g<+N>` → absolute using the group count so far.
    // `\g<0>` calls the whole pattern (recursion).
    if (name.isNotEmpty && (name[0] == '-' || name[0] == '+')) {
      final rel = int.tryParse(name.substring(1));
      if (rel == null) throw _err(OnigErr.invalidBackref);
      _tok.callGnum = name[0] == '-' ? numMem - rel + 1 : numMem + rel;
      _tok.callByNumber = true;
      return;
    }
    final asNum = int.tryParse(name);
    if (asNum != null) {
      _tok.callGnum = asNum; // includes 0 (whole-pattern recursion)
      _tok.callByNumber = true;
      if (asNum == 0) _hasCallZero = true;
    } else {
      _tok.callGnum = null;
      _tok.callByNumber = false;
      _tok.propName = name; // reuse propName to carry the call target name
    }
  }

  /// `\p{name}` / `\P{name}` / `\p{^name}`.
  void _fetchCharProperty(bool escNegate) {
    if (_pend || _peekCode() != 0x7b) {
      // ESC_P_WITH_ONE_CHAR_PROP: `\pL` single-letter form.
      if (!_pend && syn.isBehavior(SynBv.escPWithOneCharProp)) {
        final ch = _fetchChar();
        _tok.type = TokenType.charProperty;
        _tok.propName = String.fromCharCode(ch);
        _tok.propNot = escNegate;
        return;
      }
      throw _err(OnigErr.invalidCharPropertyName);
    }
    _skipCode(); // '{'
    var not = escNegate;
    if (!_pend && _peekCode() == 0x5e) {
      // '^'
      _skipCode();
      not = !not;
    }
    final start = p;
    while (!_pend && _peekCode() != 0x7d) {
      _skipCode();
    }
    if (_pend) throw _err(OnigErr.invalidCharPropertyName);
    final name = _decodeName(start, p);
    _skipCode(); // '}'
    if (name.isEmpty) throw _err(OnigErr.invalidCharPropertyName);
    _tok.type = TokenType.charProperty;
    _tok.propName = name;
    _tok.propNot = not;
  }

  // ======================================================================
  //  Groups  (prs_bag)  — subset: (), (?:), (?<name>), (?'name'), (?imsx[:])
  // ======================================================================

  /// Returns the group node, or null for an option-only `(?flags)` group
  /// (whose effect is applied to [options] in place).
  Node? _prsBag() {
    // _tok is '('. Look at what follows.
    _groupOpenPos = _pprev; // byte offset of this group's '(' (for whole-opts)
    // (*name...) name callout.
    if (!_pend &&
        _peekCode() == 0x2a &&
        syn.isOp2(SynOp2.asteriskCalloutName)) {
      _skipCode(); // consume '*'
      return _parseNameCallout();
    }
    if (!_pend && _peekCode() == 0x3f && syn.isOp2(SynOp2.qmarkGroupEffect)) {
      _skipCode(); // consume '?'
      if (_pend) throw _err(OnigErr.endPatternInGroup);
      final c = _peekCode();
      switch (c) {
        case 0x3a: // (?:
          _skipCode();
          return _parseGroupBody(capture: false);
        case 0x3d: // (?=
          _skipCode();
          return _parseLookaround(Anchor.precRead);
        case 0x21: // (?!
          _skipCode();
          return _parseLookaround(Anchor.precReadNot);
        case 0x3e: // (?>
          _skipCode();
          return _parseAtomicGroup();
        case 0x3c: // (?< ...
          _skipCode();
          if (!_pend && (_peekCode() == 0x3d || _peekCode() == 0x21)) {
            final neg = _fetchChar() == 0x21;
            return _parseLookaround(
              neg ? Anchor.lookBehindNot : Anchor.lookBehind,
            );
          }
          // (?<name>
          return _parseNamedGroup(0x3e);
        case 0x27: // (?'name'
          if (syn.isOp2(SynOp2.qmarkLtNamedGroup)) {
            _skipCode();
            return _parseNamedGroup(0x27);
          }
          throw _err(OnigErr.undefinedGroupOption);
        case 0x23: // (?# comment
          _skipCode();
          _skipComment();
          // comment produces no node; re-fetch handled by caller via empty
          return _emptyNode();
        case 0x28: // (?( conditional
          if (syn.isOp2(SynOp2.qmarkLparenIfElse)) {
            _skipCode();
            return _parseConditional();
          }
          throw _err(OnigErr.undefinedGroupOption);
        case 0x7b: // (?{ contents callout
          if (syn.isOp2(SynOp2.qmarkBraceCalloutContents)) {
            return _parseContentsCallout();
          }
          throw _err(OnigErr.undefinedGroupOption);
        case 0x7e: // (?~ absent group / expression
          if (syn.isOp2(SynOp2.qmarkTildeAbsentGroup)) {
            _skipCode();
            return _parseAbsent();
          }
          throw _err(OnigErr.undefinedGroupOption);
        default:
          return _parseOptionGroup();
      }
    }
    // plain capturing group
    if (_opton(OnigOption.dontCaptureGroup)) {
      return _parseGroupBody(capture: false);
    }
    return _parseGroupBody(capture: true);
  }

  void _skipComment() {
    while (!_pend) {
      final c = _fetchChar();
      if (c == 0x29) return; // ')'
      if (c == _cBackslash && !_pend) _fetchChar();
    }
    throw _err(OnigErr.endPatternInGroup);
  }

  Node _parseGroupBody({required bool capture}) {
    BagNode bag;
    if (capture) {
      final regnum = ++numMem;
      bag = BagNode(BagType.memory)..regNum = regnum;
      if (memNodes.length <= regnum) {
        memNodes.length = regnum + 1;
      }
      memNodes[regnum] = bag;
    } else {
      bag = BagNode(BagType.option)..options = options; // non-capturing group
    }
    _fetchToken();
    final body = _prsAlts(TokenType.subexpClose);
    if (_tok.type != TokenType.subexpClose) {
      throw _err(OnigErr.endPatternWithUnmatchedParenthesis);
    }
    bag.body = body;
    body?.parent = bag;
    // For a non-capturing group we use BAG_OPTION with unchanged options so
    // the body is simply grouped.
    return bag;
  }

  /// `(*NAME[tag]{arg,arg})` name callout. Positioned after the `*`.
  Node _parseNameCallout() {
    final nameStart = p;
    while (!_pend) {
      final c = _peekCode();
      if (c == 0x5b || c == 0x7b || c == 0x29) break; // [ { )
      _skipCode();
    }
    final name = String.fromCharCodes(s.sublist(nameStart, p));
    String? tag;
    if (!_pend && _peekCode() == 0x5b) {
      // [tag]
      _skipCode();
      final ts = p;
      while (!_pend && _peekCode() != 0x5d) {
        _skipCode();
      }
      tag = String.fromCharCodes(s.sublist(ts, p));
      if (!_pend) _skipCode(); // ]
    }
    var args = const <String>[];
    if (!_pend && _peekCode() == 0x7b) {
      // {arg,arg,...}
      _skipCode();
      final as = p;
      while (!_pend && _peekCode() != 0x7d) {
        _skipCode();
      }
      final argStr = String.fromCharCodes(s.sublist(as, p));
      if (!_pend) _skipCode(); // }
      args = argStr.isEmpty ? const [] : argStr.split(',');
    }
    if (_pend || _peekCode() != 0x29) throw _err(OnigErr.invalidCalloutPattern);
    _skipCode(); // final ')'
    if (name.isEmpty) throw _err(OnigErr.invalidCalloutName);
    return GimmickNode(GimmickType.callout)
      ..calloutIsName = true
      ..calloutName = name
      ..calloutTag = tag
      ..calloutArgs = args
      ..id = numCallout++;
  }

  /// `(?{contents}[tag])` contents callout. Positioned at the `{`.
  Node _parseContentsCallout() {
    // Support `{...}` and `{{...}}` (doubled braces let the body contain `}`).
    var braces = 0;
    while (!_pend && _peekCode() == 0x7b) {
      _skipCode();
      braces++;
    }
    final cs = p;
    var end2 = -1;
    while (!_pend) {
      if (_peekCode() == 0x7d) {
        // count run of '}'
        var run = 0;
        final save = p;
        while (!_pend && _peekCode() == 0x7d) {
          _skipCode();
          run++;
        }
        if (run >= braces) {
          end2 = save;
          break;
        }
      } else {
        _skipCode();
      }
    }
    if (end2 < 0) throw _err(OnigErr.invalidCalloutPattern);
    final contents = String.fromCharCodes(s.sublist(cs, end2));
    String? tag;
    if (!_pend && _peekCode() == 0x5b) {
      _skipCode();
      final ts = p;
      while (!_pend && _peekCode() != 0x5d) {
        _skipCode();
      }
      tag = String.fromCharCodes(s.sublist(ts, p));
      if (!_pend) _skipCode();
    }
    if (_pend || _peekCode() != 0x29) throw _err(OnigErr.invalidCalloutPattern);
    _skipCode(); // ')'
    return GimmickNode(GimmickType.callout)
      ..calloutIsName = false
      ..calloutContents = contents
      ..calloutTag = tag
      ..id = numCallout++;
  }

  /// `(?(N)then|else)` / `(?(<name>)then|else)` conditional. Positioned after
  /// the opening `(?(`. Assertion conditions `(?(?=..)..)` are deferred.
  Node _parseConditional() {
    if (_pend) throw _err(OnigErr.invalidIfElseSyntax);
    final c = _peekCode();
    Node cond;
    // A backref-checker condition begins with a digit, +/- (relative), or an
    // enclosed name (`<name>`/`'name'`). Anything else is a sub-pattern
    // condition (evaluated like a look-ahead). (regparse.c `prs_bag` `(?(`.)
    if (c == 0x2a && syn.isOp2(SynOp2.asteriskCalloutName)) {
      // (?(*NAME){args})THEN|ELSE) — name-callout condition.
      _skipCode(); // consume '*'
      cond = _parseNameCallout(); // reads until and consumes the ')'
      _fetchToken();
    } else if (c == 0x3f &&
        _peekCode2() == 0x7b &&
        syn.isOp2(SynOp2.qmarkBraceCalloutContents)) {
      // (?(?{...})THEN|ELSE) — contents (code) callout condition.
      _skipCode(); // consume '?'
      cond = _parseContentsCallout(); // at '{', consumes the ')'
      _fetchToken();
    } else if (_isDigit(c) ||
        c == 0x2d ||
        c == 0x2b ||
        c == 0x3c ||
        c == 0x27) {
      cond = _parseCheckerCondition(c);
      if (_pend || _peekCode() != 0x29) throw _err(OnigErr.invalidIfElseSyntax);
      _skipCode(); // ')' closing the condition
      _fetchToken();
    } else {
      _fetchToken();
      cond = _prsAlts(TokenType.subexpClose) ?? _emptyNode();
      if (_tok.type != TokenType.subexpClose) {
        throw _err(OnigErr.invalidIfElseSyntax);
      }
      _fetchToken(); // past the condition's ')'
    }

    // Empty body — `(?(cond))` with nothing after the condition: the whole
    // conditional IS just the checker (regparse.c "empty body: make backref
    // checker"). It asserts the group matched and FAILS when it didn't — unlike
    // `(?(cond)then)` whose implicit empty else matches. The condition must be a
    // checker (backref/name); a sub-pattern/callout body here is a syntax error.
    if (_tok.type == TokenType.subexpClose) {
      if (!cond.st(NdSt.checker)) throw _err(OnigErr.invalidIfElseSyntax);
      return cond;
    }

    // `then|else` parsed as one alternation (regparse.c uses prs_alts, then
    // splits): the first branch is THEN; any remaining branches form ELSE
    // (kept as an alternation if more than one).
    final target = _prsAlts(TokenType.subexpClose) ?? _emptyNode();
    if (_tok.type != TokenType.subexpClose) {
      throw _err(OnigErr.endPatternWithUnmatchedParenthesis);
    }
    Node yes;
    Node? no;
    if (target is AltNode) {
      yes = target.car;
      final rest = target.cdr;
      if (rest is AltNode && rest.cdr == null) {
        no = rest.car;
      } else {
        no = rest;
      }
    } else {
      yes = target;
      no = null;
    }
    return BagNode(BagType.ifElse)
      ..body = cond
      ..then_ = yes
      ..else_ = no;
  }

  /// Parse a numeric/relative/name backref-checker condition (byte level).
  Node _parseCheckerCondition(int c) {
    if (c == 0x3c || c == 0x27) {
      final close = c == 0x3c ? 0x3e : 0x27;
      _skipCode();
      final start = p;
      while (!_pend && _peekCode() != close) {
        _skipCode();
      }
      if (_pend) throw _err(OnigErr.endPatternInGroup);
      final name = _decodeName(start, p);
      _skipCode();
      // `(?(<N>)…)` / `(?('N')…)`: an all-digit body is a group *number*.
      final asNum = int.tryParse(name);
      if (asNum != null) {
        if (asNum <= 0) throw _err(OnigErr.invalidBackref);
        return BackRefNode([asNum])..setSt(NdSt.checker);
      }
      final nums = nameTable[name];
      if (nums == null) throw _err(OnigErr.undefinedNameReference, name);
      return BackRefNode(List<int>.from(nums))..setSt(NdSt.checker);
    }
    var rel = 0; // 0 = absolute, -1 = backward, 1 = forward
    if (c == 0x2d) {
      rel = -1;
      _skipCode();
    } else if (c == 0x2b) {
      rel = 1;
      _skipCode();
    }
    var n = 0;
    var any = false;
    while (!_pend && _isDigit(_peekCode())) {
      n = n * 10 + (_fetchChar() - 0x30);
      any = true;
    }
    if (!any) throw _err(OnigErr.invalidIfElseSyntax);
    // optional +level / -level suffix (backref-with-level) — consume, ignore.
    if (!_pend && (_peekCode() == 0x2b || _peekCode() == 0x2d)) {
      _skipCode();
      while (!_pend && _isDigit(_peekCode())) {
        _skipCode();
      }
    }
    final refNum = rel == 0 ? n : (rel < 0 ? numMem + 1 - n : numMem + n);
    if (refNum <= 0) throw _err(OnigErr.invalidBackref);
    return BackRefNode([refNum])..setSt(NdSt.checker);
  }

  Node _parseNamedGroup(int closeChar) {
    final nameStart = p;
    while (!_pend && _peekCode() != closeChar) {
      _skipCode();
    }
    if (_pend) throw _err(OnigErr.endPatternInGroup);
    final name = _decodeName(nameStart, p);
    _skipCode(); // consume close char
    if (name.isEmpty) throw _err(OnigErr.emptyGroupName);

    final regnum = ++numMem;
    numNamed++;
    final bag = BagNode(BagType.memory)
      ..regNum = regnum
      ..setSt(NdSt.namedGroup);
    if (memNodes.length <= regnum) memNodes.length = regnum + 1;
    memNodes[regnum] = bag;
    (nameTable[name] ??= <int>[]).add(regnum);

    _fetchToken();
    final body = _prsAlts(TokenType.subexpClose);
    if (_tok.type != TokenType.subexpClose) {
      throw _err(OnigErr.endPatternWithUnmatchedParenthesis);
    }
    bag.body = body;
    body?.parent = bag;
    return bag;
  }

  Node _parseAtomicGroup() {
    final bag = BagNode(BagType.stopBacktrack);
    _fetchToken();
    final body = _prsAlts(TokenType.subexpClose);
    if (_tok.type != TokenType.subexpClose) {
      throw _err(OnigErr.endPatternWithUnmatchedParenthesis);
    }
    bag.body = body;
    body?.parent = bag;
    return bag;
  }

  Node _parseLookaround(int anchorType) {
    final anc = AnchorNode(anchorType);
    _fetchToken();
    final body = _prsAlts(TokenType.subexpClose);
    if (_tok.type != TokenType.subexpClose) {
      throw _err(OnigErr.endPatternWithUnmatchedParenthesis);
    }
    anc.body = body;
    body?.parent = anc;
    return anc;
  }

  /// `(?imsxWDSPyaILC-...:...)` or `(?...)` option group (regparse.c
  /// `prs_bag`). Supports the Oniguruma ASCII-mode options (W/D/S/P), the
  /// text-segment options `(?y{g})`/`(?y{w})`, and the whole-pattern options
  /// (I/L/C) in addition to the classic `imsx`.
  Node? _parseOptionGroup() {
    var neg = false;
    var opt = options;
    var wholeUsed = false;
    final onig = syn.isOp2(SynOp2.optionOniguruma);
    final whole = syn.isBehavior(SynBv.wholeOptions);
    while (!_pend) {
      final c = _fetchChar();
      switch (c) {
        case 0x2d: // '-'
          neg = true;
        case 0x69: // i
          opt = _optNegate(opt, OnigOption.ignoreCase, neg);
        case 0x78: // x
          opt = _optNegate(opt, OnigOption.extend, neg);
        case 0x6d: // m  (Ruby/Oniguruma: multiline == dotall)
          if (syn.isOp2(SynOp2.optionPerl)) {
            opt = _optNegate(opt, OnigOption.singleLine, !neg);
          } else if (onig || syn.isOp2(SynOp2.optionRuby)) {
            opt = _optNegate(opt, OnigOption.multiLine, neg);
          } else {
            throw _err(OnigErr.undefinedGroupOption);
          }
        case 0x73: // s (Perl only) — dot-all
          if (syn.isOp2(SynOp2.optionPerl)) {
            opt = _optNegate(opt, OnigOption.multiLine, neg);
          } else {
            throw _err(OnigErr.undefinedGroupOption);
          }
        case 0x57: // W — word is ASCII
          if (!onig) throw _err(OnigErr.undefinedGroupOption);
          opt = _optNegate(opt, OnigOption.wordIsAscii, neg);
        case 0x44: // D — digit is ASCII
          if (!onig) throw _err(OnigErr.undefinedGroupOption);
          opt = _optNegate(opt, OnigOption.digitIsAscii, neg);
        case 0x53: // S — space is ASCII
          if (!onig) throw _err(OnigErr.undefinedGroupOption);
          opt = _optNegate(opt, OnigOption.spaceIsAscii, neg);
        case 0x50: // P — POSIX is ASCII
          if (!onig) throw _err(OnigErr.undefinedGroupOption);
          opt = _optNegate(opt, OnigOption.posixIsAscii, neg);
        case 0x79: // y{g} / y{w} — text-segment mode
          if (!onig || neg) throw _err(OnigErr.undefinedGroupOption);
          opt = _parseTextSegmentOption(opt);
        case 0x61: // a — Python: POSIX is ASCII
          if (!syn.isBehavior(SynBv.python)) {
            throw _err(OnigErr.undefinedGroupOption);
          }
          opt = _optNegate(opt, OnigOption.posixIsAscii, neg);
        case 0x43: // C — whole: don't capture group
          if (!whole || neg) throw _err(OnigErr.invalidGroupOption);
          opt = _optNegate(opt, OnigOption.dontCaptureGroup, neg);
          wholeUsed = true;
        case 0x49: // I — whole: ignorecase is ASCII
          if (!whole || neg) throw _err(OnigErr.invalidGroupOption);
          opt = _optNegate(opt, OnigOption.ignoreCaseIsAscii, neg);
          wholeUsed = true;
        case 0x4c: // L — whole: find longest
          if (!whole || neg) throw _err(OnigErr.invalidGroupOption);
          opt = _optNegate(opt, OnigOption.findLongest, neg);
          wholeUsed = true;
        case 0x3a: // ':' — scoped option group body
          if (wholeUsed) _setWholeOptions(opt);
          return _parseScopedOptionBody(opt, wholeOptions: wholeUsed);
        case 0x29: // ')' — set options for rest of branch
          if (wholeUsed) _setWholeOptions(opt);
          options = opt;
          return null;
        default:
          throw _err(OnigErr.undefinedGroupOption);
      }
    }
    throw _err(OnigErr.endPatternInGroup);
  }

  /// `(?y{g})` / `(?y{w})` text-segment options (already consumed the `y`).
  int _parseTextSegmentOption(int opt) {
    if (_pend) throw _err(OnigErr.endPatternInGroup);
    if (_fetchChar() != 0x7b) throw _err(OnigErr.undefinedGroupOption); // '{'
    if (_pend) throw _err(OnigErr.endPatternInGroup);
    final kind = _fetchChar();
    if (kind == 0x67) {
      // g: extended grapheme cluster
      opt = _optNegate(
        opt,
        OnigOption.textSegmentExtendedGraphemeCluster,
        false,
      );
      opt = _optNegate(opt, OnigOption.textSegmentWord, true);
    } else if (kind == 0x77) {
      // w: word
      opt = _optNegate(opt, OnigOption.textSegmentWord, false);
      opt = _optNegate(
        opt,
        OnigOption.textSegmentExtendedGraphemeCluster,
        true,
      );
    } else {
      throw _err(OnigErr.undefinedGroupOption);
    }
    if (_pend) throw _err(OnigErr.endPatternInGroup);
    if (_fetchChar() != 0x7d) throw _err(OnigErr.undefinedGroupOption); // '}'
    return opt;
  }

  Node _parseScopedOptionBody(int opt, {bool wholeOptions = false}) {
    final saved = options;
    options = opt;
    final bag = BagNode(BagType.option)..options = opt;
    if (wholeOptions) bag.setSt(NdSt.wholeOptions);
    _fetchToken();
    final body = _prsAlts(TokenType.subexpClose);
    if (_tok.type != TokenType.subexpClose) {
      throw _err(OnigErr.endPatternWithUnmatchedParenthesis);
    }
    bag.body = body;
    body?.parent = bag;
    options = saved;
    return bag;
  }

  /// `set_whole_options`: a `(?I/L/C)` whole-pattern option applies to the
  /// entire regex. Only one is allowed; propagate its bits to [_wholeOptions]
  /// (folded into `reg.options` after parsing).
  void _setWholeOptions(int opt) {
    if (_hasWholeOptions) throw _err(OnigErr.invalidGroupOption);
    // Position check (`check_whole_options_position`): the option group must be
    // at the pattern head — everything before its '(' can only be `(?:` opens.
    var q = 0;
    while (q < _groupOpenPos) {
      if (q + 3 <= _groupOpenPos &&
          s[q] == 0x28 &&
          s[q + 1] == 0x3f &&
          s[q + 2] == 0x3a) {
        q += 3;
      } else {
        throw _err(OnigErr.invalidGroupOption);
      }
    }
    _hasWholeOptions = true;
    if (_opton2(opt, OnigOption.dontCaptureGroup)) {
      _wholeOptions |= OnigOption.dontCaptureGroup;
    }
    if (_opton2(opt, OnigOption.ignoreCaseIsAscii)) {
      _wholeOptions |= OnigOption.ignoreCaseIsAscii;
    }
    if (_opton2(opt, OnigOption.findLongest)) {
      _wholeOptions |= OnigOption.findLongest;
    }
  }

  bool _opton2(int opt, int flag) => (opt & flag) != 0;

  int _optNegate(int opt, int flag, bool neg) =>
      neg ? (opt & ~flag) : (opt | flag);

  // ======================================================================
  //  Absent operator  `(?~...)`  (regparse.c make_absent_*)
  // ======================================================================

  int _numSaveVal = 0;

  GimmickNode _saveGimmick(int saveType) => GimmickNode(GimmickType.save)
    ..detailType = saveType
    ..id = _numSaveVal++;

  GimmickNode _updateVarGimmick(int updateType, int id) =>
      GimmickNode(GimmickType.updateVar)
        ..detailType = updateType
        ..id = id;

  Node _trueAnychar() => CtypeNode(ctAnychar)
    ..setSt(NdSt.multiLine)
    ..setSt(NdSt.superNd);

  Node _list(List<Node> ns) => nodeNewListFrom(ns) ?? _emptyNode();

  Node _alt2(Node a, Node b) => AltNode(a, AltNode(b));

  /// Dispatch `(?~...)` after the `~` is consumed (regparse.c `prs_bag`).
  Node? _parseAbsent() {
    if (_pend) throw _err(OnigErr.endPatternInGroup);
    var headBar = false;
    if (_peekCode() == 0x7c) {
      // '|'
      _skipCode();
      if (_pend) throw _err(OnigErr.endPatternInGroup);
      headBar = true;
      if (_peekCode() == 0x29) {
        // (?~|)  range clear
        _skipCode();
        return _makeRangeClear();
      }
    }
    _fetchToken();
    var absent = _prsAlts(TokenType.subexpClose) ?? _emptyNode();
    if (_tok.type != TokenType.subexpClose) {
      throw _err(OnigErr.endPatternWithUnmatchedParenthesis);
    }
    Node? expr;
    var isRangeCutter = false;
    if (headBar) {
      if (absent is! AltNode || absent.cdr == null) {
        expr = null;
        isRangeCutter = true;
      } else {
        final top = absent;
        absent = top.car;
        final rest = top.cdr!;
        if (rest is AltNode && rest.cdr == null) {
          expr = rest.car;
        } else {
          expr = rest;
        }
      }
    }
    return _makeAbsentTree(absent, expr, isRangeCutter);
  }

  /// `make_absent_engine`.
  Node _makeAbsentEngine(
    int preSaveRightId,
    Node absent,
    Node stepOne,
    int lower,
    int upper,
    bool possessive,
    bool isRangeCutter, {
    bool greedy = true,
  }) {
    final save = _saveGimmick(SaveType.s);
    final id = save.id;
    final upd = _updateVarGimmick(UpdateVarType.rightRangeFromSStack, id);
    if (isRangeCutter) upd.setSt(NdSt.absentWithSideEffects);
    var inner = _list([save, absent, upd, GimmickNode(GimmickType.fail)]);
    var x = _alt2(inner, stepOne);
    final quant = QuantNode(lower, upper, greedy: greedy);
    quant.body = x;
    x.parent = quant;
    Node body = quant;
    if (possessive) {
      final atomic = BagNode(BagType.stopBacktrack)..body = body;
      body.parent = atomic;
      body = atomic;
    }
    final upd2 = _updateVarGimmick(
      UpdateVarType.rightRangeFromStack,
      preSaveRightId,
    );
    final tail = _list([upd2, GimmickNode(GimmickType.fail)]);
    final result = _alt2(body, tail);
    if (isRangeCutter) result.setSt(NdSt.superNd);
    return result;
  }

  /// `make_absent_tail`: returns (saveNode, altNode).
  (Node, Node) _makeAbsentTail(int preSaveRightId) {
    final save = _saveGimmick(SaveType.rightRange);
    final id = save.id;
    final inner = _list([
      _updateVarGimmick(UpdateVarType.rightRangeFromStack, id),
      GimmickNode(GimmickType.fail),
    ]);
    final alt = _alt2(
      _updateVarGimmick(UpdateVarType.rightRangeFromStack, preSaveRightId),
      inner,
    );
    return (save, alt);
  }

  /// `make_range_clear` — `(?~|)`.
  Node _makeRangeClear() {
    final save = _saveGimmick(SaveType.rightRange);
    final id = save.id;
    final inner = _list([
      _updateVarGimmick(UpdateVarType.rightRangeFromStack, id),
      GimmickNode(GimmickType.fail),
    ]);
    final init = _updateVarGimmick(UpdateVarType.rightRangeInit, 0)
      ..setSt(NdSt.absentWithSideEffects);
    final alt = _alt2(init, inner)..setSt(NdSt.superNd);
    return _list([save, alt]);
  }

  /// `make_absent_tree_for_simple_one_char_repeat`.
  Node _makeAbsentSimple(
    Node absent,
    Node body,
    int lower,
    int upper,
    bool possessive,
    bool greedy,
  ) {
    final save = _saveGimmick(SaveType.rightRange);
    final id = save.id;
    final engine = _makeAbsentEngine(
      id,
      absent,
      body,
      lower,
      upper,
      possessive,
      false,
      greedy: greedy,
    );
    final upd = _updateVarGimmick(UpdateVarType.rightRangeFromStack, id);
    return _list([save, engine, upd]);
  }

  /// `make_absent_tree`.
  Node _makeAbsentTree(Node absent, Node? expr, bool isRangeCutter) {
    if (!isRangeCutter) {
      if (expr == null) {
        // default expr `\O*`
        final body = _trueAnychar();
        return _makeAbsentSimple(absent, body, 0, infiniteRepeat, false, true);
      }
      final simple = _asSimpleOneCharRepeat(expr);
      if (simple != null) {
        return _makeAbsentSimple(
          absent,
          simple.$1,
          simple.$2,
          simple.$3,
          simple.$4,
          simple.$5,
        );
      }
    }
    final save1 = _saveGimmick(SaveType.rightRange);
    final id1 = save1.id;
    final save2 = _saveGimmick(SaveType.s);
    final id2 = save2.id;
    final engine = _makeAbsentEngine(
      id1,
      absent,
      _trueAnychar(),
      0,
      infiniteRepeat,
      true,
      isRangeCutter,
    );
    final updS = _updateVarGimmick(UpdateVarType.sFromStack, id2);
    if (isRangeCutter) {
      return _list([save1, save2, engine, updS]);
    }
    final (tailSave, tailAlt) = _makeAbsentTail(id1);
    return _list([
      save1,
      save2,
      engine,
      updS,
      expr ?? _emptyNode(),
      tailSave,
      tailAlt,
    ]);
  }

  /// `is_simple_one_char_repeat`: (body, lower, upper, possessive) if [expr] is
  /// a single-char body under a `*`/`+`/`?`/`{n,m}` with a 1-width body.
  (Node, int, int, bool, bool)? _asSimpleOneCharRepeat(Node expr) {
    if (expr is! QuantNode) return null;
    final body = expr.body;
    if (body == null) return null;
    // one-char body: string of exactly one char, class, ctype, or anychar
    final oneChar =
        (body is StrNode && _strIsOneChar(body)) ||
        body is CClassNode ||
        body is CtypeNode;
    if (!oneChar) return null;
    return (body, expr.lower, expr.upper, false, expr.greedy);
  }

  bool _strIsOneChar(StrNode n) {
    final b = n.bytes;
    if (b.isEmpty) return false;
    return enc.length(b, 0, b.length) == b.length;
  }

  // ======================================================================
  //  Character classes  (prs_cc)
  // ======================================================================

  /// `\R` general newline: `(?>\x0D\x0A | [\x0A-\x0D\x{85}\x{2028}\x{2029}])`.
  Node _generalNewlineNode() {
    // The CRLF branch is the encoded code points 0x0d, 0x0a — not raw bytes, so
    // it spans one char each under multi-byte encodings (regcomp.c encodes via
    // ONIGENC_CODE_TO_MBC). The char-class branch matches code points directly.
    final buf = Uint8List(enc.codeToMbcLen(0x0d) + enc.codeToMbcLen(0x0a));
    final dlen = enc.codeToMbc(0x0d, buf, 0);
    final alen = enc.codeToMbc(0x0a, buf, dlen);
    final crlf = StrNode()..catBytes(buf, 0, dlen + alen);
    final cc = CClassNode();
    _ccAddRange(cc, 0x0a, 0x0d);
    _ccAddRange(cc, 0x85, 0x85);
    _ccAddRange(cc, 0x2028, 0x2029);
    final alt = AltNode(crlf, AltNode(cc));
    crlf.parent = alt;
    cc.parent = alt;
    final atomic = BagNode(BagType.stopBacktrack)..body = alt;
    alt.parent = atomic;
    return atomic;
  }

  /// Build a class node from a `\p{name}` / `\P{name}` Unicode property.
  /// POSIX/ctype property names → ctype id (for ASCII-mode handling). Other
  /// property names (scripts, categories, blocks) return null.
  static const Map<String, int> _propCtype = {
    'word': CType.word,
    'digit': CType.digit,
    'space': CType.space,
    'alpha': CType.alpha,
    'alnum': CType.alnum,
    'upper': CType.upper,
    'lower': CType.lower,
    'cntrl': CType.cntrl,
    'print': CType.print,
    'punct': CType.punct,
    'graph': CType.graph,
    'blank': CType.blank,
    'xdigit': CType.xdigit,
    'ascii': CType.ascii,
  };

  int? _propertyCtype(String name) => _propCtype[name.toLowerCase()];

  Node _charPropertyNode(String name, bool not) {
    final cc = CClassNode();
    final ctype = _propertyCtype(name);
    if (ctype != null) {
      // A POSIX/ctype property honours ASCII-mode options via _ccAddCtype.
      _ccAddCtype(cc, ctype, not);
      return cc;
    }
    // Legacy encodings resolve `\p{name}` against their own code values (EUC-JP
    // Hiragana/Katakana) before the Unicode property database is consulted.
    final encRanges = enc.encodingPropertyRanges(name);
    if (encRanges != null) {
      if (not) cc.setNot();
      for (var i = 0; i + 1 < encRanges.length; i += 2) {
        _ccAddRange(cc, encRanges[i], encRanges[i + 1]);
      }
      return cc;
    }
    final ranges = uni.unicodePropertyRanges(name);
    if (ranges == null) throw _err(OnigErr.invalidCharPropertyName, name);
    if (not) cc.setNot();
    for (var i = 0; i + 1 < ranges.length; i += 2) {
      _ccAddRange(cc, ranges[i], ranges[i + 1]);
    }
    return cc;
  }

  Node _prsCc() {
    // Cursor is just past the opening '['. Read code points (not bytes) so the
    // class parser works for wide encodings (UTF-16/32).
    final negated = _peekCode() == 0x5e;
    if (negated) _skipCode();

    CClassNode? prevCc; // accumulated `&&` intersection so far
    var cc = CClassNode(); // current segment
    var first = true; // ']' as first char is a literal
    var pendingLo = -1; // start of a pending range, or -1
    var prevWasValue = false;

    while (true) {
      if (_pend) throw _err(OnigErr.prematureEndOfCharClass);
      final startc = _peekCode();

      if (startc == 0x5d && !first) {
        _skipCode();
        break; // end of class
      }
      first = false;

      // POSIX bracket [[:name:]] — only when it's a well-formed start
      // (`is_posix_bracket_start`); otherwise `[` falls through to the
      // nested-class / literal handling below.
      if (startc == 0x5b && _peekCode2() == 0x3a && _isPosixBracketStart()) {
        _parsePosixBracket(cc);
        prevWasValue = false;
        pendingLo = -1;
        continue;
      }

      // Nested class `[...]` → OR its (effective) members into the segment.
      if (startc == 0x5b) {
        _skipCode(); // consume nested '['
        final nested = _prsCc() as CClassNode;
        _mergeCclass(cc, nested, and: false);
        prevWasValue = false;
        pendingLo = -1;
        continue;
      }

      // Set intersection `&&`.
      if (startc == 0x26 &&
          _peekCode2() == 0x26 &&
          syn.isOp2(SynOp2.cclassSetOp)) {
        _skipCode();
        _skipCode();
        if (prevCc == null) {
          prevCc = cc;
        } else {
          _mergeCclass(prevCc, cc, and: true);
        }
        cc = CClassNode();
        prevWasValue = false;
        pendingLo = -1;
        continue;
      }

      var isRangeDash = false;
      if (startc == 0x2d && prevWasValue) {
        // range operator, unless the next char is ']' or a `&&` set-op (then
        // the `-` is a literal member, e.g. `[a-&&-a]`).
        final n = _peekCode2();
        var beforeSetOp = false;
        if (n == 0x26 && syn.isOp2(SynOp2.cclassSetOp)) {
          final q1 = p + enc.length(s, p, end); // first '&'
          if (q1 < end) {
            final q2 = q1 + enc.length(s, q1, end);
            if (q2 < end && enc.mbcToCode(s, q2, end) == 0x26) {
              beforeSetOp = true;
            }
          }
        }
        if (n != -1 && n != 0x5d && !beforeSetOp) isRangeDash = true;
      }

      if (isRangeDash) {
        _skipCode(); // consume '-'
        _ccInRangeHi = true;
        final hi = _readCcValue(cc);
        _ccInRangeHi = false;
        if (hi == null) {
          throw _err(OnigErr.unmatchedRangeSpecifierInCharClass);
        }
        if (pendingLo < 0) {
          throw _err(OnigErr.unmatchedRangeSpecifierInCharClass);
        }
        if (hi < pendingLo) throw _err(OnigErr.emptyRangeInCharClass);
        _ccAddRange(cc, pendingLo, hi);
        pendingLo = -1;
        prevWasValue = false;
        continue;
      }

      final value = _readCcValue(cc);
      if (value == null) {
        prevWasValue = false;
        pendingLo = -1;
        continue;
      }
      // A standalone class member must be an encodable code point (a range
      // bound, handled above, may reach ONIG_MAX_CODE_POINT).
      if (enc.codeToMbcLen(value) < 0) {
        throw _err(OnigErr.invalidCodePointValue);
      }
      _ccAddRange(cc, value, value);
      pendingLo = value;
      prevWasValue = true;
    }

    if (prevCc != null) {
      _mergeCclass(prevCc, cc, and: true);
      cc = prevCc;
    }
    if (_opton(OnigOption.ignoreCase)) {
      _ccApplyCaseFold(cc);
      // Multi-char folds (e.g. ß→ss) can't live in a class; expand the class
      // to `(?:cc | seq…)` (regparse.c i_apply_case_fold `alt_root`). Only for
      // positive classes and full (non-ASCII-only) folding.
      final alt = _classMultiCharFoldAlt(cc);
      if (alt != null && !negated) return alt;
    }
    if (negated) cc.setNot();
    return cc;
  }

  /// If [cc] (positive, ignore-case) contains any char with a multi-char fold,
  /// return `(?:cc | seq₁ | seq₂ …)`; otherwise null.
  Node? _classMultiCharFoldAlt(CClassNode cc) {
    if (_opton(OnigOption.ignoreCaseIsAscii)) {
      return null; // no multi-char folds
    }
    final seqs = <List<int>>[];
    for (final src in uni.multiCharFoldSources()) {
      if (!_ccRaw(cc, src)) continue;
      final inv = uni.fold2Inverse(src);
      if (inv == null) continue;
      seqs.addAll(inv);
    }
    if (seqs.isEmpty) return null;
    // Build the alternation cc | "seq" | … (each seq an ignore-case string).
    final branches = <Node>[cc];
    for (final seq in seqs) {
      final str = StrNode()..setSt(NdSt.ignoreCase);
      final buf = Uint8List(enc.maxLength);
      for (final cp in seq) {
        final n = enc.codeToMbc(cp, buf, 0);
        str.catBytes(buf, 0, n);
      }
      branches.add(str);
    }
    Node? tail;
    for (var i = branches.length - 1; i >= 0; i--) {
      tail = AltNode(branches[i], tail);
    }
    return tail;
  }

  /// Read one class value (single char / escape) and return its code point,
  /// OR add a char-type directly (returning null).
  int? _readCcValue(CClassNode cc) {
    final c = _fetchChar();
    if (c == _cBackslash && !_pend) {
      final e = _fetchChar();
      switch (e) {
        case 0x64: // \d
          _ccAddCtype(cc, CType.digit, false);
          return null;
        case 0x44:
          _ccAddCtype(cc, CType.digit, true);
          return null;
        case 0x77:
          _ccAddCtype(cc, CType.word, false);
          return null;
        case 0x57:
          _ccAddCtype(cc, CType.word, true);
          return null;
        case 0x73:
          _ccAddCtype(cc, CType.space, false);
          return null;
        case 0x53:
          _ccAddCtype(cc, CType.space, true);
          return null;
        case 0x68:
          if (syn.isOp2(SynOp2.escHXdigit)) {
            _ccAddCtype(cc, CType.xdigit, false);
            return null;
          }
          return 0x68;
        case 0x48:
          if (syn.isOp2(SynOp2.escHXdigit)) {
            _ccAddCtype(cc, CType.xdigit, true);
            return null;
          }
          return 0x48;
        case 0x70: // \p{...}
        case 0x50: // \P{...}
          if (syn.isOp2(SynOp2.escPBraceCharProperty)) {
            _ccAddProperty(cc, e == 0x50);
            return null;
          }
          return e;
        case 0x6e:
          return 0x0a;
        case 0x74:
          return 0x09;
        case 0x72:
          return 0x0d;
        case 0x66:
          return 0x0c;
        case 0x61:
          return 0x07;
        case 0x65:
          return 0x1b;
        case 0x76:
          return 0x0b;
        case 0x62:
          return 0x08; // \b is backspace inside a class
        case 0x78:
          if (_peekCode() == 0x7b && syn.isOp(SynOp.escXBraceHex8)) {
            _skipCode(); // '{'
            return _readCcBracedSeq(cc, 16);
          }
          final hx = _readHexValue();
          return _ccCrudeByte(
            hx,
            16,
          ); // multibyte → gather crude MBC + validate
        case 0x75: // \uHHHH
          if (syn.isOp2(SynOp2.escUHex4)) return _readU4Value();
          return e;
        case 0x6f: // \o{...}
          if (syn.isOp(SynOp.escOBraceOctal) && !_pend && _peekCode() == 0x7b) {
            _skipCode(); // '{'
            return _readCcBracedSeq(cc, 8);
          }
          return e;
        case 0x63: // \cx
          if (syn.isOp(SynOp.escCControl)) return _fetchControlValue();
          return e;
        case 0x43: // \C-x
          if (syn.isOp2(SynOp2.escCapitalCBarControl)) {
            if (_pend) throw _err(OnigErr.endPatternAtControl);
            if (_fetchChar() != 0x2d) throw _err(OnigErr.controlCodeSyntax);
            return _fetchControlValue();
          }
          return e;
        case 0x4d: // \M-x
          if (syn.isOp2(SynOp2.escCapitalMBarMeta)) {
            if (_pend) throw _err(OnigErr.endPatternAtMeta);
            if (_fetchChar() != 0x2d) throw _err(OnigErr.metaCodeSyntax);
            if (_pend) throw _err(OnigErr.endPatternAtMeta);
            var v = _fetchChar();
            if (v == _cBackslash) v = _fetchEscapedValueRaw();
            return (v & 0xff) | 0x80;
          }
          return e;
        case 0x30:
        case 0x31:
        case 0x32:
        case 0x33:
        case 0x34:
        case 0x35:
        case 0x36:
        case 0x37:
          return _ccCrudeByte(_readOctalValue(e), 8); // crude MBC in multibyte
        default:
          return e; // escaped literal
      }
    }
    return c;
  }

  int _readU4Value() {
    var val = 0;
    var digits = 0;
    while (digits < 4 && _isHex(_peekCode())) {
      val = (val << 4) | _hexVal(_fetchChar());
      digits++;
    }
    if (digits < 4) throw _err(OnigErr.invalidCodePointValue);
    return val;
  }

  /// A raw byte from a numeric escape (`\xHH` / `\ooo`) inside a class. In a
  /// multi-byte encoding it begins a *crude* multi-byte character: continuation
  /// bytes must arrive as same-[base] numeric escapes (regparse.c `parse_cc`
  /// `TK_CRUDE_BYTE`) — e.g. `[\000\044]` in UTF-16BE is one char U+0024. Too
  /// few → `-206`, an invalid sequence → `-400`. In a single-byte encoding the
  /// byte is used as-is. Returns the decoded code point.
  int _ccCrudeByte(int firstByte, int base) {
    if (enc.isSingleByte) return firstByte;
    final expect = enc.lengthByFirstByte(firstByte);
    final bytes = <int>[firstByte];
    while (bytes.length < expect) {
      final b = _readCrudeContinuation(base);
      if (b < 0) throw _err(OnigErr.tooShortMultiByteString);
      bytes.add(b);
    }
    final buf = Uint8List.fromList(bytes);
    if (!enc.isValidMbcString(buf, 0, buf.length)) {
      throw _err(OnigErr.invalidCodePointValue);
    }
    return enc.mbcToCode(buf, 0, buf.length);
  }

  /// Read one continuation byte for [_ccCrudeByte]: the next token must be a
  /// same-[base] numeric escape (`\xHH` for 16, `\ooo` for 8). Returns the byte,
  /// or -1 (cursor restored) if the next token isn't such an escape.
  int _readCrudeContinuation(int base) {
    final save = p;
    if (_pend || _fetchChar() != _cBackslash) {
      p = save;
      return -1;
    }
    if (base == 16) {
      if (_pend || _fetchChar() != 0x78) {
        p = save;
        return -1;
      }
      return _readHexValue();
    }
    // base 8 — octal digits directly after the backslash.
    if (_pend) {
      p = save;
      return -1;
    }
    final d = _peekCode();
    if (d < 0x30 || d > 0x37) {
      p = save;
      return -1;
    }
    _skipCode();
    return _readOctalValue(d);
  }

  /// In-class `\x{...}` / `\o{...}` code-point sequence (cursor just past `{`).
  /// Adds every value / `lo - hi` range directly to [cc] and returns the last
  /// code point (so a following external `-` can range from it). Mirrors
  /// `fetch_token_cc` + `check_code_point_sequence_cc`: a single value must be
  /// immediately closed by `}` — `\x{V }` (trailing divider) is invalid.
  int _readCcBracedSeq(CClassNode cc, int base) {
    if (_pend) throw _err(OnigErr.invalidCodePointValue);
    final first = _scanBaseDigits(base, base == 16 ? 8 : 11);
    if (!_pend && _peekCode() == 0x7d) {
      // Single value, immediate '}'. Return it without adding/validating — the
      // class loop decides (a standalone member must be encodable, but a range
      // bound may reach ONIG_MAX_CODE_POINT).
      _skipCode();
      return first;
    }
    // As the HI of an external range (`lo-\x{first rest…}`): `first` is the
    // range bound, the rest are standalone members, and an internal range is
    // invalid.
    if (_ccInRangeHi) {
      while (true) {
        if (_pend) throw _err(OnigErr.invalidCodePointValue);
        final c = _peekCode();
        if (c == 0x7d) {
          _skipCode();
          return first;
        }
        if (c == 0x20 || c == 0x0a) {
          _skipCode();
          continue;
        }
        if (c == 0x2d) {
          throw _err(OnigErr.invalidCodePointValue); // internal range
        }
        final v = _scanBaseDigits(base, base == 16 ? 8 : 11);
        if (enc.codeToMbcLen(v) < 0) throw _err(OnigErr.invalidCodePointValue);
        _ccAddRange(cc, v, v);
      }
    }
    if (enc.codeToMbcLen(first) < 0) throw _err(OnigErr.invalidCodePointValue);
    _ccAddRange(cc, first, first);
    var lo = first; // CPS_START: may begin a range
    var rangePending = false;
    var last = first;
    var additional = 0;
    while (true) {
      if (_pend) throw _err(OnigErr.invalidCodePointValue);
      final c = _peekCode();
      if (c == 0x20 || c == 0x0a) {
        _skipCode();
        continue;
      }
      if (c == 0x7d) {
        _skipCode();
        if (rangePending || additional == 0) {
          throw _err(OnigErr.invalidCodePointValue);
        }
        return last;
      }
      if (c == 0x2d) {
        // '-' range operator
        _skipCode();
        if (lo < 0 || rangePending) throw _err(OnigErr.invalidCodePointValue);
        rangePending = true;
        continue;
      }
      final v = _scanBaseDigits(base, base == 16 ? 8 : 11);
      additional++;
      if (rangePending) {
        // A range bound may reach ONIG_MAX_CODE_POINT (0x7fffffff).
        if (v < lo) throw _err(OnigErr.emptyRangeInCharClass);
        _ccAddRange(cc, lo, v);
        rangePending = false;
        lo = -1; // CPS_EMPTY after a range
        last = v;
      } else {
        // A standalone code point must be encodable.
        if (enc.codeToMbcLen(v) < 0) throw _err(OnigErr.invalidCodePointValue);
        _ccAddRange(cc, v, v);
        lo = v;
        last = v;
      }
    }
  }

  int _readHexValue() {
    if (_peekCode() == 0x7b) {
      _skipCode();
      var val = 0;
      while (_isHex(_peekCode())) {
        val = (val << 4) | _hexVal(_fetchChar());
      }
      if (_peekCode() == 0x7d) _skipCode();
      return val;
    }
    var val = 0;
    var digits = 0;
    while (digits < 2 && _isHex(_peekCode())) {
      val = (val << 4) | _hexVal(_fetchChar());
      digits++;
    }
    return val;
  }

  int _readOctalValue(int first) {
    var val = first - 0x30;
    var count = 1;
    while (count < 3) {
      final b = _peekCode();
      if (b < 0x30 || b > 0x37) break;
      val = (val << 3) | (b - 0x30);
      _skipCode();
      count++;
    }
    return val & 0xff;
  }

  void _ccAddRange(CClassNode cc, int lo, int hi) {
    if (lo <= 0x7f && hi <= 0x7f) {
      cc.bs.setRange(lo, hi > 0x7f ? 0x7f : hi);
      if (hi <= 0x7f) return;
    }
    if (hi <= 0xff && enc.isSingleByte) {
      cc.bs.setRange(lo, hi);
      return;
    }
    // mixed / multibyte
    var mlo = lo;
    if (lo <= 0x7f) {
      cc.bs.setRange(lo, 0x7f);
      mlo = 0x80;
    }
    if (hi >= mlo) {
      (cc.mbuf ??= CodeRangeBuffer()).add(mlo, hi);
    }
  }

  /// Add a `\p{name}` / `\P{name}` property (with optional `^`) to a class.
  void _ccAddProperty(CClassNode cc, bool escNeg) {
    var not = escNeg;
    String name;
    if (!_pend && _peekCode() == 0x7b) {
      _skipCode(); // '{'
      if (!_pend && _peekCode() == 0x5e) {
        _skipCode();
        not = !not;
      }
      final start = p;
      while (!_pend && _peekCode() != 0x7d) {
        _skipCode();
      }
      if (_pend) throw _err(OnigErr.invalidCharPropertyName);
      name = String.fromCharCodes(s.sublist(start, p));
      _skipCode(); // '}'
    } else if (syn.isBehavior(SynBv.escPWithOneCharProp) && !_pend) {
      name = String.fromCharCode(_fetchChar());
    } else {
      throw _err(OnigErr.invalidCharPropertyName);
    }
    final ctype = _propertyCtype(name);
    if (ctype != null) {
      // POSIX/ctype property — honours ASCII-mode options via _ccAddCtype.
      _ccAddCtype(cc, ctype, not);
      return;
    }
    final ranges = uni.unicodePropertyRanges(name);
    if (ranges == null) throw _err(OnigErr.invalidCharPropertyName, name);
    if (!not) {
      for (var i = 0; i + 1 < ranges.length; i += 2) {
        _ccAddRange(cc, ranges[i], ranges[i + 1]);
      }
    } else {
      // Add the complement of the property's ranges (over the code space).
      var prev = 0;
      for (var i = 0; i + 1 < ranges.length; i += 2) {
        final lo = ranges[i];
        final hi = ranges[i + 1];
        if (lo > prev) _ccAddRange(cc, prev, lo - 1);
        prev = hi + 1;
      }
      if (prev <= 0x10ffff) _ccAddRange(cc, prev, 0x10ffff);
    }
  }

  /// Apply case folding to a class under `(?i)` (`i_apply_case_fold`): for each
  /// single-char fold pair, if one side is present add the other.
  void _ccApplyCaseFold(CClassNode cc) {
    // `(?I)` / ONIG_OPTION_IGNORECASE_IS_ASCII restricts folding to ASCII.
    final asciiOnly = _opton(OnigOption.ignoreCaseIsAscii);
    final adds = <int>[];
    enc.applyAllCaseFold(caseFoldFlag, (from, to) {
      if (asciiOnly && from >= 0x80) return;
      // In Folds1 each element of `to` is a single-char case-equivalent.
      for (final t in to) {
        if (asciiOnly && t >= 0x80) continue;
        if (_ccRaw(cc, from)) adds.add(t);
        if (_ccRaw(cc, t)) adds.add(from);
      }
    });
    for (final c in adds) {
      _ccAddRange(cc, c, c);
    }
  }

  bool _ccRaw(CClassNode cc, int code) {
    if (code < 256 && cc.bs.at(code)) return true;
    return cc.mbuf?.contains(code) ?? false;
  }

  // -- class set operations (or_cclass / and_cclass) -----------------------

  BitSet _bsEff(CClassNode cc) {
    final b = BitSet()..orWith(cc.bs); // always a copy — callers mutate it
    if (cc.isNot) b.invert();
    return b;
  }

  List<int> _mbEff(CClassNode cc, int mbMin, int mbMax) {
    final raw = cc.mbuf?.ranges ?? const <int>[];
    return cc.isNot ? CodeRangeBuffer.complement(raw, mbMin, mbMax) : raw;
  }

  /// dest := dest ∪ src (or dest := dest ∩ src for [and]), preserving dest's
  /// own negation flag (`or_cclass` / `and_cclass`).
  void _mergeCclass(CClassNode dest, CClassNode src, {required bool and}) {
    const mbMin = 0x80, mbMax = 0x7fffffff;
    final not1 = dest.isNot;
    // bitset
    final b1 = _bsEff(dest);
    final b2 = _bsEff(src);
    if (and) {
      b1.andWith(b2);
    } else {
      b1.orWith(b2);
    }
    if (not1) b1.invert();
    dest.bs.clearAll();
    dest.bs.orWith(b1);
    // multibyte ranges
    if (!enc.isSingleByte) {
      final e1 = _mbEff(dest, mbMin, mbMax);
      final e2 = _mbEff(src, mbMin, mbMax);
      var res = and
          ? CodeRangeBuffer.intersect(e1, e2)
          : CodeRangeBuffer.union(e1, e2);
      if (not1) res = CodeRangeBuffer.complement(res, mbMin, mbMax);
      final buf = CodeRangeBuffer();
      buf.ranges.addAll(res);
      dest.mbuf = buf;
    }
  }

  void _ccAddCtype(CClassNode cc, int ctype, bool not) {
    const maxCode = 0x10ffff;
    final asciiMode = _ctypeAsciiMode(ctype);
    // Legacy multibyte encodings (EUC-JP, SJIS, …) have no Unicode ctype ranges;
    // classify via the encoding's own is_code_ctype (`add_ctype_to_cc` fallback).
    if (!asciiMode && !enc.isSingleByte && !enc.isUnicodeEncoding) {
      _ccAddCtypeLegacyMb(cc, ctype, not);
      return;
    }
    // Unicode ctype: materialise its code-point ranges (or their complement for
    // a negated ctype). `_ccAddRange` routes < 0x80 to the byte bitset and the
    // rest to the multibyte range buffer. (`add_ctype_to_cc`.)
    final ranges = asciiMode ? null : uni.unicodeCtypeCodeRange(ctype);
    if (ranges != null) {
      if (!not) {
        for (var i = 0; i + 1 < ranges.length; i += 2) {
          _ccAddRange(cc, ranges[i], ranges[i + 1]);
        }
      } else {
        var prev = 0;
        for (var i = 0; i + 1 < ranges.length; i += 2) {
          if (ranges[i] > prev) _ccAddRange(cc, prev, ranges[i] - 1);
          prev = ranges[i + 1] + 1;
        }
        if (prev <= maxCode) _ccAddRange(cc, prev, maxCode);
      }
      return;
    }
    // ASCII-defined ctype (or ASCII-mode): members from the 7-bit table.
    for (var i = 0; i < 0x80; i++) {
      if (asciiIsCodeCtype(i, ctype) != not) cc.bs.set(i);
    }
    if (not) {
      // A negated ASCII ctype also matches every non-ASCII code point.
      if (enc.isSingleByte) {
        for (var i = 0x80; i < 0x100; i++) {
          if (!asciiIsCodeCtype(i & 0x7f, ctype)) cc.bs.set(i);
        }
      } else {
        _ccAddRange(cc, 0x80, maxCode);
      }
    }
  }

  /// `add_ctype_to_cc` fallback for a multibyte encoding without Unicode ctype
  /// ranges (EUC-JP, SJIS, …), non-ascii-mode. Single bytes are classified via
  /// the encoding's own [OnigEncoding.isCodeCtype]; for word/graph/print every
  /// multibyte char is a member (add the whole multibyte range), and negation
  /// of the *other* standard ctypes likewise matches every multibyte char.
  void _ccAddCtypeLegacyMb(CClassNode cc, int ctype, bool not) {
    const mbMax = 0x7fffffff; // MBCODE_START_POS(0x80) .. ~0
    final wgp =
        ctype == CType.word || ctype == CType.graph || ctype == CType.print;
    for (var c = 0; c < 0x100; c++) {
      if (enc.codeToMbcLen(c) == 1 && enc.isCodeCtype(c, ctype) != not) {
        cc.bs.set(c);
      }
    }
    if (wgp != not) _ccAddRange(cc, 0x80, mbMax);
  }

  /// `is_posix_bracket_start` — with the cursor at `[` (followed by `:`), is the
  /// text a well-formed POSIX bracket start: `[:` `^`? alpha+ `:]`?
  bool _isPosixBracketStart() {
    var q = p;
    q += enc.length(s, q, end); // past '['
    q += enc.length(s, q, end); // past ':'
    var n = 0;
    while (q < end) {
      final x = enc.mbcToCode(s, q, end);
      q += enc.length(s, q, end);
      if (x == 0x3a) {
        // ':' — must be immediately followed by ']', with a non-empty name.
        if (q < end && enc.mbcToCode(s, q, end) == 0x5d) return n != 0;
        return false;
      } else if (x == 0x5e && n == 0) {
        // leading '^' negation is allowed
      } else if (!enc.isCodeCtype(x, CType.alpha)) {
        return false;
      }
      n++;
    }
    return false;
  }

  void _parsePosixBracket(CClassNode cc) {
    // _peek is '['; consume "[:" (encoding-aware — each may be multi-byte).
    _skipCode(); // past '['
    _skipCode(); // past ':'
    var neg = false;
    if (!_pend && _peekCode() == 0x5e) {
      _skipCode();
      neg = true;
    }
    // POSIX class names are ASCII; build from decoded code points, not raw
    // bytes, so multi-byte encodings (UTF-16/32) name the class correctly.
    final sb = StringBuffer();
    while (!_pend && _peekCode() != 0x3a) {
      sb.writeCharCode(_peekCode());
      _skipCode();
    }
    // expect ":]"
    if (_pend || _peekCode() != 0x3a) {
      throw _err(OnigErr.invalidPosixBracketType);
    }
    _skipCode(); // past ':'
    if (_pend || _peekCode() != 0x5d) {
      throw _err(OnigErr.invalidPosixBracketType);
    }
    _skipCode(); // past ']'
    final ctype = _posixNameToCtype(sb.toString());
    if (ctype < 0) throw _err(OnigErr.invalidPosixBracketType);
    _ccAddCtype(cc, ctype, neg);
  }

  int _posixNameToCtype(String name) {
    switch (name) {
      case 'alnum':
        return CType.alnum;
      case 'alpha':
        return CType.alpha;
      case 'blank':
        return CType.blank;
      case 'cntrl':
        return CType.cntrl;
      case 'digit':
        return CType.digit;
      case 'graph':
        return CType.graph;
      case 'lower':
        return CType.lower;
      case 'print':
        return CType.print;
      case 'punct':
        return CType.punct;
      case 'space':
        return CType.space;
      case 'upper':
        return CType.upper;
      case 'xdigit':
        return CType.xdigit;
      case 'word':
        return CType.word;
      case 'ascii':
        return CType.ascii;
      default:
        return -1;
    }
  }
}
