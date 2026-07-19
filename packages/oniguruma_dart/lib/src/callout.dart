/// Callouts (`(?{…})` contents callouts and `(*name…)` name callouts): the
/// callback mechanism from `regext.c` / oniguruma.h, adapted to Dart.
///
/// A callout is invoked while matching; its return value steers the match:
/// [CalloutResult.success] continues, [CalloutResult.fail] forces backtracking,
/// [CalloutResult.error] aborts. Built-in name callouts (`FAIL`, `MISMATCH`,
/// `SKIP`, `ERROR`, `COUNT`, `TOTAL_COUNT`, `MAX`) are provided; users can also
/// register named callouts and a contents-callout handler.
library;

/// Callout outcome:
///  * [success]: continue matching (`ONIG_CALLOUT_SUCCESS`);
///  * [fail]: backtrack, trying alternatives (`ONIG_CALLOUT_FAIL`, e.g. `(*FAIL)`);
///  * [mismatch]: abort the current match attempt without trying alternatives
///    (`ONIG_MISMATCH`, e.g. `(*MISMATCH)`);
///  * [error]: abort the whole search with an error.
enum CalloutResult { success, fail, mismatch, error }

/// Whether the callout fires as matching advances or on backtracking.
abstract final class CalloutIn {
  static const int progress = 1;
  static const int retraction = 2;
  static const int both = 3;
}

/// Arguments passed to a callout callback.
class CalloutArgs {
  /// `(*name…)` callout name, or null for a contents callout.
  final String? name;

  /// `(?{contents})` body, or null for a name callout.
  final String? contents;

  /// `[tag]` if present.
  final String? tag;

  /// Positional `(arg,arg,…)` arguments.
  final List<String> args;

  /// Current subject byte offset when the callout fires.
  final int strPos;

  /// Whether this firing is progress or retraction.
  final int calloutIn;

  /// Per-callout mutable state (e.g. for COUNT), keyed by callout id.
  final Map<int, int> counters;

  /// This callout's id (index within the pattern).
  final int id;

  /// Maps every tagged callout's `[tag]` to its id, so a callout can read
  /// another's counter by tag (e.g. `(*CMP{AB,<,CD})`).
  final Map<String, int> tagToId;

  const CalloutArgs({
    this.name,
    this.contents,
    this.tag,
    this.args = const [],
    required this.strPos,
    this.calloutIn = CalloutIn.progress,
    required this.counters,
    required this.id,
    this.tagToId = const {},
  });
}

/// A callout callback (`OnigCalloutFunc`).
typedef CalloutFunc = CalloutResult Function(CalloutArgs args);

/// Registry of name callouts + the contents-callout handler.
class CalloutRegistry {
  final Map<String, CalloutFunc> _named = {};

  /// Names that also fire on *retraction* (backtracking), not only progress:
  /// e.g. `COUNT`/`TOTAL_COUNT` with direction `X` decrement as the match
  /// unwinds. The executor pushes an undo frame for these on a successful firing.
  final Set<String> _retraction = {};

  CalloutFunc? contentsHandler;

  CalloutRegistry() {
    _installBuiltins();
  }

  void register(String name, CalloutFunc f, {bool onRetraction = false}) {
    final key = name.toUpperCase();
    _named[key] = f;
    if (onRetraction) {
      _retraction.add(key);
    } else {
      _retraction.remove(key);
    }
  }

  CalloutFunc? lookup(String name) => _named[name.toUpperCase()];

  /// Whether the named callout should also fire on retraction (backtracking).
  bool firesOnRetraction(String name) =>
      _retraction.contains(name.toUpperCase());

  void _installBuiltins() {
    _named['FAIL'] = (_) => CalloutResult.fail;
    _named['MISMATCH'] = (_) => CalloutResult.mismatch;
    _named['ERROR'] = (_) => CalloutResult.error;
    _named['SKIP'] = (_) => CalloutResult.success;
    // COUNT/TOTAL_COUNT keep a signed net counter (slot 0 in C) steered by the
    // direction arg: `>` counts progress, `<` counts retraction, `X` counts
    // progress and un-counts retraction (net depth on the live path). CMP reads
    // these by tag. Both fire on retraction (registered below).
    CalloutResult count(CalloutArgs a) {
      final dir = a.args.isNotEmpty ? a.args[0] : '>';
      final retract = a.calloutIn == CalloutIn.retraction;
      var v = a.counters[a.id] ?? 0;
      if (retract) {
        if (dir == '<') {
          v++;
        } else if (dir == 'X') {
          v--;
        }
      } else if (dir != '<') {
        v++;
      }
      a.counters[a.id] = v;
      return CalloutResult.success;
    }

    _named['COUNT'] = count;
    _named['TOTAL_COUNT'] = count;
    _retraction
      ..add('COUNT')
      ..add('TOTAL_COUNT');
    _named['MAX'] = (a) {
      final n = (a.counters[a.id] ?? 0) + 1;
      a.counters[a.id] = n;
      final limit = a.args.isNotEmpty ? int.tryParse(a.args[0]) ?? 0 : 0;
      return (limit > 0 && n > limit)
          ? CalloutResult.fail
          : CalloutResult.success;
    };
    // `(*CMP{L,op,R})`: compare two operands (a `[tag]` counter or a literal
    // number) with ==, !=, <, >, <=, >=. Succeeds/fails accordingly.
    _named['CMP'] = (a) {
      if (a.args.length < 3) return CalloutResult.error;
      final lv = _cmpOperand(a, a.args[0]);
      final rv = _cmpOperand(a, a.args[2]);
      final bool res;
      switch (a.args[1]) {
        case '==':
          res = lv == rv;
        case '!=':
          res = lv != rv;
        case '<':
          res = lv < rv;
        case '>':
          res = lv > rv;
        case '<=':
          res = lv <= rv;
        case '>=':
          res = lv >= rv;
        default:
          return CalloutResult.error;
      }
      return res ? CalloutResult.success : CalloutResult.fail;
    };
  }

  /// A CMP operand: an integer literal, or a `[tag]` naming another callout
  /// whose counter (slot 0) is read.
  static int _cmpOperand(CalloutArgs a, String s) {
    final n = int.tryParse(s);
    if (n != null) return n;
    final id = a.tagToId[s];
    return id == null ? 0 : (a.counters[id] ?? 0);
  }
}

/// The global default registry (used unless a [CalloutRegistry] is passed to a
/// search). Built-ins are always available.
final CalloutRegistry defaultCalloutRegistry = CalloutRegistry();
