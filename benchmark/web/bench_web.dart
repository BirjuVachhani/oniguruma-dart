/// Web/JS benchmark: this port's `OnigRegex` (pure Dart, compiled to JS) vs the
/// SDK's built-in `RegExp` (which on the web delegates to the host JS engine's
/// native RegExp). Same 13 patterns, same corpora, same `allMatches` work as the
/// VM harness (benchmark/bench_vs_regexp.dart), so the two runs are comparable.
///
///   dart run benchmark/web/gen_corpus_data.dart          # once, embeds corpora
///   dart compile js benchmark/web/bench_web.dart -O2 -o benchmark/web/bench_web.js
///   node benchmark/web/bench_web.js
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:oniguruma_dart/oniguruma_dart.dart';

import 'corpus_data.g.dart';

const trials = 4;
const minMatchMs = 250; // per timed run

class Case {
  final String label, category, onigPat, rePat, corpus;
  final bool ignoreCase;
  const Case(this.label, this.category, this.onigPat, this.rePat,
      {this.corpus = 'ascii', this.ignoreCase = false});
}

// EXACTLY the cases from benchmark/bench_vs_regexp.dart, in the same order.
const cases = <Case>[
  Case('literal', 'literal', 'lorem', 'lorem'),
  Case('literal-unicode', 'literal', '東京', '東京', corpus: 'uni'),
  Case('alt-5', 'alternation', 'lorem|ipsum|dolor|sit|amet',
      'lorem|ipsum|dolor|sit|amet'),
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

double _nsPerCall(int minMs, int Function() f) {
  var iters = 0, sink = 0;
  final sw = Stopwatch()..start();
  do {
    sink += f();
    iters++;
  } while (sw.elapsedMilliseconds < minMs);
  sw.stop();
  _sinkGuard += sink;
  return sw.elapsedMicroseconds * 1000.0 / iters;
}

int _sinkGuard = 0;

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
  final ascii = utf8.decode(base64.decode(asciiB64));
  final uni = utf8.decode(base64.decode(uniB64));

  print('# oniguruma_dart (OnigRegex) vs SDK RegExp on WEB (dart2js @ Node/V8)');
  print('# trials=$trials, adaptive timing (>= ${minMatchMs}ms/run)\n');
  print('| pattern | category | matches | RegExp | oniguruma_dart | onig / RegExp |');
  print('|---|---|--:|--:|--:|--:|');

  final matchRatios = <double>[];
  for (final c in cases) {
    final text = c.corpus == 'uni' ? uni : ascii;
    final og = OnigRegex.compile(c.onigPat, ignoreCase: c.ignoreCase);
    final re = RegExp(c.rePat, caseSensitive: !c.ignoreCase);

    final on = _countOnig(og, text);
    final rn = re.allMatches(text).length;
    final agree = on == rn;

    for (var i = 0; i < 3; i++) {
      _countOnig(og, text);
      re.allMatches(text).length;
    }

    final reNs = _medianOf(minMatchMs, () => re.allMatches(text).length);
    final ogNs = _medianOf(minMatchMs, () => _countOnig(og, text));
    final ratio = ogNs / reNs;
    matchRatios.add(ratio);

    print('| ${c.label} | ${c.category} | ${agree ? on : "$on≠$rn ⚠"} '
        '| ${_fmt(reNs)} | ${_fmt(ogNs)} | ${ratio.toStringAsFixed(1)}× |');
    // machine-parseable full-precision line: RAW <label> <matches> <agree> <reNs> <ogNs>
    print('RAW\t${c.label}\t$on\t$agree\t${reNs.toStringAsFixed(1)}'
        '\t${ogNs.toStringAsFixed(1)}');
  }

  print('\n**geomean match onig / RegExp = ${_gmean(matchRatios).toStringAsFixed(1)}× '
      '· median = ${_median([...matchRatios]).toStringAsFixed(1)}×**');
  print('// checksum=$_sinkGuard');
}
