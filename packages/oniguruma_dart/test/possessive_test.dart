/// Regression tests for auto-possessification (`compiler.dart`
/// `_markPossessiveStars`): a greedy single-item loop `X*`/`X+` is made
/// possessive only when the following atom's first byte can't be an `X`. The
/// results must be UNCHANGED — this only removes futile give-backs. The critical
/// safety cases are the ones that must NOT be possessified (follower overlaps the
/// class), where a give-back is still required for a correct match.
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
  return rc < 0 ? null : (region.beg[0], region.end[0]);
}

void main() {
  group('possessified loops (disjoint follower) still match correctly', () {
    test(r'\w+@\w+ matches an email-like token', () {
      expect(_m(r'\w+@\w+', 'me@host'), (0, 7));
      expect(_m(r'\w+@\w+', 'no at sign'), isNull);
    });
    test(r'[a-z]+ [a-z]+ matches two words', () {
      expect(_m(r'[a-z]+ [a-z]+', 'foo bar'), (0, 7));
    });
    test(r'(\w+) \1 matches a doubled word, not a non-doubled one', () {
      expect(_m(r'(\w+) \1', 'hello hello'), (0, 11));
      expect(_m(r'(\w+) \1', 'hello world'), isNull);
      expect(_m(r'(\w+) \1', 'the the end'), (0, 7));
    });
    test(r'[a-z]+ at end takes the whole run', () {
      expect(_m(r'[a-z]+', 'abcXYZ'), (0, 3));
    });
  });

  group('NON-possessified loops (overlapping follower) still backtrack', () {
    test(r'[a-z]+x needs a give-back (x is in [a-z])', () {
      // greedy [a-z]+ eats "aax", backs off one so the literal x matches
      expect(_m(r'[a-z]+x', 'aax'), (0, 3));
      expect(_m(r'[a-z]+x', 'aaax'), (0, 4));
      expect(_m(r'[a-z]+x', 'aaa'), isNull);
    });
    test(r'\w+\w needs a give-back', () {
      expect(_m(r'\w+\w', 'ab'), (0, 2));
      expect(_m(r'\w+\w', 'a'), isNull);
    });
    test(r'(\w+)(x) splits so the second group can match', () {
      final pb = Uint8List.fromList(utf8.encode(r'(\w+)(x)'));
      final r = onigNew(pb, pb.length, utf8Encoding, onigSyntaxOniguruma, 0);
      final sb = Uint8List.fromList(utf8.encode('aax'));
      final region = OnigRegion();
      expect(
        onigSearch(r, sb, sb.length, 0, sb.length, region),
        greaterThanOrEqualTo(0),
      );
      expect([region.beg[1], region.end[1]], [0, 2]); // group 1 = "aa"
      expect([region.beg[2], region.end[2]], [2, 3]); // group 2 = "x"
    });
    test(r'.*x backtracks (anychar overlaps everything)', () {
      expect(_m(r'.*x', 'axbxc'), (0, 4)); // greedy .* then last x
    });
  });
}
