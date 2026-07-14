/// Regression tests for the Op.peekByte alternation quick-check: it must skip a
/// branch only when the current byte provably can't begin it, and must NEVER
/// skip a branch that could match (nullable heads, negated classes, ctypes).
/// The oracle + fuzzer cover this broadly; these pin the tricky cases.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:oniguruma_dart/src/encoding/encodings.dart';
import 'package:oniguruma_dart/src/region.dart';
import 'package:oniguruma_dart/src/regex.dart';
import 'package:oniguruma_dart/src/syntax.dart';
import 'package:oniguruma_dart/src/exec/search.dart';
import 'package:test/test.dart';

(int, int)? _m(String pat, String subj) {
  final pb = Uint8List.fromList(utf8.encode(pat));
  final r = onigNew(pb, pb.length, utf8Encoding, onigSyntaxOniguruma, 0);
  final sb = Uint8List.fromList(utf8.encode(subj));
  final region = OnigRegion();
  final rc = onigSearch(r, sb, sb.length, 0, sb.length, region);
  if (rc < 0) return null;
  return (region.beg[0], region.end[0]);
}

void main() {
  group('alternation quick-check still matches every branch', () {
    test('literal alternation picks the right branch', () {
      expect(_m('lorem|ipsum|dolor|sit|amet', 'xx amet yy'), (3, 7));
      expect(_m('lorem|ipsum|dolor|sit|amet', 'the ipsum'), (4, 9));
      expect(_m('lorem|ipsum|dolor|sit|amet', 'nope'), isNull);
    });

    test('multibyte branches match on lead byte', () {
      expect(_m('東|京|foo', 'a京b'), (1, 4)); // 京 at byte 1..4
      expect(_m('東|京|foo', 'zfoo'), (1, 4));
    });
  });

  group('branches that must NOT be skipped by the peek', () {
    test('nullable head branch (a?)b matches a bare b', () {
      // (a?)b : first byte can be a OR b — the helper must decline the peek.
      expect(_m(r'(a?)b|xyz', 'zzb'), (2, 3));
      expect(_m(r'(a?)b|xyz', 'ab'), (0, 2));
    });

    test('negated-class branch [^a] is not filtered', () {
      expect(_m(r'[^a]|b', 'a'), isNull); // only 'a' present -> [^a] can't, no b
      expect(_m(r'[^a]|b', 'ax'), (1, 2)); // 'x' matches [^a]
      expect(_m(r'[^a]|b', 'ab'), (1, 2)); // 'b' matches [^a] (b != a)
    });

    test('ctype branch \\w+ is not filtered', () {
      expect(_m(r'\w+|!!', '   hi'), (3, 5));
      expect(_m(r'\w+|!!', '!!'), (0, 2));
    });

    test('empty branch is never skipped (matches at any position)', () {
      // a|  : the empty second branch matches everywhere; at 'z' the whole
      // alternation matches empty at 0.
      expect(_m(r'a|', 'zzz'), (0, 0));
      expect(_m(r'a|', 'ba'), (0, 0));
    });
  });

  group('backtracking into a peeked branch', () {
    test('branch whose first byte matches but body fails falls through', () {
      // 'lorem' vs 'lorxx': peek passes on 'l', branch fails mid-way; no other
      // branch starts with 'l', so overall fail.
      expect(_m('lorem|ipsum', 'lorxx'), isNull);
      // but a real later occurrence still matches
      expect(_m('lorem|ipsum', 'lorxx ipsum'), (6, 11));
    });
  });
}
