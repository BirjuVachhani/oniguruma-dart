/// Targeted differential fuzz for the leading-`\b` word-start search skip
/// (`reg.leadingWordBoundary`). The generic fuzzer never emits `\b`, so this one
/// generates only LINEAR `\b`-led patterns (no nested quantifiers ⇒ no
/// catastrophic backtracking ⇒ the C oracle can't hang) and asserts
/// byte-identical results against the C reference CLI over random subjects.
///
///   dart run test/differential/fuzz_wordb.dart [count] [seed] [cli]
library;

import 'dart:io';

import 'diff_util.dart';

const _bodies = [
  r'\w',
  r'\w\w',
  r'\w\w\w',
  r'\w{3}',
  r'\w{5}',
  r'\w+',
  r'\w*',
  r'\w{2,4}',
  '[a-z]+',
  '[a-z]',
  'abc',
  'xy',
  '[0-9]+',
  r'\w+\b\w',
  'a',
  r'\d+',
];
const _lead = [r'\b', r'\b', r'\b', r'\B', r'^\b', r'\b']; // mostly \b
const _tail = ['', '', r'\b', r'\b', r'\B', '', '\$'];

String _genPattern(_Rng r) {
  var p = _lead[r.next(_lead.length)];
  p += _bodies[r.next(_bodies.length)];
  p += _tail[r.next(_tail.length)];
  if (r.next(4) == 0) p = '(?i)$p';
  return p;
}

const _alpha = 'abcXYZ_012 .,-!\t\nqrs';
String _genSubject(_Rng r) {
  final n = r.next(22);
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    sb.write(_alpha[r.next(_alpha.length)]);
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
  final count = argv.isNotEmpty ? int.parse(argv[0]) : 4000;
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
  print(
    '$passed passed, $failed failed, $skipped skipped '
    '($count generated, seed $seed)',
  );
  if (failed != 0) exitCode = 1;
}

String _esc(String s) => s.replaceAll('\n', r'\n').replaceAll('\t', r'\t');
