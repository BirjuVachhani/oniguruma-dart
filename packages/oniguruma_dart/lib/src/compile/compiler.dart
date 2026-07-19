/// AST → bytecode compiler (`regcomp.c` `compile_tree` + minimal tuning).
///
/// Emits into `reg.ops`. Relative addresses are computed by index arithmetic
/// (`addr = targetIndex - ownIndex`), which yields bytecode semantically
/// identical to the C two-pass model (`pc += addr`) while being robust to
/// author error. The quantifier templates follow the C emission sequences
/// (PORTING_NOTES §6).
library;

import 'dart:typed_data';

import '../encoding/encoding.dart' show asciiIsCodeCtype;
import '../onig_errors.dart';
import '../onig_types.dart';
import '../parse/node.dart';
import '../exec/nfa.dart';
import '../regex.dart';
import '../unicode/unicode.dart' as uni;
import 'operation.dart';
import 'optimize.dart';

/// Compile [root] into [reg] (`onig_compile`).
void compile(Regex reg, Node? root) {
  final c = _Compiler(reg);
  if (root != null) {
    c._markCalled(root, <int>{});
    c._infRecCheckTrav(root); // reject never-ending recursion (-221)
    c._validateBackrefs(root); // -208 (out of range) / -209 (numbered w/ names)
    c._collectBackrefs(root);
    c._setEmptyRepeatNodes(root, null); // MEMST scope (empty_repeat_node)
    c._computeMemstCaps(root); // groups back-ref'd from outside their repeat
    c._computePushMem(root, 0);
    c.compileTree(root);
  }
  c.emit(Operation(Op.end));
  c._fixupCalls();
  reg.numCall =
      c._pendingCalls.length; // >0 enables recursion-safe repeat count
  c._markPossessiveStars(); // auto-possessify safe greedy single-item loops
  reg.flat = FlatOps.from(reg.ops); // flat arrays for the executor hot loop
  setOptimizeInfo(reg, root);
  // Build the linear-time NFA fast path for the safe subset (null otherwise).
  // Subexpression calls (recursion) are never safe, so only try without them.
  if (reg.numCall == 0) reg.nfa = buildNfa(reg, root);
}

class _Compiler {
  final Regex reg;
  List<Operation> get ops => reg.ops;

  /// group number → op index of its callable body entry.
  final Map<int, int> _calledAddr = {};

  /// pending `\g` call ops to patch once bodies are compiled: (opIndex, gnum).
  final List<List<int>> _pendingCalls = [];

  /// Group numbers targeted by a back-reference anywhere in the pattern. C only
  /// emits the rigid `OP_EMPTY_CHECK_END_MEMST` for an empty-repeat body whose
  /// captures are back-referenced (`set_empty_status_check_trav` +
  /// `empty_status_mem`); every other empty body uses the plain check.
  final Set<int> _backrefTargets = {};

  _Compiler(this.reg);

  /// Group numbers whose MEM_START/END must save+restore across backtracking
  /// (C's `push_mem_start = backtrack_mem | cap_history`). A group is push if it
  /// is back-referenced, called/recursive, or lexically inside an alternation,
  /// negative look-around, or *variable*-length repeat. Groups directly under a
  /// *fixed* `{n}` (and mandatory top-level groups) are NON-push: their
  /// captures are not rewound, which is what yields C's "inverted" `beg>end`
  /// regions on empty iterations. Absent here ⇒ non-push.
  final Set<int> _pushMem = {};

  static const int _stAlt = 1, _stNot = 2, _stVarRepeat = 4, _stInCall = 8;

  /// Fill [_pushMem] by walking the tree carrying the backtrack-context state.
  void _computePushMem(Node node, int state) {
    switch (node) {
      case BagNode():
        var bodyState = state;
        if (node.type == BagType.memory) {
          final called = node.st(NdSt.called) || node.st(NdSt.recursion);
          if (state != 0 || called || _backrefTargets.contains(node.regNum)) {
            _pushMem.add(node.regNum);
          }
          // A called group can be re-entered, so its sub-captures must also
          // save/restore across the call (else a recursion corrupts them).
          if (called) bodyState = state | _stInCall;
        }
        if (node.body != null) _computePushMem(node.body!, bodyState);
        if (node.then_ != null) _computePushMem(node.then_!, bodyState);
        if (node.else_ != null) _computePushMem(node.else_!, bodyState);
      case QuantNode():
        final varRepeat =
            node.lower != node.upper || node.upper == infiniteRepeat;
        if (node.body != null) {
          _computePushMem(node.body!, state | (varRepeat ? _stVarRepeat : 0));
        }
      case AnchorNode():
        final neg =
            node.type == Anchor.precReadNot ||
            node.type == Anchor.lookBehindNot;
        if (node.body != null) {
          _computePushMem(node.body!, state | (neg ? _stNot : 0));
        }
      case ListNode():
        Node? c = node;
        while (c is ListNode) {
          _computePushMem(c.car, state);
          c = c.cdr;
        }
        if (c != null) _computePushMem(c, state);
      case AltNode():
        Node? c = node;
        while (c is AltNode) {
          _computePushMem(c.car, state | _stAlt);
          c = c.cdr;
        }
        if (c != null) _computePushMem(c, state | _stAlt);
      default:
        break;
    }
  }

  /// Validate every back-reference: a numbered ref used when named groups
  /// exist (and CAPTURE_GROUP is off) is rejected (-209, renumber_backref_node);
  /// any ref to a group beyond numMem is invalid (-208, tune_tree ND_BACKREF).
  void _validateBackrefs(Node node) {
    switch (node) {
      case BackRefNode():
        // Conditional checkers `(?(n)…)` aren't ordinary back-references.
        if (node.st(NdSt.checker)) break;
        final byName = node.st(NdSt.byName);
        if (!byName &&
            reg.numNamed > 0 &&
            (reg.options & OnigOption.captureGroup) == 0) {
          throw OnigException(OnigErr.numberedBackrefOrCallNotAllowed);
        }
        for (final t in node.back) {
          if (t > reg.numMem) throw OnigException(OnigErr.invalidBackref);
        }
      case BagNode():
        if (node.body != null) _validateBackrefs(node.body!);
        if (node.then_ != null) _validateBackrefs(node.then_!);
        if (node.else_ != null) _validateBackrefs(node.else_!);
      case QuantNode():
        if (node.body != null) _validateBackrefs(node.body!);
      case AnchorNode():
        if (node.body != null) _validateBackrefs(node.body!);
      case ListNode():
        Node? cur = node;
        while (cur is ListNode) {
          _validateBackrefs(cur.car);
          cur = cur.cdr;
        }
        if (cur != null) _validateBackrefs(cur);
      case AltNode():
        Node? cur = node;
        while (cur is AltNode) {
          _validateBackrefs(cur.car);
          cur = cur.cdr;
        }
        if (cur != null) _validateBackrefs(cur);
      default:
        break;
    }
  }

  /// group → innermost empty-repeat QuantNode containing it (regcomp.c
  /// `empty_repeat_node`), for back-referenced groups only.
  final Map<int, QuantNode> _emptyRepeatNode = {};

  /// empty-repeat body node → the groups needing the rigid MEMST check
  /// (`empty_status_mem`): those back-referenced from *outside* the repeat.
  final Map<Node, Set<int>> _memstCaps = {};

  /// `set_empty_repeat_node_trav`: record, per back-referenced memory group, the
  /// innermost enclosing empty-capable repeat. Look-ahead / look-behind bodies
  /// break the chain (their matches aren't spanned by an outer repeat).
  void _setEmptyRepeatNodes(Node node, QuantNode? empty) {
    switch (node) {
      case ListNode():
        Node? c = node;
        while (c is ListNode) {
          _setEmptyRepeatNodes(c.car, empty);
          c = c.cdr;
        }
        if (c != null) _setEmptyRepeatNodes(c, empty);
      case AltNode():
        Node? c = node;
        while (c is AltNode) {
          _setEmptyRepeatNodes(c.car, empty);
          c = c.cdr;
        }
        if (c != null) _setEmptyRepeatNodes(c, empty);
      case QuantNode():
        final e = (node.body != null && _minByteLen(node.body!) == 0)
            ? node
            : empty;
        if (node.body != null) _setEmptyRepeatNodes(node.body!, e);
      case AnchorNode():
        if (node.body == null) break;
        final e =
            (node.type == Anchor.precRead || node.type == Anchor.lookBehind)
            ? null
            : empty;
        _setEmptyRepeatNodes(node.body!, e);
      case BagNode():
        if (node.body != null) _setEmptyRepeatNodes(node.body!, empty);
        if (node.type == BagType.memory &&
            empty != null &&
            _backrefTargets.contains(node.regNum)) {
          _emptyRepeatNode[node.regNum] = empty;
        }
        if (node.type == BagType.ifElse) {
          if (node.then_ != null) _setEmptyRepeatNodes(node.then_!, empty);
          if (node.else_ != null) _setEmptyRepeatNodes(node.else_!, empty);
        }
      default:
        break;
    }
  }

  /// `set_empty_status_check_trav`: a group's empty-repeat gets the MEMST check
  /// only for back-references sitting *outside* that repeat's body.
  void _computeMemstCaps(Node node) {
    switch (node) {
      case BackRefNode():
        if (node.st(NdSt.checker)) break;
        for (final g in node.back) {
          final r = _emptyRepeatNode[g];
          if (r != null && r.body != null && !_subtreeContains(r.body!, node)) {
            (_memstCaps[r.body!] ??= <int>{}).add(g);
          }
        }
      case BagNode():
        if (node.body != null) _computeMemstCaps(node.body!);
        if (node.then_ != null) _computeMemstCaps(node.then_!);
        if (node.else_ != null) _computeMemstCaps(node.else_!);
      case QuantNode():
        if (node.body != null) _computeMemstCaps(node.body!);
      case AnchorNode():
        if (node.body != null) _computeMemstCaps(node.body!);
      case ListNode():
        Node? c = node;
        while (c is ListNode) {
          _computeMemstCaps(c.car);
          c = c.cdr;
        }
        if (c != null) _computeMemstCaps(c);
      case AltNode():
        Node? c = node;
        while (c is AltNode) {
          _computeMemstCaps(c.car);
          c = c.cdr;
        }
        if (c != null) _computeMemstCaps(c);
      default:
        break;
    }
  }

  bool _subtreeContains(Node root, Node target) {
    if (identical(root, target)) return true;
    switch (root) {
      case ListNode():
        Node? c = root;
        while (c is ListNode) {
          if (_subtreeContains(c.car, target)) return true;
          c = c.cdr;
        }
        return c != null && _subtreeContains(c, target);
      case AltNode():
        Node? c = root;
        while (c is AltNode) {
          if (_subtreeContains(c.car, target)) return true;
          c = c.cdr;
        }
        return c != null && _subtreeContains(c, target);
      case QuantNode():
        return root.body != null && _subtreeContains(root.body!, target);
      case AnchorNode():
        return root.body != null && _subtreeContains(root.body!, target);
      case BagNode():
        return (root.body != null && _subtreeContains(root.body!, target)) ||
            (root.then_ != null && _subtreeContains(root.then_!, target)) ||
            (root.else_ != null && _subtreeContains(root.else_!, target));
      default:
        return false;
    }
  }

  /// Collect all back-reference target group numbers (fills [_backrefTargets]).
  void _collectBackrefs(Node node) {
    switch (node) {
      case BackRefNode():
        _backrefTargets.addAll(node.back);
      case BagNode():
        if (node.body != null) _collectBackrefs(node.body!);
        if (node.then_ != null) _collectBackrefs(node.then_!);
        if (node.else_ != null) _collectBackrefs(node.else_!);
      case QuantNode():
        if (node.body != null) _collectBackrefs(node.body!);
      case AnchorNode():
        if (node.body != null) _collectBackrefs(node.body!);
      case ListNode():
        Node? cur = node;
        while (cur is ListNode) {
          _collectBackrefs(cur.car);
          cur = cur.cdr;
        }
        if (cur != null) _collectBackrefs(cur);
      case AltNode():
        Node? cur = node;
        while (cur is AltNode) {
          _collectBackrefs(cur.car);
          cur = cur.cdr;
        }
        if (cur != null) _collectBackrefs(cur);
      default:
        break;
    }
  }

  /// Resolve a [CallNode]'s target group number (name → first group).
  int _callTarget(CallNode node) {
    if (node.byNumber) return node.calledGnum;
    final nums = reg.nameTable[node.name];
    if (nums == null || nums.isEmpty) {
      throw OnigException(OnigErr.undefinedNameReference, detail: node.name);
    }
    return nums.first;
  }

  /// Min byte length that follows `\g<>` calls (with a [seen] recursion guard),
  /// so `infinite_recursive_call_check`'s "have we consumed?" test is accurate.
  int _recMinLen(Node node, Set<int> seen) {
    switch (node) {
      case StrNode():
        return node.len;
      case CClassNode():
      case CtypeNode():
        return 1;
      case QuantNode():
        if (node.lower == 0 || node.body == null) return 0;
        return _recMinLen(node.body!, seen) * node.lower;
      case CallNode():
        final t = _callTarget(node);
        if (!seen.add(t)) return 0; // recursion → 0
        final target = (t >= 0 && t < reg.memNodes.length)
            ? reg.memNodes[t] as Node?
            : null;
        final r = target == null ? 0 : _recMinLen(target, seen);
        seen.remove(t);
        return r;
      case BagNode():
        if (node.type == BagType.ifElse) return 0;
        return node.body == null ? 0 : _recMinLen(node.body!, seen);
      case ListNode():
        var sum = 0;
        Node? c = node;
        while (c is ListNode) {
          sum += _recMinLen(c.car, seen);
          c = c.cdr;
        }
        if (c != null) sum += _recMinLen(c, seen);
        return sum;
      case AltNode():
        var min = infiniteLen;
        Node? c = node;
        while (c is AltNode) {
          final v = _recMinLen(c.car, seen);
          if (v < min) min = v;
          c = c.cdr;
        }
        if (c != null) {
          final v = _recMinLen(c, seen);
          if (v < min) min = v;
        }
        return min == infiniteLen ? 0 : min;
      default:
        return 0;
    }
  }

  /// Pre-pass: mark every group targeted by a `\g<>` as called (and recursive
  /// if the call is nested inside its own group). [enclosing] = group numbers
  /// currently on the path.
  void _markCalled(Node node, Set<int> enclosing) {
    switch (node) {
      case CallNode():
        final t = _callTarget(node);
        final bag = (t >= 0 && t < reg.memNodes.length)
            ? reg.memNodes[t] as BagNode?
            : null;
        if (bag != null) {
          bag.setSt(NdSt.called);
          if (enclosing.contains(t)) bag.setSt(NdSt.recursion);
        }
      case BagNode():
        final inner = node.type == BagType.memory
            ? ({...enclosing, node.regNum})
            : enclosing;
        if (node.body != null) _markCalled(node.body!, inner);
        if (node.then_ != null) _markCalled(node.then_!, inner);
        if (node.else_ != null) _markCalled(node.else_!, inner);
      case QuantNode():
        if (node.body != null) _markCalled(node.body!, enclosing);
      case AnchorNode():
        if (node.body != null) _markCalled(node.body!, enclosing);
      case ListNode():
        Node? cur = node;
        while (cur is ListNode) {
          _markCalled(cur.car, enclosing);
          cur = cur.cdr;
        }
        if (cur != null) _markCalled(cur, enclosing);
      case AltNode():
        Node? cur = node;
        while (cur is AltNode) {
          _markCalled(cur.car, enclosing);
          cur = cur.cdr;
        }
        if (cur != null) _markCalled(cur, enclosing);
      default:
        break;
    }
  }

  // --- never-ending recursion (-221) --------------------------------------
  // Ports regcomp.c infinite_recursive_call_check{,_trav}: a called+recursive
  // group whose body MUST recurse (every path) or recurses before consuming any
  // char (INFINITE) is rejected.
  static const int _recExist = 1 << 0;
  static const int _recMust = 1 << 1;
  static const int _recInfinite = 1 << 2;

  void _infRecCheckTrav(Node node) {
    switch (node) {
      case ListNode():
        Node? cur = node;
        while (cur is ListNode) {
          _infRecCheckTrav(cur.car);
          cur = cur.cdr;
        }
        if (cur != null) _infRecCheckTrav(cur);
      case AltNode():
        Node? cur = node;
        while (cur is AltNode) {
          _infRecCheckTrav(cur.car);
          cur = cur.cdr;
        }
        if (cur != null) _infRecCheckTrav(cur);
      case QuantNode():
        if (node.body != null) _infRecCheckTrav(node.body!);
      case AnchorNode():
        if (node.body != null) _infRecCheckTrav(node.body!);
      case BagNode():
        if (node.type == BagType.memory &&
            node.st(NdSt.recursion) &&
            node.st(NdSt.called)) {
          node.setSt(NdSt.mark1);
          final ret = node.body == null ? 0 : _infRecCheck(node.body!, 1);
          node.clearSt(NdSt.mark1);
          if ((ret & (_recMust | _recInfinite)) != 0) {
            throw OnigException(OnigErr.neverEndingRecursion);
          }
        }
        if (node.then_ != null) _infRecCheckTrav(node.then_!);
        if (node.else_ != null) _infRecCheckTrav(node.else_!);
        if (node.body != null) _infRecCheckTrav(node.body!);
      default:
        break;
    }
  }

  int _infRecCheck(Node node, int head) {
    var r = 0;
    switch (node) {
      case ListNode():
        var head2 = head;
        Node? x = node;
        while (x != null) {
          final car = x is ListNode ? x.car : x;
          final ret = _infRecCheck(car, head2);
          if (ret & _recInfinite != 0) return ret;
          r |= ret;
          if (head2 != 0 && _recMinLen(car, <int>{}) != 0) head2 = 0;
          x = x is ListNode ? x.cdr : null;
        }
      case AltNode():
        var must = _recMust;
        Node? alt = node;
        while (alt != null) {
          final car = alt is AltNode ? alt.car : alt;
          final ret = _infRecCheck(car, head);
          if (ret & _recInfinite != 0) return ret;
          r |= (ret & _recExist);
          must &= ret;
          alt = alt is AltNode ? alt.cdr : null;
        }
        r |= must;
      case QuantNode():
        if (node.upper == 0) break;
        r = _infRecCheck(node.body!, head);
        if ((r & _recMust) != 0 && node.lower == 0) r &= ~_recMust;
      case AnchorNode():
        if (node.body != null) r = _infRecCheck(node.body!, head);
      case CallNode():
        final t = _callTarget(node);
        final target = (t >= 0 && t < reg.memNodes.length)
            ? reg.memNodes[t] as Node?
            : null;
        if (target != null) r = _infRecCheck(target, head);
      case BagNode():
        if (node.type == BagType.memory) {
          if (node.st(NdSt.mark2)) return 0;
          if (node.st(NdSt.mark1)) {
            return head == 0
                ? (_recExist | _recMust)
                : (_recExist | _recMust | _recInfinite);
          }
          node.setSt(NdSt.mark2);
          r = node.body == null ? 0 : _infRecCheck(node.body!, head);
          node.clearSt(NdSt.mark2);
        } else if (node.type == BagType.ifElse) {
          var ret = node.body == null ? 0 : _infRecCheck(node.body!, head);
          if (ret & _recInfinite != 0) return ret;
          r |= ret;
          if (node.then_ != null) {
            final min = (head != 0 && node.body != null)
                ? _minByteLen(node.body!)
                : 0;
            ret = _infRecCheck(node.then_!, min != 0 ? 0 : head);
            if (ret & _recInfinite != 0) return ret;
            r |= ret;
          }
          if (node.else_ != null) {
            final eret = _infRecCheck(node.else_!, head);
            if (eret & _recInfinite != 0) return eret;
            r |= (eret & _recExist);
            if ((eret & _recMust) == 0) r &= ~_recMust;
          } else {
            r &= ~_recMust;
          }
        } else {
          r = node.body == null ? 0 : _infRecCheck(node.body!, head);
        }
      default:
        break;
    }
    return r;
  }

  void _fixupCalls() {
    for (final pc in _pendingCalls) {
      final addr = _calledAddr[pc[1]];
      if (addr == null) {
        throw OnigException(OnigErr.undefinedGroupReference);
      }
      ops[pc[0]].addr = addr; // absolute op index
    }
  }

  int emit(Operation op) {
    ops.add(op);
    return ops.length - 1;
  }

  int get pos => ops.length;

  Never _err(int code) => throw OnigException(code);

  // --- dispatch ------------------------------------------------------------

  void compileTree(Node node) {
    switch (node) {
      case StrNode():
        _compileString(node);
      case CClassNode():
        _compileCClass(node);
      case CtypeNode():
        _compileCtype(node);
      case BackRefNode():
        // A standalone checker `(?(n))` (empty-body conditional) is a bare
        // assertion: pass iff the group matched, else fail.
        if (node.st(NdSt.checker)) {
          emit(Operation(Op.backrefCheck)..ns = List<int>.of(node.back));
        } else {
          _compileBackref(node);
        }
      case QuantNode():
        _compileQuant(node);
      case BagNode():
        _compileBag(node);
      case AnchorNode():
        _compileAnchor(node);
      case ListNode():
        _compileList(node);
      case AltNode():
        _compileAlt(node);
      case CallNode():
        _compileCall(node);
      case GimmickNode():
        _compileGimmick(node);
    }
  }

  // --- list / alt ----------------------------------------------------------

  void _compileList(ListNode node) {
    Node? cur = node;
    while (cur is ListNode) {
      compileTree(cur.car);
      cur = cur.cdr;
    }
    if (cur != null) compileTree(cur);
  }

  /// `a|b|c` → PUSH/JUMP chain (PORTING_NOTES ALT template).
  void _compileAlt(AltNode node) {
    // Collect branches.
    final branches = <Node>[];
    Node? cur = node;
    while (cur is AltNode) {
      branches.add(cur.car);
      cur = cur.cdr;
    }
    if (cur != null) branches.add(cur);

    // Fast path: literal switch. Every branch has a fixed, DISTINCT single
    // first byte and is non-nullable, so at most one branch can match at any
    // position. Dispatch straight to that branch via a byte→addr table with no
    // PUSH/backtrack frame (there is never another branch to give back to).
    final lead = _distinctLeadBytes(branches);
    if (lead != null) {
      final dispIdx = emit(Operation(Op.dispatchByte));
      final table = Uint16List(256);
      final dJumpIdxs = <int>[];
      for (var i = 0; i < branches.length; i++) {
        table[lead[i]] = pos - dispIdx; // relative addr of this branch's start
        compileTree(branches[i]);
        if (i != branches.length - 1) dJumpIdxs.add(emit(Operation(Op.jump)));
      }
      final endIdx = pos;
      for (final j in dJumpIdxs) {
        ops[j].addr = endIdx - j;
      }
      ops[dispIdx].disp = table;
      return;
    }

    final jumpIdxs = <int>[];
    for (var i = 0; i < branches.length; i++) {
      final last = i == branches.length - 1;
      if (!last) {
        // Quick-check: if this branch has a complete, non-nullable first-byte
        // set, peek the current byte and skip the branch (no PUSH/enter/fail)
        // when it can't match.
        final fb = _altFirstBytes(branches[i]);
        final peekIdx = fb == null ? -1 : emit(Operation(Op.peekByte)..bs = fb);
        final pushIdx = emit(Operation(Op.push));
        compileTree(branches[i]);
        final jumpIdx = emit(Operation(Op.jump));
        jumpIdxs.add(jumpIdx);
        final nextStart = jumpIdx + 1; // op right after this JUMP
        ops[pushIdx].addr = nextStart - pushIdx;
        if (peekIdx >= 0) ops[peekIdx].addr = nextStart - peekIdx;
      } else {
        compileTree(branches[i]);
      }
    }
    final endIdx = pos;
    for (final j in jumpIdxs) {
      ops[j].addr = endIdx - j;
    }
  }

  /// Complete over-approximation of the first byte of [node] as a 256-bit
  /// [BitSet], or null if it can't be proven complete. Only non-nullable heads
  /// are accepted (so the set really is every byte that can begin a match).
  /// This is the safety condition for skipping the branch in [Op.peekByte].
  BitSet? _altFirstBytes(Node node) {
    final bs = BitSet();
    return _altFirstBytesInto(node, bs) ? bs : null;
  }

  bool _altFirstBytesInto(Node node, BitSet bs) {
    switch (node) {
      case StrNode():
        if (node.len == 0 || node.st(NdSt.ignoreCase)) return false;
        bs.set(node.bytes[0]);
        return true;
      case CClassNode():
        // Single-byte, non-negated classes only: a negated or multibyte class
        // can begin with bytes the bitset doesn't enumerate.
        if (node.mbuf != null && !node.mbuf!.isEmpty) return false;
        if (node.isNot) return false;
        var any = false;
        for (var b = 0; b < 256; b++) {
          if (node.bs.at(b)) {
            bs.set(b);
            any = true;
          }
        }
        return any;
      case QuantNode():
        if (node.lower < 1) {
          return false; // optional head → first byte may shift
        }
        return _altFirstBytesInto(node.body!, bs);
      case BagNode():
        switch (node.type) {
          case BagType.memory:
          case BagType.option:
          case BagType.stopBacktrack:
            return node.body != null && _altFirstBytesInto(node.body!, bs);
          case BagType.ifElse:
            return false;
        }
      case ListNode():
        // Safe only when the head consumes ≥1 byte, so it alone fixes the first
        // byte; a nullable head would let later elements contribute.
        if (_minByteLen(node.car) == 0) return false;
        return _altFirstBytesInto(node.car, bs);
      default:
        return false;
    }
  }

  /// Per-branch fixed first byte for a literal-switch alternation, or null when
  /// any branch's first byte isn't a single determinable value or two branches
  /// share a head. Distinctness is what makes [Op.dispatchByte] sound: it means
  /// at most one branch is viable at a position, so no give-back frame is ever
  /// needed. Reuses the (audited) non-nullable-head predicate [_altFirstBytes]
  /// and requires its set to be a singleton.
  List<int>? _distinctLeadBytes(List<Node> branches) {
    if (branches.length < 2) return null;
    final lead = List<int>.filled(branches.length, 0);
    final seen = <int>{};
    for (var i = 0; i < branches.length; i++) {
      final b = _singleLeadByte(branches[i]);
      if (b < 0 || !seen.add(b)) {
        return null; // undeterminable or duplicate head
      }
      lead[i] = b;
    }
    return lead;
  }

  /// The one fixed first byte of [node] if its first-byte set is a singleton and
  /// the head is non-nullable; otherwise -1.
  int _singleLeadByte(Node node) {
    final bs = BitSet();
    if (!_altFirstBytesInto(node, bs)) return -1;
    var found = -1;
    for (var b = 0; b < 256; b++) {
      if (bs.at(b)) {
        if (found != -1) return -1; // more than one possible first byte
        found = b;
      }
    }
    return found;
  }

  // --- string --------------------------------------------------------------

  void _compileString(StrNode node) {
    if (node.len == 0) return;
    if (node.st(NdSt.ignoreCase)) {
      // ASCII-only ignore-case: fold to lower and emit a case-insensitive
      // comparison via per-byte OP. Full Unicode fold expansion is P6.
      _compileStringIc(node);
      return;
    }
    final bytes = node.bytes;
    var i = 0;
    while (i < bytes.length) {
      final remain = bytes.length - i;
      final take = remain >= 5 ? 5 : remain;
      final op = _strOpForLen(take);
      final o = Operation(op)
        ..str = Uint8List.sublistView(bytes, i, i + take)
        ..strLen = take
        ..strN = take;
      emit(o);
      i += take;
    }
  }

  void _compileStringIc(StrNode node) {
    // Decode the pattern's code points.
    final b = node.bytes;
    final cps = <int>[];
    var i = 0;
    while (i < b.length) {
      cps.add(reg.enc.mbcToCode(b, i, b.length));
      i += reg.enc.length(b, i, b.length);
    }

    // `(?I)` / ONIG_OPTION_IGNORECASE_IS_ASCII restricts folding to ASCII and
    // (via onig_reg_init) clears the multi-char fold flag.
    final asciiOnly = (reg.caseFoldFlag & caseFoldAsciiOnly) != 0;
    final multiChar = (reg.caseFoldFlag & caseFoldMultiChar) != 0;

    // Expand multi-char folds (e.g. ß↔ss) into a fold-aware AST unit list.
    final units = <Node>[];
    var anyMulti = false;
    var pi = 0;
    while (pi < cps.length) {
      // Forward: sequence (cps[pi], cps[pi+1]) folds to single char(s).
      if (multiChar && pi + 1 < cps.length) {
        final tg = uni.fold2Forward(cps[pi], cps[pi + 1]);
        if (tg != null) {
          anyMulti = true;
          final seq = ListNode(
            _icClass([cps[pi]]),
            ListNode(_icClass([cps[pi + 1]])),
          );
          units.add(AltNode(seq, AltNode(_icClass(tg))));
          pi += 2;
          continue;
        }
      }
      // Inverse: a single char equivalent to a multi-char sequence (ß→ss).
      final seqs = multiChar ? uni.fold2Inverse(cps[pi]) : null;
      if (seqs != null && seqs.isNotEmpty) {
        anyMulti = true;
        Node alt = _icClass([cps[pi]]);
        for (final sq in seqs) {
          Node? tail;
          for (var k = sq.length - 1; k >= 0; k--) {
            tail = ListNode(_icClass([sq[k]]), tail);
          }
          alt = AltNode(alt, AltNode(tail ?? StrNode()));
        }
        units.add(alt);
        pi++;
        continue;
      }
      units.add(_icClass([cps[pi]]));
      pi++;
    }

    if (!anyMulti && !asciiOnly) {
      // Fast path: only single-char folds → code-point rep compare (op.ns).
      final reps = [for (final cp in cps) reg.enc.caseFoldRep(cp)];
      emit(
        Operation(Op.strN)
          ..ns = reps
          ..strN = reps.length
          ..flag = 2,
      );
      return;
    }
    final tree = nodeNewListFrom(units) ?? StrNode();
    compileTree(tree);
  }

  /// A character class matching [codes] and all their single-char case folds.
  /// Under ASCII-only folding a non-ASCII char matches only itself, and ASCII
  /// chars fold only within ASCII.
  CClassNode _icClass(List<int> codes) {
    final asciiOnly = (reg.caseFoldFlag & caseFoldAsciiOnly) != 0;
    final cc = CClassNode();
    for (final c in codes) {
      if (asciiOnly && c >= 0x80) {
        _ccAddCode(cc, c);
        continue;
      }
      for (final m in uni.caseFoldClassMembers(c)) {
        if (asciiOnly && m >= 0x80) continue;
        _ccAddCode(cc, m);
      }
    }
    return cc;
  }

  void _ccAddCode(CClassNode cc, int cp) {
    if (cp < 0x80) {
      cc.bs.set(cp);
    } else {
      (cc.mbuf ??= CodeRangeBuffer()).add(cp, cp);
    }
  }

  int _strOpForLen(int n) {
    switch (n) {
      case 1:
        return Op.str1;
      case 2:
        return Op.str2;
      case 3:
        return Op.str3;
      case 4:
        return Op.str4;
      case 5:
        return Op.str5;
      default:
        return Op.strN;
    }
  }

  // --- character class -----------------------------------------------------

  void _compileCClass(CClassNode node) {
    final hasMb = node.mbuf != null && !node.mbuf!.isEmpty;
    final hasBs = !node.bs.isEmpty;
    int op;
    if (hasMb && hasBs) {
      op = node.isNot ? Op.cclassMixNot : Op.cclassMix;
    } else if (hasMb) {
      op = node.isNot ? Op.cclassMbNot : Op.cclassMb;
    } else {
      op = node.isNot ? Op.cclassNot : Op.cclass;
    }
    emit(
      Operation(op)
        ..bs = node.bs
        ..mb = node.mbuf,
    );
  }

  // --- ctype ---------------------------------------------------------------

  void _compileCtype(CtypeNode node) {
    if (node.ctype == -2) {
      // \X: grapheme cluster, or word segment under `(?y{w})`.
      emit(
        Operation(Op.extendedGraphemeCluster)
          ..flag = node.st(NdSt.textSegmentWord)
              ? TextSegmentBoundaryType.word
              : TextSegmentBoundaryType.extendedGraphemeCluster,
      );
      return;
    }
    if (node.ctype == -1) {
      // anychar
      emit(Operation(node.st(NdSt.multiLine) ? Op.anycharMl : Op.anychar));
      return;
    }
    if (node.ctype == CType.word) {
      final ascii = node.asciiMode;
      final op = node.not
          ? (ascii ? Op.noWordAscii : Op.noWord)
          : (ascii ? Op.wordAscii : Op.word);
      emit(Operation(op));
      return;
    }
    // Other ctypes → an ASCII bitset class (Unicode ranges wired in P6).
    final bs = BitSet();
    for (var i = 0; i < 0x80; i++) {
      if (asciiIsCodeCtype(i, node.ctype)) bs.set(i);
    }
    emit(Operation(node.not ? Op.cclassNot : Op.cclass)..bs = bs);
  }

  // --- backref -------------------------------------------------------------

  void _compileBackref(BackRefNode node) {
    if (node.hasLevel) {
      // \k<name±n>: matches the group's capture n call levels away (the flat
      // capture may have been overwritten by recursion, so walk the stack).
      emit(
        Operation(Op.backrefWithLevel)
          ..ns = List<int>.of(node.back)
          ..num = node.back.length
          ..c = node.nestLevel
          ..flag = node.ignoreCase ? 1 : 0,
      );
      return;
    }
    // `flag == 1` marks a case-insensitive back-reference.
    final ic = node.ignoreCase ? 1 : 0;
    if (node.back.length == 1) {
      final n = node.back.first;
      if (n == 1) {
        emit(
          Operation(Op.backref1)
            ..mem = 1
            ..flag = ic,
        );
        return;
      }
      if (n == 2) {
        emit(
          Operation(Op.backref2)
            ..mem = 2
            ..flag = ic,
        );
        return;
      }
      emit(
        Operation(Op.backrefN)
          ..mem = n
          ..flag = ic,
      );
      return;
    }
    emit(
      Operation(Op.backrefMulti)
        ..ns = List<int>.of(node.back)
        ..num = node.back.length
        ..flag = ic,
    );
  }

  // --- anchors -------------------------------------------------------------

  void _compileAnchor(AnchorNode node) {
    switch (node.type) {
      case Anchor.beginBuf:
        emit(Operation(Op.beginBuf));
      case Anchor.endBuf:
        emit(Operation(Op.endBuf));
      case Anchor.beginLine:
        emit(Operation(Op.beginLine));
      case Anchor.endLine:
        emit(Operation(Op.endLine));
      case Anchor.semiEndBuf:
        emit(Operation(Op.semiEndBuf));
      case Anchor.beginPosition:
        emit(Operation(Op.checkPosition)..flag = CheckPositionType.searchStart);
      case Anchor.wordBoundary:
        emit(Operation(Op.wordBoundary)..flag = node.asciiMode ? 1 : 0);
      case Anchor.noWordBoundary:
        emit(Operation(Op.noWordBoundary)..flag = node.asciiMode ? 1 : 0);
      case Anchor.wordBegin:
        emit(Operation(Op.wordBegin)..flag = node.asciiMode ? 1 : 0);
      case Anchor.wordEnd:
        emit(Operation(Op.wordEnd)..flag = node.asciiMode ? 1 : 0);
      case Anchor.textSegmentBoundary:
        emit(
          Operation(Op.textSegmentBoundary)
            ..flag = node.st(NdSt.textSegmentWord)
                ? TextSegmentBoundaryType.word
                : TextSegmentBoundaryType.extendedGraphemeCluster
            ..flag2 = 0,
        );
      case Anchor.noTextSegmentBoundary:
        emit(
          Operation(Op.textSegmentBoundary)
            ..flag = node.st(NdSt.textSegmentWord)
                ? TextSegmentBoundaryType.word
                : TextSegmentBoundaryType.extendedGraphemeCluster
            ..flag2 = 1,
        ); // "not"
      case Anchor.precRead:
        _compilePrecRead(node, negative: false);
      case Anchor.precReadNot:
        _compilePrecRead(node, negative: true);
      case Anchor.lookBehind:
        _compileLookBehind(node, negative: false);
      case Anchor.lookBehindNot:
        _compileLookBehind(node, negative: true);
      default:
        _err(OnigErr.parserBug);
    }
  }

  /// Look-behind `(?<=X)` / `(?<!X)`: fixed or variable length.
  void _compileLookBehind(AnchorNode node, {required bool negative}) {
    final body = node.body!;
    // The absent operator manipulates right_range (via SAVE/UPDATE_VAR
    // right-range gimmicks), which a look-behind can't accommodate: C rejects
    // it (`ci.min == INFINITE_LEN` → INVALID_LOOK_BEHIND_PATTERN).
    if (_hasRightRangeGimmick(body, <int>{})) {
      throw OnigException(OnigErr.invalidLookBehindPattern);
    }
    final (minC, maxC) = _charLen(body);
    // A look-behind can only step back a bounded distance
    // (LOOK_BEHIND_MAX_CHAR_LEN = 65535 in onigenc_step_back).
    const lookBehindMaxCharLen = 65535;
    if ((maxC != infiniteLen && maxC > lookBehindMaxCharLen) ||
        minC > lookBehindMaxCharLen) {
      throw OnigException(OnigErr.invalidLookBehindPattern);
    }
    final n = minC;
    if (minC != maxC) {
      // divide_look_behind_alternatives (regcomp.c tune_look_behind,
      // CHAR_LEN_TOP_ALT_FIXED): a top-level alternation whose branches are each
      // individually fixed-length becomes an alternation of *fixed* look-behinds:
      // `(?<=A|B)` → `(?<=A)|(?<=B)`. Each is then a real backtrackable
      // alternative, so a later failure re-enters and tries the next branch
      // (e.g. `(?<=;()|)\k<1>` reaches the `;()` branch when `\k<1>` needs g1).
      // Only when the look-behind's captures are actually referenced, otherwise
      // the branch choice is unobservable and the plain variable step-back (which
      // C would optimize away via reset-empty) gives identical offsets.
      if (!negative && body is AltNode && _lookBehindCapturesUsed(body)) {
        final branches = _altBranches(body);
        if (branches.every((b) {
          final (a, c) = _charLen(b);
          return a == c && c != infiniteLen;
        })) {
          _compileDividedLookBehind(branches);
          return;
        }
      }
      _compileVarLookBehind(body, minC, maxC, negative: negative);
      return;
    }
    if (!negative) {
      final id = _newMarkId();
      emit(
        Operation(Op.mark)
          ..id = id
          ..flag = 1,
      ); // save_pos
      emit(
        Operation(Op.stepBackStart)
          ..len = n
          ..c =
              0 // remaining = 0 (fixed)
          ..addr = 1,
      );
      compileTree(body);
      emit(
        Operation(Op.cutToMark)
          ..id = id
          ..flag = 1,
      ); // restore_pos
    } else {
      final id = _newMarkId();
      final pushIdx = emit(Operation(Op.push));
      emit(
        Operation(Op.mark)
          ..id = id
          ..flag = 0,
      );
      emit(
        Operation(Op.stepBackStart)
          ..len = n
          ..c = 0
          ..addr = 1,
      );
      compileTree(body);
      emit(Operation(Op.popToMark)..id = id);
      emit(Operation(Op.pop));
      emit(Operation(Op.fail));
      ops[pushIdx].addr = pos - pushIdx;
    }
  }

  /// C `check_node_in_look_behind`'s `used`: does [node] contain a captured
  /// group that is back-referenced/called, or a `\K` keep? Only then does a
  /// divided look-behind's branch choice affect an observable capture.
  bool _lookBehindCapturesUsed(Node node) {
    switch (node) {
      case BagNode():
        if (node.type == BagType.memory &&
            (_backrefTargets.contains(node.regNum) || node.st(NdSt.called))) {
          return true;
        }
        return (node.body != null && _lookBehindCapturesUsed(node.body!)) ||
            (node.then_ != null && _lookBehindCapturesUsed(node.then_!)) ||
            (node.else_ != null && _lookBehindCapturesUsed(node.else_!));
      case QuantNode():
        return node.body != null && _lookBehindCapturesUsed(node.body!);
      case AnchorNode():
        return node.body != null && _lookBehindCapturesUsed(node.body!);
      case GimmickNode():
        return node.type == GimmickType.save &&
            node.detailType == SaveType.keep;
      case ListNode():
        Node? cur = node;
        while (cur is ListNode) {
          if (_lookBehindCapturesUsed(cur.car)) return true;
          cur = cur.cdr;
        }
        return cur != null && _lookBehindCapturesUsed(cur);
      case AltNode():
        Node? cur = node;
        while (cur is AltNode) {
          if (_lookBehindCapturesUsed(cur.car)) return true;
          cur = cur.cdr;
        }
        return cur != null && _lookBehindCapturesUsed(cur);
      default:
        return false;
    }
  }

  /// Flatten a top-level `A|B|C` [AltNode] chain into its branch nodes.
  List<Node> _altBranches(AltNode alt) {
    final out = <Node>[];
    Node? cur = alt;
    while (cur is AltNode) {
      out.add(cur.car);
      cur = cur.cdr;
    }
    if (cur != null) out.add(cur);
    return out;
  }

  /// Compile a divided look-behind: `(?<=A)|(?<=B)|…`, one fixed-length
  /// look-behind per branch, chained as an alternation so each is an
  /// independently-backtrackable alternative.
  void _compileDividedLookBehind(List<Node> branches) {
    Node? tail;
    for (var i = branches.length - 1; i >= 0; i--) {
      final lb = AnchorNode(Anchor.lookBehind)..body = branches[i];
      tail = tail == null ? lb : AltNode(lb, tail);
    }
    compileTree(tail!);
  }

  /// True if [node] contains a SIDE-EFFECTING absent operator (`(?~|…)`
  /// range-cutter/clear, marked ABSENT_WITH_SIDE_EFFECTS). These can't live in
  /// a look-behind (plain `(?~…)` is fine). Follows `\g<>` calls once via [seen].
  bool _hasRightRangeGimmick(Node node, Set<int> seen) {
    if (node.st(NdSt.absentWithSideEffects)) return true;
    switch (node) {
      case GimmickNode():
        return false;
      case ListNode():
        Node? c = node;
        while (c is ListNode) {
          if (_hasRightRangeGimmick(c.car, seen)) return true;
          c = c.cdr;
        }
        return c != null && _hasRightRangeGimmick(c, seen);
      case AltNode():
        Node? c = node;
        while (c is AltNode) {
          if (_hasRightRangeGimmick(c.car, seen)) return true;
          c = c.cdr;
        }
        return c != null && _hasRightRangeGimmick(c, seen);
      case QuantNode():
        return node.body != null && _hasRightRangeGimmick(node.body!, seen);
      case AnchorNode():
        return node.body != null && _hasRightRangeGimmick(node.body!, seen);
      case BagNode():
        return (node.body != null && _hasRightRangeGimmick(node.body!, seen)) ||
            (node.then_ != null && _hasRightRangeGimmick(node.then_!, seen)) ||
            (node.else_ != null && _hasRightRangeGimmick(node.else_!, seen));
      case CallNode():
        final t = _callTarget(node);
        if (!seen.add(t)) return false; // guard against recursion
        final target = (t >= 0 && t < reg.memNodes.length)
            ? reg.memNodes[t] as Node?
            : null;
        return target != null && _hasRightRangeGimmick(target, seen);
      default:
        return false;
    }
  }

  /// Character-length range `(min, max)` of [node] (max may be [infiniteLen]).
  int _addInf(int a, int b) =>
      (a == infiniteLen || b == infiniteLen) ? infiniteLen : a + b;
  int _maxInf(int a, int b) =>
      (a == infiniteLen || b == infiniteLen) ? infiniteLen : (a > b ? a : b);

  (int, int) _charLen(Node node) {
    switch (node) {
      case StrNode():
        final n = _charCount(node);
        return (n, n);
      case CClassNode():
      case CtypeNode():
        return (1, 1);
      case AnchorNode():
        return (0, 0);
      case BackRefNode():
        return (0, infiniteLen);
      case QuantNode():
        final (bmin, bmax) = _charLen(node.body!);
        final lo = bmin * node.lower;
        final hi = (node.upper == infiniteRepeat || bmax == infiniteLen)
            ? infiniteLen
            : bmax * node.upper;
        return (lo, hi);
      case BagNode():
        if (node.type == BagType.ifElse) {
          // `(?(c)T|E)`: the "yes" path is condition+then, the "no" path is
          // else; the node spans the alternation of the two (node_char_len).
          final (cmn, cmx) = node.body == null ? (0, 0) : _charLen(node.body!);
          final (tmn, tmx) = node.then_ == null
              ? (0, 0)
              : _charLen(node.then_!);
          final (emn, emx) = node.else_ == null
              ? (0, 0)
              : _charLen(node.else_!);
          final yesMin = _addInf(cmn, tmn);
          final yesMax = _addInf(cmx, tmx);
          return (yesMin < emn ? yesMin : emn, _maxInf(yesMax, emx));
        }
        if (node.body == null) return (0, 0);
        return _charLen(node.body!);
      case ListNode():
        var lo = 0, hi = 0;
        Node? cur = node;
        while (cur is ListNode) {
          final (a, b) = _charLen(cur.car);
          lo += a;
          hi = (hi == infiniteLen || b == infiniteLen) ? infiniteLen : hi + b;
          cur = cur.cdr;
        }
        if (cur != null) {
          final (a, b) = _charLen(cur);
          lo += a;
          hi = (hi == infiniteLen || b == infiniteLen) ? infiniteLen : hi + b;
        }
        return (lo, hi);
      case AltNode():
        var lo = infiniteLen, hi = 0;
        Node? cur = node;
        while (cur is AltNode) {
          final (a, b) = _charLen(cur.car);
          if (a < lo) lo = a;
          hi = (hi == infiniteLen || b == infiniteLen)
              ? infiniteLen
              : (b > hi ? b : hi);
          cur = cur.cdr;
        }
        if (cur != null) {
          final (a, b) = _charLen(cur);
          if (a < lo) lo = a;
          hi = (hi == infiniteLen || b == infiniteLen)
              ? infiniteLen
              : (b > hi ? b : hi);
        }
        return (lo == infiniteLen ? 0 : lo, hi);
      case CallNode():
        return (0, infiniteLen);
      case GimmickNode():
        return (0, 0);
    }
  }

  int _charCount(StrNode node) {
    final b = node.bytes;
    var count = 0;
    var i = 0;
    while (i < b.length) {
      i += reg.enc.length(b, i, b.length);
      count++;
    }
    return count;
  }

  /// `(?=...)` / `(?!...)` (PORTING_NOTES anchor templates).
  void _compilePrecRead(AnchorNode node, {required bool negative}) {
    final body = node.body!;
    if (!negative) {
      final markIdx = emit(
        Operation(Op.mark)
          ..id = _newMarkId()
          ..flag = 1,
      ); // save_pos = true
      final id = ops[markIdx].id;
      compileTree(body);
      emit(
        Operation(Op.cutToMark)
          ..id = id
          ..flag = 1,
      ); // restore_pos = true
    } else {
      final id = _newMarkId();
      final pushIdx = emit(Operation(Op.push));
      emit(
        Operation(Op.mark)
          ..id = id
          ..flag = 0,
      );
      compileTree(body);
      emit(Operation(Op.popToMark)..id = id);
      emit(Operation(Op.pop));
      emit(Operation(Op.fail));
      // PUSH target = op right after FAIL (the success continuation).
      ops[pushIdx].addr = pos - pushIdx;
    }
  }

  int _markSeq = 0;
  int _newMarkId() => _markSeq++;

  /// Variable-length look-behind (PORTING_NOTES; compile_anchor_look_behind_node
  /// variable branch). Sets right_range to the current position, steps back
  /// `min..max` chars, and requires the body to end exactly at that position.
  void _compileVarLookBehind(
    Node body,
    int minC,
    int maxC, {
    required bool negative,
  }) {
    final diff = maxC == infiniteLen ? infiniteLen : maxC - minC;
    final rrId = _newMarkId();
    if (!negative) {
      final markId = _newMarkId();
      emit(
        Operation(Op.saveVal)
          ..flag = SaveType.rightRange
          ..id = rrId,
      );
      emit(Operation(Op.updateVar)..flag = UpdateVarType.rightRangeToS);
      emit(
        Operation(Op.mark)
          ..id = markId
          ..flag = 0,
      );
      emit(
        Operation(Op.stepBackStart)
          ..len = minC
          ..c = diff
          ..addr = 1,
      );
      compileTree(body);
      emit(
        Operation(Op.checkPosition)..flag = CheckPositionType.currentRightRange,
      );
      emit(
        Operation(Op.cutToMark)
          ..id = markId
          ..flag = 0,
      );
      emit(
        Operation(Op.updateVar)
          ..flag = UpdateVarType.rightRangeFromStack
          ..id = rrId,
      );
    } else {
      // Negative: succeed iff the body does NOT match ending here.
      final markId = _newMarkId();
      emit(
        Operation(Op.saveVal)
          ..flag = SaveType.rightRange
          ..id = rrId,
      );
      emit(Operation(Op.updateVar)..flag = UpdateVarType.rightRangeToS);
      final pushIdx = emit(Operation(Op.push));
      emit(
        Operation(Op.mark)
          ..id = markId
          ..flag = 0,
      );
      emit(
        Operation(Op.stepBackStart)
          ..len = minC
          ..c = diff
          ..addr = 1,
      );
      compileTree(body);
      emit(
        Operation(Op.checkPosition)..flag = CheckPositionType.currentRightRange,
      );
      emit(Operation(Op.popToMark)..id = markId);
      emit(Operation(Op.pop));
      emit(Operation(Op.fail));
      ops[pushIdx].addr = pos - pushIdx;
      emit(
        Operation(Op.updateVar)
          ..flag = UpdateVarType.rightRangeFromStack
          ..id = rrId,
      );
    }
  }

  // --- bag (groups) --------------------------------------------------------

  void _compileBag(BagNode node) {
    switch (node.type) {
      case BagType.memory:
        _compileMemory(node);
      case BagType.option:
        if (node.body != null) compileTree(node.body!);
      case BagType.stopBacktrack:
        _compileStopBacktrack(node);
      case BagType.ifElse:
        _compileIfElse(node);
    }
  }

  /// `(?(cond)then|else)` (PORTING_NOTES BAG_IF_ELSE template).
  void _compileIfElse(BagNode node) {
    final id = _newMarkId();
    emit(
      Operation(Op.mark)
        ..id = id
        ..flag = 0,
    );
    final pushIdx = emit(Operation(Op.push));
    // condition: a backref-check node.
    final cond = node.body;
    if (cond is BackRefNode) {
      // Check every group of the (possibly multiplexed) name: the condition
      // is true if ANY of them matched.
      emit(Operation(Op.backrefCheck)..ns = List<int>.of(cond.back));
    } else if (cond != null) {
      compileTree(cond);
    }
    emit(
      Operation(Op.cutToMark)
        ..id = id
        ..flag = 0,
    );
    if (node.then_ != null) compileTree(node.then_!);
    final jumpIdx = emit(Operation(Op.jump));
    final elseCutIdx = emit(
      Operation(Op.cutToMark)
        ..id = id
        ..flag = 0,
    );
    if (node.else_ != null) compileTree(node.else_!);
    final endIdx = pos;
    ops[pushIdx].addr = elseCutIdx - pushIdx; // cond-fail path
    ops[jumpIdx].addr = endIdx - jumpIdx; // skip else after then
  }

  void _compileMemory(BagNode node) {
    if (node.st(NdSt.called)) {
      // Callable group: inline entry CALLs its own body, then JUMPs over it.
      // Body block ends in OP_RETURN and is entered only via CALL.
      // Group 0 (`\g<0>`, whole-pattern recursion) has no capture region, so it
      // emits no MEM_START/MEM_END (regcomp.c: regnum == 0 && ND_IS_CALLED).
      final isZero = node.regNum == 0;
      final callIdx = emit(Operation(Op.call));
      final jumpIdx = emit(Operation(Op.jump));
      final bodyStart = pos;
      _calledAddr[node.regNum] = bodyStart;
      if (!isZero) emit(Operation(Op.memStartPush)..mem = node.regNum);
      if (node.body != null) compileTree(node.body!);
      if (!isZero) {
        emit(
          Operation(node.st(NdSt.recursion) ? Op.memEndPushRec : Op.memEndPush)
            ..mem = node.regNum,
        );
      }
      emit(Operation(Op.returnOp));
      final endIdx = pos;
      ops[callIdx].addr = bodyStart; // absolute
      ops[jumpIdx].addr = endIdx - jumpIdx; // relative skip past body
      return;
    }
    // Push variants save+restore across backtracking; non-push variants set the
    // capture registers directly (no rewind), matching C's `push_mem_start` /
    // `push_mem_end` so non-push groups can leave "inverted" empty regions.
    final push = _pushMem.contains(node.regNum);
    emit(Operation(push ? Op.memStartPush : Op.memStart)..mem = node.regNum);
    if (node.body != null) compileTree(node.body!);
    emit(Operation(push ? Op.memEndPush : Op.memEnd)..mem = node.regNum);
  }

  void _compileCall(CallNode node) {
    final t = _callTarget(node);
    final callIdx = emit(Operation(Op.call));
    _pendingCalls.add([callIdx, t]);
  }

  /// True if [node] contains a memory group that is targeted by a `\g<>` call
  /// (so a `(?<n>…){0}` body must still be compiled as the call target).
  bool _containsCalledGroup(Node? node) {
    switch (node) {
      case BagNode():
        if (node.type == BagType.memory && node.st(NdSt.called)) return true;
        return _containsCalledGroup(node.body) ||
            _containsCalledGroup(node.then_) ||
            _containsCalledGroup(node.else_);
      case QuantNode():
        return _containsCalledGroup(node.body);
      case AnchorNode():
        return _containsCalledGroup(node.body);
      case ListNode():
        Node? c = node;
        while (c is ListNode) {
          if (_containsCalledGroup(c.car)) return true;
          c = c.cdr;
        }
        return _containsCalledGroup(c);
      case AltNode():
        Node? c = node;
        while (c is AltNode) {
          if (_containsCalledGroup(c.car)) return true;
          c = c.cdr;
        }
        return _containsCalledGroup(c);
      default:
        return false;
    }
  }

  /// `(?>...)` atomic group: MARK + body + CUT_TO_MARK (general form).
  void _compileStopBacktrack(BagNode node) {
    final id = _newMarkId();
    emit(
      Operation(Op.mark)
        ..id = id
        ..flag = 0,
    );
    if (node.body != null) compileTree(node.body!);
    // flag=2: atomic cut. Keep any right_range/\K SAVE_VAL from the body (e.g.
    // an enclosed range-cutter `(?~|…)`) so its boundary is undone when the
    // enclosing scope backtracks out of the atomic (#891). flag=0/1 cuts don't.
    emit(
      Operation(Op.cutToMark)
        ..id = id
        ..flag = 2,
    );
  }

  // --- gimmick -------------------------------------------------------------

  void _compileGimmick(GimmickNode node) {
    switch (node.type) {
      case GimmickType.save:
        // \K keep, or SAVE_S / SAVE_RIGHT_RANGE for the absent operator.
        emit(
          Operation(Op.saveVal)
            ..flag = node.detailType
            ..id = node.id,
        );
      case GimmickType.fail:
        emit(Operation(Op.fail));
      case GimmickType.callout:
        emit(
          Operation(node.calloutIsName ? Op.calloutName : Op.calloutContents)
            ..id = node.id
            ..calloutName = node.calloutName
            ..calloutContents = node.calloutContents
            ..calloutTag = node.calloutTag
            ..calloutArgs = node.calloutArgs,
        );
      case GimmickType.updateVar:
        emit(
          Operation(Op.updateVar)
            ..flag = node.detailType
            ..id = node.id,
        );
    }
  }

  // --- quantifiers ---------------------------------------------------------

  /// `QUANTIFIER_EXPAND_LIMIT_SIZE`: C unrolls a repeat only while the compiled
  /// body is small enough (`tlen*count <= 10`); larger counts use `OP_REPEAT`.
  /// This exact boundary decides whether a repeat gets empty-check semantics,
  /// so we reproduce it 1:1 from `compile_quantifier_node`.
  static const int _expandLimit = 10;

  void _compileQuant(QuantNode node) {
    final body = node.body!;
    final lower = node.lower;
    final upper = node.upper;
    final greedy = node.greedy;
    final tlen = _opLen(body);
    if (tlen == 0) return; // body compiles to nothing
    final infinite = upper == infiniteRepeat;
    final canEmpty = _minByteLen(body) == 0;

    if (infinite && (lower <= 1 || tlen * lower <= _expandLimit)) {
      // Expand the mandatory `lower` copies (no empty-check), then a single
      // greedy/lazy loop whose body carries the empty-check.
      _compileNTimes(body, lower);
      if (greedy) {
        if (!canEmpty && _isStarEligible(body)) {
          _greedyInfiniteStar(body);
        } else {
          _greedyInfinite(body, canEmpty);
        }
      } else {
        _lazyInfinite(body, canEmpty);
      }
    } else if (upper == 0) {
      // {0}: normally emits nothing, but if the body contains a group that is
      // called via `\g<>` (include_referred), the body must still be compiled
      // (jumped over) so the call target exists. (compile_quantifier_node.)
      if (_containsCalledGroup(body)) {
        final jumpIdx = emit(Operation(Op.jump));
        compileTree(body);
        ops[jumpIdx].addr = pos - jumpIdx;
      }
    } else if (!infinite &&
        greedy &&
        (upper == 1 || (tlen + 1) * upper <= _expandLimit)) {
      _compileNTimes(body, lower);
      final optional = upper - lower;
      if (optional > 0) _greedyFinite(body, optional);
    } else if (!greedy && upper == 1 && lower == 0) {
      _lazyFinite(body, 1); // '??'
    } else {
      // Everything else (large greedy ranges, all non-trivial lazy ranges,
      // large `{n,}`) goes through OP_REPEAT, exactly as C does.
      _countedRepeat(body, lower, upper, greedy);
    }
  }

  /// Counted repeat via OP_REPEAT/OP_REPEAT_INC (PORTING_NOTES template G). The
  /// body is wrapped in an empty-check when it can match empty, so an empty
  /// iteration ends the repeat (skips OP_REPEAT_INC) instead of looping.
  void _countedRepeat(Node body, int lower, int upper, bool greedy) {
    final id = reg.numRepeat++;
    // infiniteRepeat (-1) → a large upper so `n >= upper` never fires.
    final storedUpper = upper == infiniteRepeat ? infiniteLen : upper;
    reg.repeatRanges.add(RepeatRange(lower, storedUpper, 0)); // bodyAddr below
    final repIdx = emit(Operation(greedy ? Op.repeat : Op.repeatNg)..id = id);
    final bodyStart = pos;
    _compileBodyWithEmptyCheck(body, _minByteLen(body) == 0);
    emit(Operation(greedy ? Op.repeatInc : Op.repeatIncNg)..id = id);
    final exit = pos;
    ops[repIdx].addr = exit - repIdx; // REPEAT.addr → exit (relative)
    reg.repeatRanges[id] = RepeatRange(lower, storedUpper, bodyStart);
  }

  /// Compiled operation-count of [node], mirroring C `compile_length_tree`
  /// with every `OPSIZE_*` == 1 (this build). Used *only* to reproduce C's
  /// expand-vs-`OP_REPEAT` quantifier decisions; never affects emitted
  /// addresses, so estimates that model C's notional bytecode (e.g. the
  /// anychar-star fast path my emitter doesn't use) are intentional.
  int _opLen(Node node) {
    switch (node) {
      case StrNode():
        return _strRuns(node);
      case CClassNode():
      case CtypeNode():
      case BackRefNode():
      case CallNode():
      case GimmickNode():
        return 1;
      case AnchorNode():
        return _anchorLen(node);
      case QuantNode():
        return _quantLen(node);
      case BagNode():
        return _bagLen(node);
      case ListNode():
        var len = 0;
        Node? c = node;
        while (c is ListNode) {
          len += _opLen(c.car);
          c = c.cdr;
        }
        if (c != null) len += _opLen(c);
        return len;
      case AltNode():
        var len = 0, n = 0;
        Node? c = node;
        while (c is AltNode) {
          len += _opLen(c.car);
          n++;
          c = c.cdr;
        }
        if (c != null) {
          len += _opLen(c);
          n++;
        }
        return len + 2 * (n - 1); // (PUSH+JUMP) per split
    }
  }

  /// Number of maximal runs of equal per-char byte length (C
  /// `compile_length_string_node`: one OP_STR op per run).
  int _strRuns(StrNode node) {
    final b = node.bytes;
    if (b.isEmpty) return 0;
    var runs = 1;
    var i = 0;
    var prevLen = reg.enc.length(b, 0, b.length);
    i += prevLen;
    while (i < b.length) {
      final len = reg.enc.length(b, i, b.length);
      if (len != prevLen) {
        runs++;
        prevLen = len;
      }
      i += len;
    }
    return runs;
  }

  int _quantLen(QuantNode qn) {
    final tlen = _opLen(qn.body!);
    if (tlen == 0) return 0;
    final infinite = qn.upper == infiniteRepeat;
    final b = qn.body!;
    // anychar-infinite-greedy fast path (OP_ANYCHAR_STAR).
    if (qn.greedy && infinite && b is CtypeNode && b.ctype == -1) {
      if (qn.lower <= 1 || tlen * qn.lower <= _expandLimit) {
        return 1 + tlen * qn.lower;
      }
    }
    final canEmpty = _minByteLen(b) == 0;
    final modTlen = tlen + (canEmpty ? 2 : 0);
    if (infinite && (qn.lower <= 1 || tlen * qn.lower <= _expandLimit)) {
      final head = (qn.lower == 1 && tlen > _expandLimit) ? 1 : tlen * qn.lower;
      return head + 1 + modTlen + 1; // (PUSH|JUMP) + body + (JUMP|PUSH)
    } else if (qn.upper == 0) {
      return qn.includeReferred ? (1 + tlen) : 0;
    } else if (!infinite &&
        qn.greedy &&
        (qn.upper == 1 || (tlen + 1) * qn.upper <= _expandLimit)) {
      return tlen * qn.lower + (1 + tlen) * (qn.upper - qn.lower);
    } else if (!qn.greedy && qn.upper == 1 && qn.lower == 0) {
      return 1 + 1 + tlen; // '??'
    }
    return 1 + modTlen + 1; // OP_REPEAT + body + OP_REPEAT_INC
  }

  int _anchorLen(AnchorNode node) {
    final tlen = node.body != null ? _opLen(node.body!) : 0;
    final leadLen = node.leadNode != null ? _opLen(node.leadNode!) : 0;
    final fixed = node.charMinLen == node.charMaxLen;
    switch (node.type) {
      case Anchor.precRead:
        return 2 + tlen; // MARK + body + CUT_TO_MARK
      case Anchor.precReadNot:
        return 5 + tlen; // PUSH+MARK + body + POP_TO_MARK+POP+FAIL
      case Anchor.lookBehind:
        return fixed ? 3 + tlen : 12 + tlen + (leadLen > 0 ? 1 + leadLen : 0);
      case Anchor.lookBehindNot:
        return fixed ? 6 + tlen : 15 + tlen + (leadLen > 0 ? 1 + leadLen : 0);
      default:
        return 1; // word/text-segment boundary and simple anchors (^ $ \A …)
    }
  }

  int _bagLen(BagNode node) {
    final tlen = node.body != null ? _opLen(node.body!) : 0;
    switch (node.type) {
      case BagType.option:
        return tlen;
      case BagType.memory:
        return tlen + 2; // MEM_START + body + MEM_END (non-called)
      case BagType.stopBacktrack:
        return tlen + 2; // MARK + body + CUT_TO_MARK
      case BagType.ifElse:
        final thenLen = node.then_ != null ? _opLen(node.then_!) : 0;
        final elseLen = node.else_ != null ? _opLen(node.else_!) : 0;
        return tlen + thenLen + elseLen + 5;
    }
  }

  void _compileNTimes(Node body, int n) {
    for (var i = 0; i < n; i++) {
      compileTree(body);
    }
  }

  /// Eligible for the [Op.starGreedy] fast loop: a body that compiles to exactly
  /// one single-character-consuming op with no captures/empty-check. A char
  /// class, or a ctype (anychar / `\w` / `\d`-style). `\X` (grapheme, ctype -2)
  /// is excluded (it consumes a whole cluster via its own opcode).
  bool _isStarEligible(Node body) =>
      body is CClassNode || (body is CtypeNode && body.ctype != -2);

  /// Greedy `*` / `+` / `{n,}` tail for a single-item body, as one [Op.starGreedy]
  /// marker immediately followed by the (unchanged) body op. The executor scans
  /// the whole run in a tight loop and pushes ONE decrement-on-backtrack frame
  /// (semantics identical to template B's PUSH/body/JUMP, exit = starPc + 2).
  void _greedyInfiniteStar(Node body) {
    emit(Operation(Op.starGreedy));
    final before = pos;
    compileTree(body); // must be exactly one op (guaranteed by _isStarEligible)
    assert(pos - before == 1, 'starGreedy body must be a single op');
  }

  /// Auto-possessification: a greedy single-item loop `X*`/`X+` (an [Op.starGreedy])
  /// followed by an atom whose first byte cannot be an `X` (or by end-of-pattern)
  /// never needs to give a character back (giving back exposes only `X` chars,
  /// where the follower can't match). Mark such loops possessive (flag=1) so the
  /// executor skips pushing the give-back frame entirely. Provably match-preserving.
  void _markPossessiveStars() {
    for (var i = 0; i + 1 < ops.length; i++) {
      if (ops[i].opcode != Op.starGreedy) continue;
      final body = ops[i + 1];
      // Find the next consuming op after the loop exit (i+2), skipping only the
      // zero-width capture-group boundary ops. Anything else → don't possessify.
      var j = i + 2;
      while (j < ops.length && _isMemBoundary(ops[j].opcode)) {
        j++;
      }
      if (j >= ops.length) continue;
      if (_starPossessiveSafe(body, ops[j])) ops[i].flag = 1;
    }
  }

  static bool _isMemBoundary(int op) =>
      op == Op.memStart ||
      op == Op.memStartPush ||
      op == Op.memEnd ||
      op == Op.memEndPush ||
      op == Op.memEndPushRec ||
      op == Op.memEndRec;

  bool _starPossessiveSafe(Operation body, Operation next) {
    if (next.opcode == Op.end) return true; // nothing follows the loop
    final nb = _firstLiteralByte(next);
    if (nb < 0 || nb >= 0x80) {
      return false; // only ASCII single-literal followers
    }
    return !_bodyMatchesByte(
      body,
      nb,
    ); // safe iff the follower ∉ loop's char set
  }

  /// First byte of a plain (non-ignore-case) literal op, or -1.
  int _firstLiteralByte(Operation op) {
    switch (op.opcode) {
      case Op.str1:
      case Op.str2:
      case Op.str3:
      case Op.str4:
      case Op.str5:
      case Op.strN:
        if (op.flag != 0) return -1; // ignore-case / crude: bail
        final s = op.str;
        return (s != null && s.isNotEmpty) ? s[0] : -1;
      default:
        return -1;
    }
  }

  /// Whether the [Op.starGreedy] body matches ASCII byte [b] (b < 0x80). Returns
  /// true (⇒ not disjoint ⇒ not possessive) for any body it can't prove disjoint.
  bool _bodyMatchesByte(Operation body, int b) {
    switch (body.opcode) {
      case Op.cclass:
      case Op.cclassMb:
      case Op.cclassMix:
        return body.bs?.at(b) ?? true; // mbuf is ≥0x80, irrelevant for ASCII b
      case Op.word:
      case Op.wordAscii:
        return asciiIsCodeCtype(b, CType.word);
      default:
        return true; // conservative: assume a match → keep backtracking
    }
  }

  /// PORTING_NOTES quant template (B): greedy `*` / `+` / `{n,}` tail.
  void _greedyInfinite(Node body, bool emptyNeeded) {
    final pushIdx = emit(Operation(Op.push));
    _compileBodyWithEmptyCheck(body, emptyNeeded);
    final jumpIdx = emit(Operation(Op.jump));
    ops[jumpIdx].addr = pushIdx - jumpIdx; // loop back to PUSH
    ops[pushIdx].addr = (jumpIdx + 1) - pushIdx; // exit = after JUMP
  }

  /// Template (C): lazy `*?` / `+?` / `{n,}?` tail.
  void _lazyInfinite(Node body, bool emptyNeeded) {
    final jumpIdx = emit(Operation(Op.jump));
    final bodyStart = pos;
    _compileBodyWithEmptyCheck(body, emptyNeeded);
    final pushIdx = emit(Operation(Op.push));
    ops[pushIdx].addr = bodyStart - pushIdx; // backtrack re-enters body
    ops[jumpIdx].addr = pushIdx - jumpIdx; // jump forward to PUSH
  }

  /// Template (E): greedy finite `{n,m}` optionals (unrolled).
  void _greedyFinite(Node body, int optional) {
    final pushIdxs = <int>[];
    for (var i = 0; i < optional; i++) {
      pushIdxs.add(emit(Operation(Op.push)));
      compileTree(body); // plain body (no empty-check for finite)
    }
    final endIdx = pos;
    for (final pi in pushIdxs) {
      ops[pi].addr = endIdx - pi; // each PUSH skips to the end
    }
  }

  /// Lazy finite `{n,m}?` optionals (unrolled; template F repeated).
  void _lazyFinite(Node body, int optional) {
    final jumpIdxs = <int>[];
    for (var i = 0; i < optional; i++) {
      final pushIdx = emit(Operation(Op.push));
      final jumpIdx = emit(Operation(Op.jump));
      jumpIdxs.add(jumpIdx);
      ops[pushIdx].addr = (jumpIdx + 1) - pushIdx; // alt = body branch
      compileTree(body);
    }
    final endIdx = pos;
    for (final j in jumpIdxs) {
      ops[j].addr = endIdx - j; // prefer skipping to the end
    }
  }

  void _compileBodyWithEmptyCheck(Node body, bool needed) {
    if (!needed) {
      compileTree(body);
      return;
    }
    final id = reg.numEmptyCheck++;
    // Rigid MEMST is used ONLY for captures back-referenced from OUTSIDE this
    // repeat (C's `empty_status_mem` via `set_empty_status_check_trav`); a
    // back-reference inside the same repeat uses the plain check (e.g.
    // `(?:\1a|())*`).
    final caps = (_memstCaps[body] ?? const <int>{}).toList()..sort();
    if (caps.isEmpty) {
      emit(Operation(Op.emptyCheckStart)..mem = id);
      compileTree(body);
      emit(Operation(Op.emptyCheckEnd)..mem = id);
    } else {
      emit(
        Operation(Op.emptyCheckStart)
          ..mem = id
          ..ns = caps,
      );
      compileTree(body);
      emit(
        Operation(Op.emptyCheckEndMemst)
          ..mem = id
          ..ns = caps,
      );
    }
  }

  // --- minimum byte length (for empty-check decision) ----------------------

  int _minByteLen(Node node) {
    switch (node) {
      case StrNode():
        return node.len;
      case CClassNode():
        return 1;
      case CtypeNode():
        return 1;
      case AnchorNode():
        return 0;
      case BackRefNode():
        return 0;
      case QuantNode():
        if (node.lower == 0) return 0;
        return _minByteLen(node.body!) * node.lower;
      case BagNode():
        switch (node.type) {
          case BagType.memory:
          case BagType.option:
          case BagType.stopBacktrack:
            return node.body == null ? 0 : _minByteLen(node.body!);
          case BagType.ifElse:
            return 0;
        }
      case ListNode():
        var sum = 0;
        Node? cur = node;
        while (cur is ListNode) {
          sum += _minByteLen(cur.car);
          cur = cur.cdr;
        }
        if (cur != null) sum += _minByteLen(cur);
        return sum;
      case AltNode():
        var min = infiniteLen;
        Node? cur = node;
        while (cur is AltNode) {
          final m = _minByteLen(cur.car);
          if (m < min) min = m;
          cur = cur.cdr;
        }
        if (cur != null) {
          final m = _minByteLen(cur);
          if (m < min) min = m;
        }
        return min == infiniteLen ? 0 : min;
      case CallNode():
        return 0;
      case GimmickNode():
        return 0;
    }
  }
}
