/// Differential fuzz for the `C+ exact…` walk-back optimization vs the C CLI.
/// Generates linear `C+ L R…` patterns (no catastrophic backtracking → the C
/// oracle can't hang) and asserts byte-identical results over random subjects.
///
///   dart run test/differential/fuzz_exactback.dart [count] [seed] [cli]
library;

import 'dart:io';

import 'diff_util.dart';

const _pats = [
  r'\w+@\w+', r'\w+@\w+@\w+', r'[a-z]+:[a-z]+', r'\d+\.\d+', r'\w+@\d+',
  r'\w+-\w+', r'[a-z]+/[a-z]+', r'\w+\.\w+\.\w+', r'\d+:\d+', r'[a-zA-Z]+=\w+',
];

const _alpha = 'abcXY_09 @:.-/=\t!';
String _genSubject(_Rng r) {
  final n = r.next(26);
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
    final pat = _pats[rng.next(_pats.length)];
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
        failures.add('pat=$pat subj=${_esc(subj)}\n  C=$c\n  D=$d');
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

String _esc(String s) => s.replaceAll('\n', r'\n').replaceAll('\t', r'\t');
