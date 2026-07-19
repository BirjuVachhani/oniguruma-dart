/// Tests for the linear-time Thompson/Pike NFA fast path (lib/src/exec/nfa.dart).
///
/// Three guarantees:
///  1. Parity: for patterns the NFA accepts, it returns byte-identical results
///     to the backtracking VM (checked by running both on the same inputs).
///  2. Linear time: a classic catastrophic-backtracking pattern completes in
///     bounded time on a large input (the whole point of the fast path).
///  3. Gating: unsupported constructs fall back (reg.nfa == null) and still
///     produce correct matches through the backtracking VM.
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

Regex _compile(String pat, {int option = 0}) {
  final pb = Uint8List.fromList(utf8.encode(pat));
  return onigNew(pb, pb.length, utf8Encoding, onigSyntaxOniguruma, option);
}

(int, int, int) _search(Regex reg, String subj) {
  final sb = Uint8List.fromList(utf8.encode(subj));
  final r = OnigRegion();
  final m = onigSearch(reg, sb, sb.length, 0, sb.length, r);
  if (m < 0) return (m, -1, -1);
  return (m, r.beg[0], r.end[0]);
}

void main() {
  // Risky (nested-repetition) patterns are diverted to the NFA. On short inputs
  // the backtracking VM also completes, so we can assert byte-identical results.
  group('NFA parity (same result as the backtracking VM)', () {
    const cases = <(String, List<String>)>[
      (r'(a+)+$', ['aaa', 'aaab', '', 'baaa']),
      (r'(a+)+b', ['aaab', 'aaa', 'b', 'xaab']),
      (r'(ab+)+', ['abbab', 'abbb', 'xyz', 'ab']),
      (r'([0-9]+)+x', ['123x', '12', '99x9', 'x']),
      (r'(\w+)+@', ['abc@', 'abc', '@', 'a_b@x']),
      (r'(a|b|c)(d+)+e', ['add e', 'adde', 'bde', 'zzz']),
      (r'x(a+)+y', ['xaaay', 'xay', 'xy', 'xaab']),
    ];
    for (final (pat, subjects) in cases) {
      test('/$pat/', () {
        final regNfa = _compile(pat);
        expect(regNfa.nfa, isNotNull, reason: '$pat should be NFA-eligible');
        final regBt = _compile(pat)..nfa = null; // force backtracking
        for (final s in subjects) {
          expect(
            _search(regNfa, s),
            _search(regBt, s),
            reason: 'divergence on /$pat/ against ${jsonEncode(s)}',
          );
        }
      });
    }
  });

  // Flat / single-level patterns are NOT diverted. They are faster on the
  // backtracking VM (literal/BMH/map/anchor prefilters). They must still match.
  group('flat patterns keep the backtracking prefilter path', () {
    const cases = <(String, String, bool)>[
      ('lorem', 'xxloremxx', true),
      ('[a-z]+', '123abc', true),
      (r'\w+', ' hi_there', true),
      (r'.*lorem', 'a b lorem c', true),
      ('colou?r', 'colour', true),
      (r'\bword\b', 'a word here', true),
    ];
    for (final (pat, subj, m) in cases) {
      test('/$pat/ not diverted', () {
        final reg = _compile(pat);
        expect(reg.nfa, isNull, reason: '$pat should stay on the fast path');
        expect(_search(reg, subj).$1 >= 0, m);
      });
    }
  });

  test('linear time on a catastrophic pattern', () {
    // `(a+)+$` on many a's followed by a non-matching byte is the textbook
    // exponential-backtracking case. The NFA must finish near-instantly.
    final reg = _compile(r'(a+)+$');
    expect(reg.nfa, isNotNull);
    final subj = '${'a' * 5000}!';
    final sw = Stopwatch()..start();
    final (m, _, _) = _search(reg, subj);
    sw.stop();
    expect(m, OnigResult.mismatch);
    expect(
      sw.elapsedMilliseconds,
      lessThan(500),
      reason: 'NFA should be linear, not exponential',
    );
  });

  group('unsupported constructs fall back but still match', () {
    const cases = <(String, String, bool)>[
      (r'(\w+) \1', 'hi hi', true), // back-reference
      (r'(?>a+)b', 'aaab', true), // atomic group
      (r'(?=ab)a', 'abc', true), // look-ahead
      (r'a\X', 'a\u{1f468}', true), // \X grapheme cluster
      (r'(?:a|b)+', 'abab', true), // alternation under a quantifier
    ];
    for (final (pat, subj, shouldMatch) in cases) {
      test('/$pat/ falls back', () {
        final reg = _compile(pat);
        expect(reg.nfa, isNull, reason: '$pat must NOT be NFA-eligible');
        final (m, _, _) = _search(reg, subj);
        expect(m >= 0, shouldMatch);
      });
    }
  });

  test('(?i) ignore-case is excluded from the NFA', () {
    final reg = _compile('(?i)abc');
    expect(reg.nfa, isNull);
    expect(_search(reg, 'xABCx').$1, greaterThanOrEqualTo(0));
  });
}
