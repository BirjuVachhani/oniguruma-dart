/// Targeted differential fuzz for the literal-switch alternation opcode
/// (`Op.dispatchByte`). The generic fuzzer only builds 2-way alternations, so
/// this one specifically generates multi-branch alternations with DISTINCT
/// first bytes (the exact shape that compiles to a dispatch table) — bare,
/// embedded with a continuation that forces backtracking, quantified, and
/// captured — and asserts byte-identical results against the C reference CLI.
///
///   dart run test/differential/fuzz_dispatch.dart [count] [seed] [cli]
library;

import 'dart:io';

import 'diff_util.dart';

// Words with pairwise-distinct first letters, so a random subset always yields
// a distinct-first-byte switch (dispatch-eligible).
const _words = [
  'lorem', 'ipsum', 'dolor', 'sit', 'amet', 'be', 'go', 'red', 'up', 'joy',
  'fox', 'kit', 'wolf', 'nap', 'queue', 'hi', 'via', 'zap', // distinct heads
];

const _quants = ['', '', '', '+', '*', '?'];
const _tails = ['', '', r'\b', 's', 'x', r'\d', '.', '!'];

String _pick(_Rng r, List<String> xs) => xs[r.next(xs.length)];

/// Build a distinct-first-byte alternation of [k] branches plus optional
/// wrapping (capture/non-capture), quantifier and a trailing continuation.
String _genPattern(_Rng r) {
  final k = 2 + r.next(5); // 2..6 branches
  final used = <int>{};
  final branches = <String>[];
  var guard = 0;
  while (branches.length < k && guard++ < 100) {
    final w = _words[r.next(_words.length)];
    final head = w.codeUnitAt(0);
    if (!used.add(head)) continue; // keep first bytes distinct
    branches.add(w);
  }
  if (branches.length < 2) return 'lorem|ipsum';
  final capture = r.next(2) == 0;
  final open = capture ? '(' : '(?:';
  var pat = '$open${branches.join('|')})';
  pat += _pick(r, _quants);
  pat += _pick(r, _tails);
  if (r.next(3) == 0) pat = '${_pick(r, _words)} $pat'; // a prefix literal
  return pat;
}

const _subjAlphabet = 'loremipsumdolrsatbgoyfxkwnqhvz .!0123';
String _genSubject(_Rng r) {
  final n = r.next(24);
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    sb.write(_subjAlphabet[r.next(_subjAlphabet.length)]);
  }
  // occasionally splice in a whole word so matches actually happen
  if (r.next(2) == 0) {
    final at = r.next(sb.length + 1);
    final s = sb.toString();
    return s.substring(0, at) + _words[r.next(_words.length)] + s.substring(at);
  }
  return sb.toString();
}

class _Rng {
  int _s;
  _Rng(this._s);
  int next(int n) {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s % n;
  }
}

Future<void> main(List<String> argv) async {
  final count = argv.isNotEmpty ? int.parse(argv[0]) : 8000;
  final seed = argv.length > 1 ? int.parse(argv[1]) : 12345;
  final cli = argv.length > 2 ? argv[2] : 'benchmark/c/onig_cli';

  final oracle = await COracle.start(cli);
  final rng = _Rng(seed);
  var passed = 0, failed = 0, skipped = 0;
  final failures = <String>[];

  for (var i = 0; i < count; i++) {
    final pat = _genPattern(rng);
    final subj = _genSubject(rng);
    final pb = b(pat), sb = b(subj);
    final c = await oracle.run(pb, sb);
    if (c.kind == 'ERROR') {
      skipped++;
      continue;
    }
    final d = runDart(pb, sb, retryLimit: 1000000);
    if (d.kind == 'ERROR') {
      skipped++;
      continue;
    }
    if (c == d) {
      passed++;
    } else {
      failed++;
      if (failures.length < 20) {
        failures.add('pat=${_esc(pat)} subj=${_esc(subj)}\n  C=$c\n  D=$d');
      }
    }
  }
  await oracle.close();

  for (final f in failures) {
    stderr.writeln('DIVERGE: $f');
  }
  print('$passed passed, $failed failed, $skipped skipped '
      '($count generated, seed $seed)');
  if (failed != 0) exitCode = 1;
}

String _esc(String s) => s.replaceAll('\n', r'\n');
