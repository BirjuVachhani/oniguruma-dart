// Example usage of oniguruma_dart, a pure-Dart port of the Oniguruma regex
// engine. Shows the idiomatic String API (recommended) and the low-level byte
// API (mirrors the C library, operating on Uint8List with byte offsets).
import 'dart:convert';
import 'dart:typed_data';

import 'package:oniguruma_dart/oniguruma_dart.dart';

void main() {
  // ---- Idiomatic String API ------------------------------------------------
  final re = OnigRegex.compile(r'(?<user>\w+)@(?<host>[\w.]+)');

  final m = re.firstMatch('contact bob@acme.com today');
  print(m?.group(0)); // bob@acme.com
  print(m?.namedGroup('user')); // bob
  print(m?.namedGroup('host')); // acme.com
  print(m?.start); // 8  (UTF-16 code-unit offset)

  // allMatches / replaceAll
  print(
    OnigRegex.compile(
      r'\d+',
    ).allMatches('a1 b22 c333').map((x) => x.group(0)).toList(),
  ); // [1, 22, 333]
  print(OnigRegex.compile(r'\s+').replaceAll('a  b   c', (_) => '_')); // a_b_c

  // Unicode-aware: properties, and case-insensitive multi-char folds (ß ↔ ss).
  print(OnigRegex.compile(r'\p{Han}+').firstMatch('東京タワー')?.group(0)); // 東京
  print(OnigRegex.compile(r'(?i)straße').firstMatch('STRASSE') != null); // true

  // ---- Low-level byte API (mirrors the C library) --------------------------
  final pattern = Uint8List.fromList(utf8.encode(r'a(.*)b|[e-f]+'));
  final subject = Uint8List.fromList(utf8.encode('zzzzaffffffffb'));

  final reg = onigNew(
    pattern,
    pattern.length,
    utf8Encoding,
    onigSyntaxDefault,
    OnigOption.defaultOption,
  );

  final region = OnigRegion();
  final start = onigSearch(
    reg,
    subject,
    subject.length,
    0,
    subject.length,
    region,
  );

  if (start >= 0) {
    print('match at byte $start');
    for (var i = 0; i < region.numRegs; i++) {
      print('  group $i: [${region.beg[i]}, ${region.end[i]})'); // byte offsets
    }
  } else if (start == OnigResult.mismatch) {
    print('no match');
  } else {
    print('error: ${onigErrorCodeToStr(start)}');
  }
}
