/// Decomposes the String-API cost of the port to prove where the time goes.
///
/// For a fixed pattern+corpus it times, in isolation:
///   [encode]  utf8.encode(input)                         (String -> bytes)
///   [c2b]     build the dense code-unit->byte List<int>  (one runes pass)
///   [b2c]     build the byte->code-unit Map<int,int>     (one runes pass)  <-- suspected killer
///   [match]   the raw byte-API onigSearch scan loop over the prebuilt bytes
///   [strAPI]  OnigRegex.allMatches(input) end-to-end     (encode+maps+match+result)
///   [regexp]  RegExp.allMatches(input)                   (reference)
///
/// Run:  dart compile exe benchmark/bench_stringapi_breakdown.dart -o /tmp/bd && /tmp/bd
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:oniguruma_dart/oniguruma_dart.dart';

int _utf8Len(int rune) => rune < 0x80
    ? 1
    : rune < 0x800
        ? 2
        : rune < 0x10000
            ? 3
            : 4;

double _timeMs(int minMs, void Function() f) {
  var iters = 0;
  final sw = Stopwatch()..start();
  do {
    f();
    iters++;
  } while (sw.elapsedMilliseconds < minMs);
  sw.stop();
  return sw.elapsedMicroseconds / 1000.0 / iters;
}

void main() {
  final input = File('benchmark/datasets/corpus.txt').readAsStringSync();
  final asciiOnly = input.codeUnits.every((c) => c < 0x80);
  stdout.writeln('corpus: ${input.length} code units, '
      'ascii-only=$asciiOnly\n');

  // --- component: encode ---
  final encMs = _timeMs(300, () {
    final b = Uint8List.fromList(utf8.encode(input));
    if (b.length == -1) stdout.write('');
  });

  // --- component: build c2b dense List<int> (faithful copy of _Utf8Index) ---
  final c2bMs = _timeMs(300, () {
    final c2b = List<int>.filled(input.length + 1, 0);
    var bytePos = 0, cu = 0;
    for (final rune in input.runes) {
      final rb = _utf8Len(rune);
      final ru = rune > 0xffff ? 2 : 1;
      for (var k = 0; k < ru; k++) {
        c2b[cu + k] = bytePos;
      }
      bytePos += rb;
      cu += ru;
    }
    c2b[cu] = bytePos;
    if (c2b.length == -1) stdout.write('');
  });

  // --- component: build b2c Map<int,int> (faithful copy of _Utf8Index) ---
  final b2cMs = _timeMs(300, () {
    final b2c = <int, int>{};
    var bp = 0, c = 0;
    for (final rune in input.runes) {
      b2c[bp] = c;
      bp += _utf8Len(rune);
      c += rune > 0xffff ? 2 : 1;
    }
    b2c[bp] = c;
    if (b2c.length == -1) stdout.write('');
  });

  // --- component: raw byte-API scan (bytes prebuilt, no maps) ---
  final pat = 'lorem';
  final pb = Uint8List.fromList(utf8.encode(pat));
  final reg = onigNew(pb, pb.length, utf8Encoding, onigSyntaxDefault, 0);
  final bytes = Uint8List.fromList(utf8.encode(input));
  final end = bytes.length;
  final matchMs = _timeMs(300, () {
    var start = 0, count = 0;
    final region = OnigRegion();
    while (start <= end) {
      final r = onigSearch(reg, bytes, end, start, end, region);
      if (r < 0) break;
      count++;
      var next = region.end[0];
      if (next == start) next++;
      start = next;
    }
    if (count == -1) stdout.write('');
  });

  // --- end-to-end String API ---
  final og = OnigRegex.compile(pat);
  final strApiMs = _timeMs(300, () {
    var n = 0;
    for (final _ in og.allMatches(input)) {
      n++;
    }
    if (n == -1) stdout.write('');
  });

  // --- reference RegExp ---
  final re = RegExp(pat);
  final reMs = _timeMs(300, () {
    final n = re.allMatches(input).length;
    if (n == -1) stdout.write('');
  });

  String f(double ms) => '${ms.toStringAsFixed(2)}ms';
  stdout.writeln('pattern: "$pat"  (matches sparse over the corpus)\n');
  stdout.writeln('| component | time | note |');
  stdout.writeln('|---|--:|---|');
  stdout.writeln('| encode (String->UTF-8) | ${f(encMs)} | Uint8List.fromList(utf8.encode) |');
  stdout.writeln('| c2b dense List<int>    | ${f(c2bMs)} | code-unit -> byte, 1 runes pass |');
  stdout.writeln('| b2c Map<int,int>       | ${f(b2cMs)} | byte -> code-unit HASHMAP |');
  stdout.writeln('| match (byte API, no maps) | ${f(matchMs)} | onigSearch scan only |');
  stdout.writeln('| **String API end-to-end** | **${f(strApiMs)}** | encode+c2b+b2c+match+results |');
  stdout.writeln('| RegExp (reference)     | ${f(reMs)} | native, zero setup |');
  final setup = encMs + c2bMs + b2cMs;
  stdout.writeln('\nsetup (encode+c2b+b2c) = ${f(setup)} '
      '= ${(setup / strApiMs * 100).toStringAsFixed(0)}% of String-API time');
  stdout.writeln('match alone = ${f(matchMs)} '
      '= ${(matchMs / strApiMs * 100).toStringAsFixed(0)}% of String-API time');
}
