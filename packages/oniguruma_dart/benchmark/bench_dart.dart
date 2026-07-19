/// Dart-side benchmark harness: mirrors `benchmark/c/onig_cli` exactly so the
/// two are directly comparable (same encoding, syntax, options, and scan loop).
///
/// Two modes:
///   `bench   <pattern> <file> <iters>`   compile once, scan whole subject for
///                                        all matches; ns per scan.
///   `compile <pattern> <iters>`          compile the pattern N times; ns/compile.
///
///   dart run benchmark/bench_dart.dart bench   '[a-z]+' corpus.txt 50
///   dart run benchmark/bench_dart.dart compile '[a-z]+' 100000
/// (or AOT: `dart compile exe benchmark/bench_dart.dart -o benchmark/bench_dart`)
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:oniguruma_dart/oniguruma_dart.dart';

final _enc = utf8Encoding;
final _syntax = onigSyntaxDefault;
const _option = OnigOption.defaultOption;

void _benchMode(String pat, String file, int iters) {
  final pattern = Uint8List.fromList(utf8.encode(pat));
  final subject = File(file).readAsBytesSync();
  final end = subject.length;

  final reg = onigNew(pattern, pattern.length, _enc, _syntax, _option);
  final region = OnigRegion();

  var totalMatches = 0;
  final sw = Stopwatch()..start();
  for (var it = 0; it < iters; it++) {
    var start = 0;
    var count = 0;
    while (start <= end) {
      final r = onigSearch(reg, subject, end, start, end, region);
      if (r < 0) break;
      count++;
      var next = region.end[0];
      if (next == start) next++; // zero-width: advance one byte
      start = next;
    }
    totalMatches = count;
  }
  sw.stop();
  final totalNs = sw.elapsedMicroseconds * 1000.0;
  stdout.writeln(
    '$totalMatches matches, '
    '${(totalNs / iters).toStringAsFixed(1)} ns/search-scan, '
    '${(totalNs / 1e6).toStringAsFixed(2)} ms total ($iters iters)',
  );
}

void _compileMode(String pat, int iters) {
  final pattern = Uint8List.fromList(utf8.encode(pat));
  // warm up + validate once
  onigNew(pattern, pattern.length, _enc, _syntax, _option);

  final sw = Stopwatch()..start();
  for (var it = 0; it < iters; it++) {
    onigNew(pattern, pattern.length, _enc, _syntax, _option);
  }
  sw.stop();
  final totalNs = sw.elapsedMicroseconds * 1000.0;
  stdout.writeln(
    'compiled, '
    '${(totalNs / iters).toStringAsFixed(1)} ns/compile, '
    '${(totalNs / 1e6).toStringAsFixed(2)} ms total ($iters iters)',
  );
}

void main(List<String> argv) {
  if (argv.isNotEmpty && argv[0] == 'bench') {
    if (argv.length < 4) {
      stderr.writeln('usage: bench_dart bench <pattern> <file> <iters>');
      exit(2);
    }
    _benchMode(argv[1], argv[2], int.parse(argv[3]));
  } else if (argv.isNotEmpty && argv[0] == 'compile') {
    if (argv.length < 3) {
      stderr.writeln('usage: bench_dart compile <pattern> <iters>');
      exit(2);
    }
    _compileMode(argv[1], int.parse(argv[2]));
  } else {
    stderr.writeln('usage: bench_dart bench|compile ...');
    exit(2);
  }
}
