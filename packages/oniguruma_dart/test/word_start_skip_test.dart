/// Regression tests for the leading-`\b` word-start search skip
/// (`optimize.dart` sets `reg.leadingWordBoundary`; `search.dart` map loop
/// skips candidates where str[s] and str[s-1] are both ASCII word chars).
///
/// The skip only drops positions where `\b` is provably false, so results must
/// be byte-identical to a full scan. The interesting cases: matches at BOL
/// (position 0), after every kind of non-word neighbour (space, punctuation,
/// newline, digit-vs-underscore boundaries are still word|word), matches that
/// begin mid-buffer, a `\b` after a multibyte char, and `\B` (which must NOT
/// enable the skip). Cross-checked against an independent word-boundary oracle
/// over thousands of random subjects.
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
  group(r'\b\w{5}\b (the benchmark pattern)', () {
    test(
      'matches a 5-letter word at BOL',
      () => expect(_m(r'\b\w{5}\b', 'lorem ipsum'), (0, 5)),
    );
    test(
      'matches a 5-letter word mid-buffer',
      () => expect(_m(r'\b\w{5}\b', 'a lorem b'), (2, 7)),
    );
    test('no 5-letter word ⇒ no match', () {
      expect(_m(r'\b\w{5}\b', 'hi go fantastic'), isNull); // 2,3,9 lengths
    });
    test(
      'there is exactly 5 → matches',
      () => expect(_m(r'\b\w{5}\b', 'oh there go'), (3, 8)),
    );
    test('skips mid-word candidates but still finds the real start', () {
      // "xxlorem": 'l' at index 2 is mid-word (prev 'x' is word); the real
      // 5-letter word "lorem" only appears after the space.
      expect(_m(r'\b\w{5}\b', 'xxlorem lorem'), (8, 13));
    });
  });

  group('word-start neighbours', () {
    test('after a space', () => expect(_m(r'\bword\b', 'a word'), (2, 6)));
    test('after punctuation', () => expect(_m(r'\bword\b', '(word)'), (1, 5)));
    test('after a newline', () => expect(_m(r'\bword\b', 'x\nword'), (2, 6)));
    test('underscore is a word char (no boundary inside a_b)', () {
      expect(_m(r'\bword\b', 'a_word'), isNull); // '_' before 'w' ⇒ no \b
    });
    test('digit-letter is word|word (no boundary)', () {
      expect(_m(r'\bword\b', '1word'), isNull); // '1' before 'w' ⇒ no \b
    });
    test(
      'match at position 0 with no preceding char',
      () => expect(_m(r'\bword\b', 'word!'), (0, 4)),
    );
  });

  group(r'\b after a multibyte char', () {
    test('word after non-word CJK punctuation is a boundary', () {
      // '。' (U+3002, 3 UTF-8 bytes) is punctuation ⇒ non-word ⇒ 'w' starts a
      // word. The skip (ASCII-only) leaves this multibyte-prev case to the VM.
      expect(_m(r'\bword\b', '。word'), (3, 7));
    });
    test('word after a CJK ideograph (a word char) has NO boundary', () {
      // '好' IS a Unicode word char, so there is no \b between it and 'w'.
      expect(_m(r'\bword\b', '好word'), isNull);
    });
    test('accented word skipped, ascii "cafe" matched (byte offsets)', () {
      // 'x café cafe': é is 2 UTF-8 bytes, so ascii "cafe" sits at bytes 8..12.
      // 'café' (bytes 2..8) can't match \bcafe\b (é ≠ e).
      expect(_m(r'\bcafe\b', 'x café cafe'), (8, 12));
    });
  });

  group(r'\B must NOT enable the skip (still correct)', () {
    test(r'\Bord matches inside a word', () {
      expect(_m(r'\Bord', 'word'), (1, 4)); // 'ord' preceded by word 'w'
      expect(_m(r'\Bord', ' ord'), isNull); // 'o' at a boundary ⇒ \B false
    });
  });

  // Fast in-process differential: independent word-boundary oracle over random
  // subjects, for a family of \b-led patterns. Confirms the skip never changes
  // the leftmost match.
  group(r'\b patterns vs independent oracle (fuzz)', () {
    bool aw(int c) =>
        (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5a) ||
        (c >= 0x61 && c <= 0x7a) ||
        c == 0x5f;
    bool wb(String s, int p) {
      final left = p > 0 && aw(s.codeUnitAt(p - 1));
      final right = p < s.length && aw(s.codeUnitAt(p));
      return left != right;
    }

    // reference for \b\w{n}\b : leftmost p where \b(p), then n word chars, \b.
    (int, int)? refWordN(String s, int n) {
      for (var p = 0; p <= s.length; p++) {
        if (!wb(s, p)) continue;
        if (p + n > s.length) continue;
        var ok = true;
        for (var k = 0; k < n; k++) {
          if (!aw(s.codeUnitAt(p + k))) {
            ok = false;
            break;
          }
        }
        if (ok && wb(s, p + n)) return (p, p + n);
      }
      return null;
    }

    test('4000 random subjects for \\b\\w{3}\\b and \\b\\w{5}\\b', () {
      var rng = 0x1234abcd;
      int rand(int m) {
        rng = (rng * 1103515245 + 12345) & 0x7fffffff;
        return rng % m;
      }

      // ASCII-only alphabet (the skip's domain): letters, digits, _, and
      // several non-word separators.
      const alpha = 'abcdeXYZ_012 .,-!\t';
      for (final n in [3, 5]) {
        final pat =
            r'\b\w{'
            '$n'
            r'}\b';
        for (var iter = 0; iter < 2000; iter++) {
          final len = rand(18);
          final sb = StringBuffer();
          for (var i = 0; i < len; i++) {
            sb.write(alpha[rand(alpha.length)]);
          }
          final subj = sb.toString();
          expect(
            _m(pat, subj),
            refWordN(subj, n),
            reason: 'pat=$pat subj=«$subj»',
          );
        }
      }
    });
  });
}
