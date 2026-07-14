/// Tests for the search-start optimizer (lib/src/compile/optimize.dart): which
/// prefilter (`Optimize.str`/`map`, the `.*` anchor) each pattern gets.
///
/// The oracle validates *results*, not *strategy*, so a pattern that silently
/// loses its prefilter (as `(?i)…` literals once did — matching correctly but
/// scanning every position) passes the oracle yet regresses badly. These tests
/// pin the strategy so such regressions fail loudly.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:oniguruma_dart/src/encoding/encodings.dart';
import 'package:oniguruma_dart/src/exec/search.dart';
import 'package:oniguruma_dart/src/onig_types.dart';
import 'package:oniguruma_dart/src/region.dart';
import 'package:oniguruma_dart/src/regex.dart';
import 'package:oniguruma_dart/src/syntax.dart';
import 'package:test/test.dart';

Regex _c(String pat) {
  final pb = Uint8List.fromList(utf8.encode(pat));
  return onigNew(pb, pb.length, utf8Encoding, onigSyntaxOniguruma, 0);
}

int _find(Regex r, String subj) {
  final sb = Uint8List.fromList(utf8.encode(subj));
  return onigSearch(r, sb, sb.length, 0, sb.length, OnigRegion());
}

void main() {
  group('prefilter selection', () {
    test('plain literal → Optimize.str with exact bytes + BMH skip table', () {
      final r = _c('lorem');
      expect(r.optimize, Optimize.str);
      expect(r.exact, utf8.encode('lorem'));
      expect(r.exactSkip, isNotNull);
    });

    test('char class → Optimize.map', () {
      expect(_c('[a-z]+').optimize, Optimize.map);
    });

    test('undeterminable prefix (optional lead) → Optimize.none', () {
      expect(_c(r'\w*').optimize, Optimize.none);
    });

    test('leading .* + required literal → exact + anychar-inf anchor', () {
      final r = _c('.*lorem');
      expect(r.optimize, Optimize.str);
      expect(r.exact, utf8.encode('lorem'));
      expect(r.exactAnchorAnyChar, isTrue);
    });
  });

  // Regression guard for the case-insensitive prefilter: `(?i)…` literals must
  // get a first-byte map over the leading char's fold class, not fall back to
  // scanning every position.
  group('case-insensitive first-byte map', () {
    test('(?i)lorem → map over {l, L}, excludes others', () {
      final r = _c('(?i)lorem');
      expect(r.optimize, Optimize.map, reason: 'must prefilter, not scan all');
      final m = r.map!;
      expect(m[0x6c], 1, reason: 'l'); // l
      expect(m[0x4c], 1, reason: 'L'); // L
      expect(m[0x7a], 0, reason: 'z must not be in the set');
      expect(m[0x61], 0, reason: 'a must not be in the set');
    });

    test('(?i)ABC → map includes both cases of the lead char', () {
      final m = _c('(?i)ABC').map!;
      expect(m[0x41], 1); // A
      expect(m[0x61], 1); // a
    });

    test('(?i)(group) unwraps to the inner literal', () {
      final r = _c('(?i)(lorem)');
      expect(r.optimize, Optimize.map);
      expect(r.map![0x4c], 1); // L
    });

    test('lead char with a multi-char fold (ß≡ss) bails safely to none', () {
      // A match could start with `s`, which the single-code-point fold class
      // doesn't capture, so no (incomplete) map is built.
      expect(_c('(?i)ße').optimize, Optimize.none);
    });

    test('map prefilter does not break case-insensitive matching', () {
      final r = _c('(?i)lorem');
      expect(r.optimize, Optimize.map);
      for (final s in ['lorem', 'LOREM', 'Lorem', 'lOrEm']) {
        expect(_find(r, 'zz${s}zz'), greaterThanOrEqualTo(0), reason: s);
      }
      expect(_find(r, 'no such word here'), lessThan(0));
    });
  });
}
