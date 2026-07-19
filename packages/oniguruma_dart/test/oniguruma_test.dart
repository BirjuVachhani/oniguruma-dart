import 'dart:convert';
import 'dart:typed_data';

import 'package:oniguruma_dart/oniguruma_dart.dart';
import 'package:test/test.dart';

/// Compile [pattern] and search [subject]; return `[start, b0,e0, b1,e1, ...]`
/// or null on mismatch. Offsets are byte offsets (as in the C library).
List<int>? search(String pattern, String subject) {
  final pb = Uint8List.fromList(utf8.encode(pattern));
  final sb = Uint8List.fromList(utf8.encode(subject));
  final reg = onigNew(
    pb,
    pb.length,
    utf8Encoding,
    onigSyntaxDefault,
    OnigOption.defaultOption,
  );
  final region = OnigRegion();
  final r = onigSearch(reg, sb, sb.length, 0, sb.length, region);
  if (r < 0) return null;
  final out = <int>[r];
  for (var i = 0; i < region.numRegs; i++) {
    out.add(region.beg[i]);
    out.add(region.end[i]);
  }
  return out;
}

/// Expect a match at [from,to) for the whole match (`x2` macro equivalent).
void x2(String pat, String str, int from, int to) {
  final r = search(pat, str);
  expect(r, isNotNull, reason: '/$pat/ should match "$str"');
  expect([r![1], r[2]], [from, to], reason: '/$pat/ on "$str"');
}

/// Expect group [mem] at [from,to) (`x3` macro equivalent).
void x3(String pat, String str, int from, int to, int mem) {
  final r = search(pat, str);
  expect(r, isNotNull, reason: '/$pat/ should match "$str"');
  expect(
    [r![1 + mem * 2], r[2 + mem * 2]],
    [from, to],
    reason: '/$pat/ group $mem on "$str"',
  );
}

/// Expect no match (`n` macro equivalent).
void n(String pat, String str) {
  expect(search(pat, str), isNull, reason: '/$pat/ should NOT match "$str"');
}

void main() {
  group('literals & basics', () {
    test('literal', () => x2('abc', 'zzabc', 2, 5));
    test('dot', () => x2('a.c', 'abc', 0, 3));
    test('dot no newline', () => n('a.c', 'a\nc'));
    test('empty pattern', () => x2('', 'abc', 0, 0));
    test('mismatch', () => n('xyz', 'abcdef'));
  });

  group('quantifiers', () {
    test('star', () => x2('a*', 'aaab', 0, 3));
    test('plus', () => x2('a+', 'baaa', 1, 4));
    test('opt', () => x2('colou?r', 'color', 0, 5));
    test('opt2', () => x2('colou?r', 'colour', 0, 6));
    test('interval', () => x2('a{2,3}', 'aaaa', 0, 3));
    test('exact', () => x2('a{2}', 'aaaa', 0, 2));
    test('lazy', () => x2('a+?', 'aaa', 0, 1));
    test('greedy group', () => x2('(ab)+', 'ababab', 0, 6));
  });

  group('classes', () {
    test('range', () => x2('[a-z]+', 'Hello', 1, 5));
    test('negated', () => x2('[^a-z]+', 'ABC12def', 0, 5));
    test('digit', () => x2(r'\d+', 'abc123', 3, 6));
    test('word', () => x2(r'\w+', ' ab_9 ', 1, 5));
    test('posix', () => x2('[[:digit:]]+', 'x42', 1, 3));
  });

  group('anchors', () {
    test('begin ok', () => x2('^abc', 'abc', 0, 3));
    test('begin fail', () => n('^abc', 'xabc'));
    test('end', () => x2(r'abc$', 'xxabc', 2, 5));
    test('A', () => x2(r'\Aabc', 'abc', 0, 3));
    test('z', () => x2(r'abc\z', 'abc', 0, 3));
    test('word boundary', () => x2(r'\bword\b', 'a word x', 2, 6));
  });

  group('groups & alternation', () {
    test('alt', () => x2('gr(a|e)y', 'grey', 0, 4));
    test('capture', () => x3('(a)(b)(c)', 'abc', 1, 2, 2));
    test('named', () => x3(r'(?<n>\d+)', 'x123', 1, 4, 1));
    test('backref', () => x2(r'(\w+)\s+\1', 'hi hi', 0, 5));
    test('backref fail', () => n(r'(\w+)\s+\1', 'hi bye'));
    test('nested', () => x3('a(.*)b', 'axxb', 1, 3, 1));
  });

  group('escapes', () {
    test('hex', () => x2(r'\x41\x42', 'AB', 0, 2));
    test('tab', () => x2(r'a\tb', 'a\tb', 0, 3));
  });

  group('unicode', () {
    test('word', () => x2(r'\w+', 'café x', 0, 5)); // é is 2 bytes
    test('property L', () => x2(r'\p{L}+', 'ab12', 0, 2));
    test('property script', () => x2(r'\p{Greek}+', 'αβγz', 0, 6));
    test('negated property', () => x2(r'\P{L}+', 'ab!@#z', 2, 5));
    test(
      'cyrillic boundary',
      () => x2(r'\bмир\b', 'вот мир', 7, 13),
    ); // byte offsets
  });

  group('case-insensitive', () {
    test('ascii', () => x2('(?i)abc', 'XABC', 1, 4));
    test('unicode char', () => x2('(?i)é', 'É', 0, 2));
    test('class', () => x2('(?i)[a-z]+', 'HELLO', 0, 5));
  });

  group('look-around', () {
    test('lookahead', () => x2(r'foo(?=bar)', 'foobar', 0, 3));
    test('neg lookahead', () => n(r'foo(?!bar)', 'foobar'));
    test('lookbehind', () => x2(r'(?<=foo)bar', 'foobar', 3, 6));
    test('neg lookbehind', () => x2(r'(?<!foo)bar', 'xxxbar', 3, 6));
  });

  group('conditionals & keep', () {
    test('conditional then', () => x2('(a)?(?(1)b|c)', 'ab', 0, 2));
    test('conditional else', () => x2('(a)?(?(1)b|c)', 'c', 0, 1));
    test('keep', () => x3(r'foo\Kbar', 'foobar', 3, 6, 0));
  });

  group('variable look-behind', () {
    test('class+', () => x2(r'(?<=[ab]+)c', 'aabc', 3, 4));
    test('digits', () => x2(r'(?<=\d+)x', '123x', 3, 4));
    test('neg', () => x2(r'(?<!\d+)x', 'abcx', 3, 4));
    test('alt lengths', () => x2(r'(?<=foo|xy)!', 'foo!', 3, 4));
    test('dotstar', () => x2(r'(?<=a.*z)!', 'abcz!', 4, 5));
  });

  group('subexp calls', () {
    test('numbered', () => x2(r'(\d)\g<1>', '42', 0, 2));
    test('group', () => x2(r'(ab)\g<1>', 'abab', 0, 4));
    test(
      'recursion position',
      () => x2(r'\A(?<p>\((?:[^()]|\g<p>)*\))\z', '(a(b)c)', 0, 7),
    );
  });

  group('recursion & levels', () {
    test(
      'subexp recursion capture',
      () => x3(r'(?<p>\((?:[^()]|\g<p>)*\))', '(a(b)c)', 0, 7, 1),
    );
    test(
      'palindrome (backref-with-level)',
      () => x2(r'\A(?<a>|.|(?:(?<b>.)\g<a>\k<b+0>))\z', 'reer', 0, 4),
    );
    test(
      'non-palindrome',
      () => n(r'\A(?<a>|.|(?:(?<b>.)\g<a>\k<b+0>))\z', 'reet'),
    );
  });

  group('callouts', () {
    test('(*FAIL)', () => n(r'a(*FAIL)', 'a'));
    test('(*FAIL) alt', () => x2(r'a(*FAIL)|ab', 'ab', 0, 2));
    test('(*MISMATCH)', () => n(r'a(*MISMATCH)b|ab', 'ab'));
  });

  group('empty-repeat captures', () {
    test('(a?)*', () => x3('(a?)*', '', 0, 0, 1));
    test('(a*)*', () => x3('(a*)*', 'aaa', 3, 3, 1));
    // Counted repeats over empty-capable groups (compile-length-driven
    // OP_REPEAT + empty-check); values verified against the C library.
    test('(a?){2}\$', () => x3(r'(a?){2}$', 'a', 1, 1, 1));
    test('(a??){3}\$', () => x3(r'(a??){3}$', 'a', 1, 1, 1));
    test('(a*){2}\$', () => x3(r'(a*){2}$', 'a', 1, 1, 1));
    test('(a??){2} on aa', () => x3(r'(a??){2}$', 'aa', 1, 2, 1));
    // Non-push MEM under a fixed {n}: Oniguruma's "inverted" (beg>end) empty
    // region: a failed later iteration leaves start ahead of end. Verified
    // against the C library (g1 = 1,0).
    test(
      'inverted region (^…){2}',
      () => x3(r'(^(?:[[:alpha:]]|b){0,26}){2}', 'b0xy', 1, 0, 1),
    );
    test(
      'inverted region anchored',
      () => x3(r'^((?:[[:alpha:]]|c){0,26}){2}c', 'cx2zc', 1, 0, 1),
    );
  });

  group('posix & gnu apis', () {
    test('posix regexec', () {
      final h = PosixRegexHolder();
      expect(posixRegcomp(h, r'([a-z]+) ([a-z]+)', Reg.extended), 0);
      final m = [PosixMatch(), PosixMatch(), PosixMatch()];
      expect(posixRegexec(h.regex!, 'x hi bye', 3, m, 0), 0);
      expect([m[1].rmSo, m[1].rmEo], [0, 1]); // "x"
      expect([m[2].rmSo, m[2].rmEo], [2, 4]); // "hi"
    });
    test('gnu re_search', () {
      final reg = reCompilePattern(r'\d+');
      final sb = Uint8List.fromList('ab12'.codeUnits);
      expect(reSearch(reg, sb, 4, 0, 4, OnigRegion()), 2);
    });
  });

  group('text segments', () {
    test(
      'grapheme combining',
      () => x2(r'\X', 'e\u0301', 0, 3),
    ); // e + combining acute
    test('grapheme flag', () => x2(r'\X', '\u{1F1FA}\u{1F1F8}', 0, 8));
    test('boundary', () => x2(r'\y\w+\y', '  hi  ', 2, 4));
  });

  group('string API', () {
    test('firstMatch groups', () {
      final m = OnigRegex.compile(r'(\w+)@(\w+)').firstMatch('x bob@acme');
      expect(m?.group(0), 'bob@acme');
      expect(m?.group(1), 'bob');
      expect(m?.group(2), 'acme');
      expect(m?.start, 2);
    });
    test('allMatches', () {
      final got = OnigRegex.compile(
        r'\d+',
      ).allMatches('a1b22c333').map((m) => m.group(0));
      expect(got.toList(), ['1', '22', '333']);
    });
    test('replaceAll', () {
      final out = OnigRegex.compile(r'\d+').replaceAll('a1b22', (m) => '#');
      expect(out, 'a#b#');
    });
    test('unicode offsets', () {
      // 'é' is one code unit but two UTF-8 bytes.
      final m = OnigRegex.compile('monde').firstMatch('héllo monde');
      expect(m?.start, 6);
      expect(m?.end, 11);
    });
    test('named group', () {
      final m = OnigRegex.compile(r'(?<y>\d{4})').firstMatch('yr 2026 end');
      expect(m?.namedGroup('y'), '2026');
    });
    test('ignoreCase flag', () {
      expect(OnigRegex.compile('hi', ignoreCase: true).hasMatch('HI'), isTrue);
    });
  });
}
