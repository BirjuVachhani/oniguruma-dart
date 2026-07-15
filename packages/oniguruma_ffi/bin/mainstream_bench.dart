/// Measures the native Oniguruma engine *as driven from Dart through this
/// package* on the canonical 13 "mainstream" patterns, over the exact same two
/// corpora as the pure-Dart port's benchmark — so the numbers drop straight
/// into `oniguruma_dart/benchmark/mainstream_results.json` alongside the C,
/// V8 and pure-Dart engines.
///
/// Two numbers per pattern, both "median ns to scan the whole corpus for every
/// non-overlapping match":
///
///   * per-match  — the package's real [OnigScanner.findNextMatch] API: one FFI
///                  crossing and one result object per match (what a consumer
///                  actually pays to enumerate matches from Dart).
///   * bulk       — [OnigScanner.scanCount]: the entire scan in a single FFI
///                  crossing, no per-match allocation (the native-from-Dart
///                  throughput ceiling, directly comparable to the C loop).
///
/// Built as an AOT bundle (so the native code asset is bundled, unlike a plain
/// `dart run`) and invoked by `oniguruma_dart/benchmark/ffi_bench.py`:
///   dart build cli -t bin/mainstream_bench.dart -o build/bench_ffi
///   build/bench_ffi/bundle/bin/mainstream_bench <ascii-corpus> <unicode-corpus>
///
/// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:oniguruma_ffi/oniguruma_ffi.dart';

const trials = 5;
const minMs = 250; // per timed run

// label, pattern, corpus — identical set to the pure-Dart mainstream benchmark.
const patterns = <(String, String, String)>[
  ('literal', 'lorem', 'ascii'),
  ('literal-unicode', '東京', 'uni'),
  ('alt-5', 'lorem|ipsum|dolor|sit|amet', 'ascii'),
  ('class-lower', '[a-z]+', 'ascii'),
  ('class-digit', '[0-9]+', 'ascii'),
  ('word-w', r'\w+', 'ascii'),
  ('two-words', '[a-z]+ [a-z]+', 'ascii'),
  ('word-boundary', r'\b\w{5}\b', 'ascii'),
  ('email-like', r'\w+@\w+', 'ascii'),
  ('named-group', '(?<w>[a-z]+)', 'ascii'),
  ('case-insens', '(?i)lorem', 'ascii'),
  ('backref-dup', r'(\w+) \1', 'ascii'),
  ('greedy-dotstar', '.*lorem', 'ascii'),
];

/// Counts all non-overlapping matches by walking the scanner's per-match API,
/// exactly as a consumer enumerating matches from Dart would.
int _perMatchScan(OnigScanner sc, OnigString s) {
  var start = 0, n = 0;
  while (true) {
    final m = sc.findNextMatch(s, start);
    if (m == null) break;
    n++;
    final e = m.captureIndices[0].end;
    start = e > start ? e : start + 1;
  }
  return n;
}

/// Run [f] for at least [minMs], return ns per call. [sink] blocks DCE.
double _nsPerCall(int Function() f) {
  var iters = 0, sink = 0;
  final sw = Stopwatch()..start();
  do {
    sink += f();
    iters++;
  } while (sw.elapsedMilliseconds < minMs);
  sw.stop();
  if (sink == -1) stdout.write(''); // never true; keeps sink live
  return sw.elapsedMicroseconds * 1000.0 / iters;
}

double _median(List<double> xs) {
  xs.sort();
  final n = xs.length;
  return n.isOdd ? xs[n ~/ 2] : (xs[n ~/ 2 - 1] + xs[n ~/ 2]) / 2;
}

double _medianOf(int Function() f) =>
    _median([for (var i = 0; i < trials; i++) _nsPerCall(f)]);

String _fmt(double ns) => ns >= 1e6
    ? '${(ns / 1e6).toStringAsFixed(2)}ms'
    : ns >= 1e3
        ? '${(ns / 1e3).toStringAsFixed(1)}µs'
        : '${ns.toStringAsFixed(0)}ns';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: bench_ffi <ascii-corpus> <unicode-corpus>');
    exit(2);
  }
  final ascii = File(args[0]).readAsStringSync();
  final uni = File(args[1]).readAsStringSync();

  print('# oniguruma_ffi (native Oniguruma via FFI) — mainstream benchmark');
  print('# ${onigVersion()}  ·  trials=$trials, adaptive (>= ${minMs}ms/run)\n');
  print('| pattern | matches | per-match (findNextMatch) | bulk (scanCount) |');
  print('|---|--:|--:|--:|');

  for (final (label, pat, corpus) in patterns) {
    final text = corpus == 'uni' ? uni : ascii;
    final sc = OnigScanner([pat]);
    final s = OnigString(text);

    // Cross-check the two paths agree on the match count before timing.
    final cPer = _perMatchScan(sc, s);
    final cBulk = sc.scanCount(s);
    final agree = cPer == cBulk;

    // warm up both paths
    for (var i = 0; i < 3; i++) {
      _perMatchScan(sc, s);
      sc.scanCount(s);
    }

    final perNs = _medianOf(() => _perMatchScan(sc, s));
    final bulkNs = _medianOf(() => sc.scanCount(s));

    print('| $label | ${agree ? cPer : "$cPer≠$cBulk ⚠"} '
        '| ${_fmt(perNs)} | ${_fmt(bulkNs)} |');
    // machine-parseable: RAW <label> <matches> <perMatchNs> <bulkNs>
    print('RAW\t$label\t$cPer\t${perNs.toStringAsFixed(1)}'
        '\t${bulkNs.toStringAsFixed(1)}');

    s.dispose();
    sc.dispose();
  }
}
