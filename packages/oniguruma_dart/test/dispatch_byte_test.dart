/// Regression tests for the literal-switch alternation opcode
/// (`compiler.dart` `_compileAlt` fast path → `Op.dispatchByte`): when every
/// branch of an alternation has a fixed, DISTINCT single first byte, the
/// alternation compiles to a byte→branch jump table with NO backtrack frame.
///
/// The results must be byte-identical to the general PUSH/JUMP alternation.
/// The interesting cases are (a) a candidate whose byte matches a branch head
/// but whose full literal does NOT match: must fail, never spuriously match a
/// sibling; (b) the switch embedded in a larger pattern where the continuation
/// forces a give-back; (c) captures inside a branch; (d) shared-first-byte
/// alternations that must FALL BACK to the general path and still be correct.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:oniguruma_dart/src/encoding/encodings.dart';
import 'package:oniguruma_dart/src/region.dart';
import 'package:oniguruma_dart/src/regex.dart';
import 'package:oniguruma_dart/src/syntax.dart';
import 'package:oniguruma_dart/src/exec/search.dart';
import 'package:test/test.dart';

OnigRegion? _search(String pat, String subj) {
  final pb = Uint8List.fromList(utf8.encode(pat));
  final r = onigNew(pb, pb.length, utf8Encoding, onigSyntaxOniguruma, 0);
  final sb = Uint8List.fromList(utf8.encode(subj));
  final region = OnigRegion();
  final rc = onigSearch(r, sb, sb.length, 0, sb.length, region);
  return rc < 0 ? null : region;
}

(int, int)? _m(String pat, String subj) {
  final r = _search(pat, subj);
  return r == null ? null : (r.beg[0], r.end[0]);
}

void main() {
  group('distinct-first-byte switch matches each branch', () {
    const pat = 'lorem|ipsum|dolor|sit|amet';
    test('each alternative matches at its own start', () {
      expect(_m(pat, 'lorem'), (0, 5));
      expect(_m(pat, 'ipsum'), (0, 5));
      expect(_m(pat, 'dolor'), (0, 5));
      expect(_m(pat, 'sit'), (0, 3));
      expect(_m(pat, 'amet'), (0, 4));
    });
    test('finds the alternative mid-string (leftmost)', () {
      expect(_m(pat, 'xxx dolor yyy'), (4, 9));
      expect(_m(pat, 'a b sit'), (4, 7));
    });
    test('no match when nothing present', () {
      expect(_m(pat, 'consectetur'), isNull);
      expect(_m(pat, ''), isNull);
    });
  });

  group('byte hits a head but the full literal fails → must NOT match', () {
    const pat = 'lorem|ipsum|dolor|sit|amet';
    // "in" starts with 'i' (ipsum's head) but is not "ipsum".
    test('i-word that is not ipsum', () => expect(_m(pat, 'in out'), isNull));
    // "logic" starts with 'l' but is not "lorem".
    test('l-word that is not lorem', () => expect(_m(pat, 'logic'), isNull));
    // "site" contains "sit" as a prefix → should match "sit".
    test(
      'prefix of a longer word still matches',
      () => expect(_m(pat, 'site'), (0, 3)),
    );
    // partial then real: "si sit" (first "si" fails, later "sit" matches).
    test(
      'partial before the real one',
      () => expect(_m(pat, 'si sit'), (3, 6)),
    );
  });

  group('embedded switch with a continuation (give-back / backtrack)', () {
    test(r'(lorem|ipsum)\b requires a boundary after', () {
      expect(_m(r'(lorem|ipsum)\b', 'lorem!'), (0, 5));
      expect(_m(r'(lorem|ipsum)\b', 'loremx'), isNull); // no boundary
    });
    test('switch then a literal that overlaps the tail', () {
      // amet|sit followed by a char; distinct heads a/s.
      expect(_m(r'(amet|sit)s', 'amets'), (0, 5));
      expect(_m(r'(amet|sit)s', 'sits'), (0, 4));
      expect(_m(r'(amet|sit)s', 'amet'), isNull);
    });
    test('switch inside a repeat', () {
      expect(_m(r'(?:ab|cd|ef)+', 'abcdefab'), (0, 8));
      expect(_m(r'(?:ab|cd|ef)+', 'abXcd'), (0, 2));
    });
  });

  group('captures inside branches are filled correctly', () {
    test('group 1 spans the taken branch', () {
      final r = _search(r'(lorem|ipsum|dolor)', 'see dolor here');
      expect(r, isNotNull);
      expect([r!.beg[1], r.end[1]], [4, 9]);
    });
    test('nested capture in one branch', () {
      final r = _search(r'a(x)|b(y)|c(z)', 'find cz');
      expect(r, isNotNull);
      expect([r!.beg[0], r.end[0]], [5, 7]);
      expect([r.beg[3], r.end[3]], [6, 7]); // (z) captured
      expect(r.beg[1], -1); // (x) not set
      expect(r.beg[2], -1); // (y) not set
    });
  });

  group('shared-first-byte alternations fall back and stay correct', () {
    // Both start with 'a' → NOT eligible for dispatch; leftmost/ordered
    // semantics (first branch wins) must hold.
    test('a|ab prefers the first branch (leftmost, not longest)', () {
      expect(_m('a|ab', 'ab'), (0, 1));
    });
    test('ab|a still matches a when ab cannot', () {
      expect(_m('ab|a', 'ac'), (0, 1));
      expect(_m('ab|a', 'ab'), (0, 2));
    });
    test('shared-prefix words need real backtracking', () {
      expect(_m('abc|abd|abe', 'abd'), (0, 3));
      expect(_m('abc|abd|abe', 'abe'), (0, 3));
      expect(_m('abc|abd|abe', 'abf'), isNull);
    });
  });

  group('nullable / non-fixed branches fall back', () {
    test('optional-head branch a?|b (a? is nullable) stays correct', () {
      expect(_m('a?|b', 'b'), (0, 0)); // a? matches empty first (leftmost)
      expect(_m('a?|b', 'a'), (0, 1));
    });
    test('class-head branch [0-9]+|end', () {
      expect(_m(r'[0-9]+|end', '42'), (0, 2));
      expect(_m(r'[0-9]+|end', 'end'), (0, 3));
    });
  });

  // Fast in-process differential for the ≥3-branch dispatch path: a bare
  // distinct-first-byte literal switch is equivalent to "leftmost position where
  // one of the words starts (and fully matches)". Compute that independently and
  // check thousands of random (word-set, subject) pairs against the engine, no
  // C subprocess needed, so it covers far more branch/subject combos than the
  // IPC fuzzer can.
  group('dispatch vs independent oracle (fuzz)', () {
    const words = [
      'lorem',
      'ipsum',
      'dolor',
      'sit',
      'amet',
      'be',
      'go',
      'red',
      'up',
      'joy',
      'fox',
      'kit',
      'wolf',
      'nap',
      'queue',
      'via',
      'zap',
      'hi',
    ];

    // Independent reference: leftmost start of any word (distinct heads ⇒ at
    // most one word can begin at a given position, so no ordering ambiguity).
    (int, int)? refMatch(List<String> ws, String subj) {
      for (var p = 0; p < subj.length; p++) {
        for (final w in ws) {
          if (subj.startsWith(w, p)) return (p, p + w.length);
        }
      }
      return null;
    }

    test('4000 random distinct-head switches match the oracle', () {
      var rng = 0xC0FFEE;
      int rand(int n) {
        rng = (rng * 1103515245 + 12345) & 0x7fffffff;
        return rng % n;
      }

      const alpha = 'loremipsumdolrsatbgoyfxkwnqhvz .';
      var checked = 0;
      for (var iter = 0; iter < 4000; iter++) {
        // pick 2..6 words with distinct first letters
        final used = <int>{};
        final ws = <String>[];
        var guard = 0;
        final target = 2 + rand(5);
        while (ws.length < target && guard++ < 60) {
          final w = words[rand(words.length)];
          if (used.add(w.codeUnitAt(0))) ws.add(w);
        }
        if (ws.length < 2) continue;
        final pat = ws.join('|');

        // random subject, sometimes with a word spliced in
        final n = rand(20);
        final sb = StringBuffer();
        for (var i = 0; i < n; i++) {
          sb.write(alpha[rand(alpha.length)]);
        }
        var subj = sb.toString();
        if (rand(2) == 0) {
          final at = rand(subj.length + 1);
          subj =
              subj.substring(0, at) +
              words[rand(words.length)] +
              subj.substring(at);
        }

        expect(
          _m(pat, subj),
          refMatch(ws, subj),
          reason: 'pat=$pat subj=${_escape(subj)}',
        );
        checked++;
      }
      expect(checked, greaterThan(3000)); // sanity: most iters ran
    });
  });
}

String _escape(String s) => s.replaceAll(' ', '·');
