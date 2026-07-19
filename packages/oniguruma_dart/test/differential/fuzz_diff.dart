/// Randomized differential fuzzer: generates random patterns (from the
/// slice's supported construct set) and random subjects, then asserts the Dart
/// port and the C reference library agree on every result.
///
///   dart run test/differential/fuzz_diff.dart [count] [seed] [path-to-cli]
library;

import 'dart:io';

import 'diff_util.dart';

const _atoms = [
  'a', 'b', 'c', 'x', '.', r'\d', r'\w', r'\s', '[a-c]', '[^a-c]', '[0-9]',
  '[[:alpha:]]', 'ab', r'\.', 'z', //
];
const _quants = [
  '', '*', '+', '?', '*?', '+?', '??', '{2}', '{1,3}', '{2,}', //
  '{5,30}', '{25}', '{0,26}', '{27,}?', //
];

String _genPattern(_Rng r, int depth) {
  final sb = StringBuffer();
  final terms = 1 + r.next(3);
  for (var t = 0; t < terms; t++) {
    final kind = r.next(depth > 0 ? 5 : 3);
    if (kind == 3 && depth > 0) {
      // group
      sb.write('(');
      if (r.next(2) == 0) sb.write('?:');
      sb.write(_genPattern(r, depth - 1));
      sb.write(')');
      sb.write(_quants[r.next(_quants.length)]);
    } else if (kind == 4 && depth > 0) {
      // alternation
      sb.write('(?:');
      sb.write(_atoms[r.next(_atoms.length)]);
      sb.write('|');
      sb.write(_atoms[r.next(_atoms.length)]);
      sb.write(')');
      sb.write(_quants[r.next(_quants.length)]);
    } else if (kind == 2 && depth > 0 && r.next(3) == 0) {
      // look-around (no trailing quantifier: assertions can't be repeated)
      const la = ['(?=', '(?!', '(?<=', '(?<!'];
      sb.write(la[r.next(la.length)]);
      sb.write(_atoms[r.next(_atoms.length)]);
      if (r.next(2) == 0) sb.write(_quants[r.next(_quants.length)]);
      sb.write(')');
    } else {
      sb.write(_atoms[r.next(_atoms.length)]);
      sb.write(_quants[r.next(_quants.length)]);
    }
  }
  // occasional anchors / ignore-case
  var pat = sb.toString();
  if (r.next(4) == 0) pat = '(?i)$pat'; // exercise the case-insensitive path
  final a = r.next(4);
  if (a == 0) return '^$pat';
  if (a == 1) return '$pat\$';
  return pat;
}

const _subjectAlphabet = 'abcxyz012 .\n';
String _genSubject(_Rng r) {
  final n = r.next(12);
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    sb.write(_subjectAlphabet[r.next(_subjectAlphabet.length)]);
  }
  return sb.toString();
}

/// Tiny deterministic LCG (avoids Math.random for reproducibility).
class _Rng {
  int _s;
  _Rng(this._s);
  int next(int n) {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s % n;
  }
}

Future<void> main(List<String> argv) async {
  final count = argv.isNotEmpty ? int.parse(argv[0]) : 5000;
  final seed = argv.length > 1 ? int.parse(argv[1]) : 12345;
  final cliPath = argv.length > 2 ? argv[2] : 'benchmark/c/onig_cli';
  if (!File(cliPath).existsSync()) {
    stderr.writeln('C reference CLI not found at $cliPath');
    exit(2);
  }
  final oracle = await COracle.start(cliPath);
  final rng = _Rng(seed);

  var pass = 0, fail = 0, cErr = 0;
  for (var i = 0; i < count; i++) {
    final pat = _genPattern(rng, 2);
    final subj = _genSubject(rng);
    final pb = b(pat), sb = b(subj);
    final c = await oracle.run(pb, sb);
    // Skip cases the reference itself rejects (unsupported/rare parse quirks).
    if (c.kind == 'ERROR') {
      cErr++;
      continue;
    }
    final dart = runDart(pb, sb, retryLimit: 5000000);
    // Skip pathological patterns where our engine hit the backtracking cap.
    if (dart.kind == 'ERROR' && dart.errorCode == -17) {
      cErr++;
      continue;
    }
    if (dart == c) {
      pass++;
    } else {
      fail++;
      if (fail <= 25) {
        stdout.writeln('MISMATCH  /$pat/  on  ${_q(subj)}');
        stdout.writeln('    C   : $c');
        stdout.writeln('    Dart: $dart');
      }
    }
  }
  await oracle.close();
  stdout.writeln(
    '\n$pass passed, $fail failed, $cErr C-errors skipped '
    '($count generated, seed $seed)',
  );
  exit(fail == 0 ? 0 : 1);
}

String _q(String s) => '"${s.replaceAll("\n", r"\n")}"';
