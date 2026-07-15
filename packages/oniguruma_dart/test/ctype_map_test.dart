/// Regression tests for the ctype/multibyte-class first-byte prefilter
/// (`optimize.dart` `_firstByteSet`). The map must be a COMPLETE over-approximation:
/// a match that begins with a non-ASCII char (whose UTF-8 lead byte is 0xC2..0xF4)
/// must NOT be skipped. A too-narrow map would silently drop such matches, so these
/// pin matches that begin at a Unicode position.
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
  return (region.beg[0], region.end[0]); // byte offsets
}

void main() {
  group('ctype first-byte map must not skip Unicode-starting matches', () {
    test(r'\w+ finds a run that begins at a CJK char after spaces', () {
      // leading spaces are skipped by the map; the match starts at 日 (lead 0xE6)
      expect(_m(r'\w+', '   日本語'), isNotNull);
      final m = _m(r'\w+', '   日本語')!;
      expect(m.$1, 3); // byte offset of 日 (3 spaces)
    });

    test(r'\w+ begins at a Latin-1 letter (2-byte lead 0xC3)', () {
      expect(_m(r'\w+', '  élan'), isNotNull);
      expect(_m(r'\w+', '  élan')!.$1, 2);
    });

    test(r'\d+ finds Arabic-Indic digits (Unicode \d member)', () {
      // ٥٦ = U+0665 U+0666 (lead 0xD9); preceded by non-digits
      expect(_m(r'\d+', 'ab٥٦'), isNotNull);
    });

    test(r'\s+ finds a Unicode space (ideographic space U+3000)', () {
      expect(_m(r'\s+', 'x　y'), isNotNull); // U+3000 between x and y
    });

    test(r'\p{L}+ begins at a Greek letter', () {
      expect(_m(r'\p{L}+', '123 Ωμέγα'), isNotNull);
      expect(_m(r'\p{L}+', '123 Ωμέγα')!.$1, 4); // after "123 "
    });

    test('non-matching positions are still correctly rejected', () {
      expect(_m(r'\w+', '   ...   '), isNull); // only spaces/punct -> no word
      expect(_m(r'\d+', 'abc def'), isNull); // no digits
    });
  });
}
