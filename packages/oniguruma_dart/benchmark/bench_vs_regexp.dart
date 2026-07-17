/// Dart-vs-Dart benchmark: this port's `OnigRegex` (pure-Dart backtracking VM)
/// vs the SDK's built-in `RegExp` (V8 Irregexp, native). Both run the SAME
/// patterns over the SAME strings, in one process, via each engine's idiomatic
/// String API (`allMatches`). The harness verifies both engines find the same
/// number of matches before timing, so every row compares equal work.
///
/// Build once and run (AOT, fairest): from the package root,
///   dart compile exe benchmark/bench_vs_regexp.dart -o benchmark/bench_vs_regexp
///   benchmark/bench_vs_regexp
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:oniguruma_dart/oniguruma_dart.dart';

const trials = 4;
const minMatchMs = 250; // per timed run
const minCompileMs = 200;

class Case {
  final String label, category, onigPat, rePat, corpus;
  final bool ignoreCase;
  const Case(
    this.label,
    this.category,
    this.onigPat,
    this.rePat, {
    this.corpus = 'ascii',
    this.ignoreCase = false,
  });
}

const cases = <Case>[
  Case('literal', 'literal', 'lorem', 'lorem'),
  Case('literal-unicode', 'literal', '東京', '東京', corpus: 'uni'),
  Case(
    'alt-5',
    'alternation',
    'lorem|ipsum|dolor|sit|amet',
    'lorem|ipsum|dolor|sit|amet',
  ),
  Case('class-lower', 'char-class', '[a-z]+', '[a-z]+'),
  Case('class-digit', 'char-class', '[0-9]+', '[0-9]+'),
  Case('word-w', 'class/quant', r'\w+', r'\w+'),
  Case('two-words', 'quantifier', '[a-z]+ [a-z]+', '[a-z]+ [a-z]+'),
  Case('word-boundary', 'anchor', r'\b\w{5}\b', r'\b\w{5}\b'),
  Case('email-like', 'quant/greedy', r'\w+@\w+', r'\w+@\w+'),
  Case('named-group', 'capture', '(?<w>[a-z]+)', '(?<w>[a-z]+)'),
  Case('case-insens', 'case-fold', 'lorem', 'lorem', ignoreCase: true),
  Case('backref-dup', 'back-reference', r'(\w+) \1', r'(\w+) \1'),
  Case('greedy-dotstar', 'greedy .*', '.*lorem', '.*lorem'),
];

int _countOnig(OnigRegex r, String t) {
  var n = 0;
  for (final _ in r.allMatches(t)) {
    n++;
  }
  return n;
}

/// Run [f] repeatedly for at least [minMs], return ns per call. [sink] guards
/// against dead-code elimination.
double _nsPerCall(int minMs, int Function() f) {
  var iters = 0, sink = 0;
  final sw = Stopwatch()..start();
  do {
    sink += f();
    iters++;
  } while (sw.elapsedMilliseconds < minMs);
  sw.stop();
  if (sink == -1) stdout.write(''); // never true; keeps `sink` live
  return sw.elapsedMicroseconds * 1000.0 / iters;
}

double _median(List<double> xs) {
  xs.sort();
  final n = xs.length;
  return n.isOdd ? xs[n ~/ 2] : (xs[n ~/ 2 - 1] + xs[n ~/ 2]) / 2;
}

double _medianOf(int minMs, int Function() f) =>
    _median([for (var i = 0; i < trials; i++) _nsPerCall(minMs, f)]);

String _fmt(double ns) => ns >= 1e6
    ? '${(ns / 1e6).toStringAsFixed(2)}ms'
    : ns >= 1e3
    ? '${(ns / 1e3).toStringAsFixed(1)}µs'
    : '${ns.toStringAsFixed(0)}ns';

double _gmean(List<double> xs) {
  if (xs.isEmpty) return 0;
  var s = 0.0;
  for (final x in xs) {
    s += math.log(x);
  }
  return math.exp(s / xs.length);
}

void main() {
  final ascii = File('benchmark/datasets/corpus.txt').readAsStringSync();
  final uni = File('benchmark/datasets/unicode_corpus.txt').readAsStringSync();

  stdout.writeln(
    '# oniguruma_dart (OnigRegex) vs SDK RegExp — match throughput',
  );
  stdout.writeln(
    '# trials=$trials, adaptive timing (>= ${minMatchMs}ms/run)\n',
  );
  stdout.writeln(
    '| pattern | category | matches | RegExp | oniguruma_dart | onig / RegExp |',
  );
  stdout.writeln('|---|---|--:|--:|--:|--:|');

  final matchRatios = <double>[];
  final compileRatios = <double>[];
  final compileRows = <String>[];

  for (final c in cases) {
    final text = c.corpus == 'uni' ? uni : ascii;
    final og = OnigRegex.compile(c.onigPat, ignoreCase: c.ignoreCase);
    final re = RegExp(c.rePat, caseSensitive: !c.ignoreCase);

    final on = _countOnig(og, text);
    final rn = re.allMatches(text).length;
    final agree = on == rn;

    // warm up both engines
    for (var i = 0; i < 3; i++) {
      _countOnig(og, text);
      re.allMatches(text).length;
    }

    final reNs = _medianOf(minMatchMs, () => re.allMatches(text).length);
    final ogNs = _medianOf(minMatchMs, () => _countOnig(og, text));
    final ratio = ogNs / reNs;
    matchRatios.add(ratio);

    stdout.writeln(
      '| ${c.label} | ${c.category} | ${agree ? on : "$on≠$rn ⚠"} '
      '| ${_fmt(reNs)} | ${_fmt(ogNs)} | ${ratio.toStringAsFixed(1)}× |',
    );
    // machine-parseable full-precision line: RAW <label> <matches> <agree> <reNs> <ogNs>
    stdout.writeln(
      'RAW\t${c.label}\t$on\t$agree\t${reNs.toStringAsFixed(1)}'
      '\t${ogNs.toStringAsFixed(1)}',
    );

    // compile time: onig compiles eagerly; force RegExp to compile via a match.
    final ogc = _medianOf(
      minCompileMs,
      () => OnigRegex.compile(c.onigPat, ignoreCase: c.ignoreCase).hashCode,
    );
    final rec = _medianOf(minCompileMs, () {
      final r = RegExp(c.rePat, caseSensitive: !c.ignoreCase);
      return r.hasMatch('a') ? 1 : 0;
    });
    compileRatios.add(ogc / rec);
    compileRows.add(
      '| ${c.label} | ${_fmt(rec)} | ${_fmt(ogc)} '
      '| ${(ogc / rec).toStringAsFixed(1)}× |',
    );
  }

  stdout.writeln(
    '\n**geomean match onig / RegExp = ${_gmean(matchRatios).toStringAsFixed(1)}× '
    '· median = ${_median([...matchRatios]).toStringAsFixed(1)}×**',
  );

  stdout.writeln('\n## Compile time (construct + first use)\n');
  stdout.writeln('| pattern | RegExp | oniguruma_dart | onig / RegExp |');
  stdout.writeln('|---|--:|--:|--:|');
  for (final r in compileRows) {
    stdout.writeln(r);
  }
  stdout.writeln(
    '\n**geomean compile onig / RegExp = ${_gmean(compileRatios).toStringAsFixed(1)}×**',
  );
}
