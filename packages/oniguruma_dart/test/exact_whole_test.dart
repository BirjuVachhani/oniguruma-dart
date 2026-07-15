/// Regression tests for the pure-literal fast path (`regex.dart`
/// `exactWholeMatch`; `search.dart` Optimize.str direct region fill): when the
/// whole pattern is an exact literal, a Sunday hit IS the match and the driver
/// fills the region without running matchAt. Results must be byte-identical to
/// the verified path. The critical cases are the ones that must NOT take the
/// shortcut — a capture, a trailing anchor, or a whole-string option — where
/// matchAt is still required.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:oniguruma_dart/src/encoding/encodings.dart';
import 'package:oniguruma_dart/src/onig_types.dart';
import 'package:oniguruma_dart/src/region.dart';
import 'package:oniguruma_dart/src/regex.dart';
import 'package:oniguruma_dart/src/syntax.dart';
import 'package:oniguruma_dart/src/exec/search.dart';
import 'package:test/test.dart';

Regex _c(String pat) {
  final pb = Uint8List.fromList(utf8.encode(pat));
  return onigNew(pb, pb.length, utf8Encoding, onigSyntaxOniguruma, 0);
}

(int, int)? _m(String pat, String subj, {int option = 0}) {
  final r = _c(pat);
  final sb = Uint8List.fromList(utf8.encode(subj));
  final region = OnigRegion();
  final rc = onigSearch(r, sb, sb.length, 0, sb.length, region, option: option);
  return rc < 0 ? null : (region.beg[0], region.end[0]);
}

void main() {
  group('pure literal takes the fast path and is correct', () {
    test('flag is set only for a bare literal', () {
      expect(_c('lorem').exactWholeMatch, isTrue);
      expect(_c('(lorem)').exactWholeMatch, isFalse, reason: 'capture');
      expect(_c(r'lorem$').exactWholeMatch, isFalse, reason: 'trailing anchor');
      expect(_c(r'\blorem').exactWholeMatch, isFalse, reason: 'leading \\b');
      expect(_c('lorem+').exactWholeMatch, isFalse, reason: 'quantifier');
      expect(
        _c('lo.em').exactWholeMatch,
        isFalse,
        reason: 'not a pure literal',
      );
    });

    test('match offsets', () {
      expect(_m('lorem', 'lorem'), (0, 5));
      expect(_m('lorem', 'xx lorem yy'), (3, 8));
      expect(_m('lorem', 'no match here'), isNull);
      expect(_m('lorem', 'say lorem'), (4, 9)); // at end of buffer
      expect(_m('a', 'banana'), (1, 2));
    });

    test('multibyte literal', () {
      // "café" = 5 bytes (é is 2); at byte 3 it ends at byte 8.
      expect(_m('café', 'un café'), (3, 8));
    });
  });

  group('non-fast-path patterns still correct (matchAt used)', () {
    test('capture group fills group 1', () {
      final r = _c('(lorem)');
      final sb = Uint8List.fromList(utf8.encode('see lorem'));
      final region = OnigRegion();
      expect(
        onigSearch(r, sb, sb.length, 0, sb.length, region),
        greaterThanOrEqualTo(0),
      );
      expect([region.beg[0], region.end[0]], [4, 9]);
      expect([region.beg[1], region.end[1]], [4, 9]);
    });
    test(r'trailing $ requires end-of-line', () {
      expect(_m(r'lorem$', 'lorem'), (0, 5));
      expect(_m(r'lorem$', 'lorem x'), isNull);
    });
    test('MATCH_WHOLE_STRING option', () {
      expect(_m('lorem', 'lorem', option: OnigOption.matchWholeString), (0, 5));
      expect(
        _m('lorem', 'lorem yy', option: OnigOption.matchWholeString),
        isNull,
      );
    });
  });

  test('allMatches over the corpus finds the same count (via search loop)', () {
    // Sanity: repeated onigSearch (as allMatches does) over a small text yields
    // every non-overlapping occurrence with the fast path on.
    final r = _c('ab');
    final sb = Uint8List.fromList(utf8.encode('ab_ab_abab_a_ab'));
    final region = OnigRegion();
    var pos = 0, count = 0;
    while (pos <= sb.length) {
      final rc = onigSearch(r, sb, sb.length, pos, sb.length, region);
      if (rc < 0) break;
      count++;
      pos = region.end[0] > region.beg[0] ? region.end[0] : region.end[0] + 1;
    }
    expect(count, 5); // ab, ab, ab, ab, ab
  });
}
