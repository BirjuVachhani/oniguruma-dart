/// GNU regex API adapter (`reggnu.c`), mapped to Dart.
///
/// Mirrors `onig_new`/`re_search`/`re_match` semantics over the core engine
/// using the GNU-regex syntax. For 1:1 API parity; idiomatic callers use
/// `OnigRegex`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'encoding/utf8.dart';
import 'exec/search.dart';
import 'onig_types.dart';
import 'region.dart';
import 'regex.dart';
import 'syntax.dart';

/// Compile [pattern] with the GNU-regex syntax (`re_compile_pattern`).
Regex reCompilePattern(String pattern, {OnigSyntax? syntax}) {
  final pb = Uint8List.fromList(utf8.encode(pattern));
  return onigNew(
    pb,
    pb.length,
    utf8Encoding,
    syntax ?? onigSyntaxGnuRegex,
    OnigOption.none,
  );
}

/// `re_search` — search [str] in `[start, start+range]` for [reg]. Returns the
/// match start byte offset, or -1 (no match). Fills [region] if provided.
int reSearch(
  Regex reg,
  Uint8List str,
  int size,
  int start,
  int range,
  OnigRegion? region,
) {
  final rangeEnd = (start + range).clamp(0, size);
  return onigSearch(reg, str, size, start, rangeEnd, region);
}

/// `re_match` — anchored match of [reg] at [at]. Returns the matched byte
/// length, or -1.
int reMatch(Regex reg, Uint8List str, int size, int at, OnigRegion? region) {
  return onigMatch(reg, str, size, at, region);
}
