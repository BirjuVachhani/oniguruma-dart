/// Differential test runner: runs a batch of (pattern, subject) cases through
/// both the Dart port and the C reference CLI and reports any divergence.
///
///   dart run test/differential/run_diff.dart [path-to-onig_cli]
library;

import 'dart:io';

import 'diff_util.dart';

/// Core vertical-slice cases: literals, `.`, quantifiers, alternation, classes,
/// anchors, groups, backrefs.
const List<(String, String)> cases = [
  ('a(.*)b|[e-f]+', 'zzzzaffffffffb'),
  (r'\d+', 'abc123def'),
  ('xyz', 'no match here'),
  ('(foo)(bar)?', 'foobar'),
  ('a*', 'aaa'),
  ('a+', 'baaa'),
  ('a?b', 'b'),
  ('a{2,3}', 'aaaa'),
  ('a{2}', 'aaaa'),
  ('colou?r', 'color'),
  ('colou?r', 'colour'),
  ('(ab)+', 'ababab'),
  ('(a|b)*c', 'abbac'),
  ('[a-z]+', 'Hello World'),
  ('[^a-z]+', 'ABC123def'),
  (r'\w+', '  hello_world 42'),
  (r'\s+', 'a   b'),
  ('^abc', 'abc'),
  ('^abc', 'xabc'),
  (r'abc$', 'xxabc'),
  (r'\bword\b', 'a word here'),
  (r'\Aabc', 'abc'),
  (r'abc\z', 'abc'),
  ('(a)(b)(c)', 'abc'),
  (r'(\w+)\s+\1', 'hello hello'),
  (r'(\w+)\s+\1', 'hello world'),
  ('a.c', 'abc'),
  ('a.c', 'a\nc'),
  ('.*', 'anything'),
  ('gr(a|e)y', 'grey'),
  ('[[:digit:]]+', 'abc42'),
  ('(?:abc)+', 'abcabc'),
  ('a??', 'aaa'),
  ('a+?', 'aaa'),
  ('(?<name>\\d+)', 'x123'),
  (r'\x41\x42', 'AB'),
  ('[a-c]{2,}', 'abcabc'),
  ('', 'abc'),
  ('a*', ''),
  // Unicode: properties, ctype, word boundary
  (r'\w+', 'café résumé'),
  (r'\p{L}+', '123abcДЕФ'),
  (r'\p{Lu}+', 'abcABCdef'),
  (r'\P{L}+', 'abc123!@#'),
  (r'\p{Latin}+', 'abcДЕФ'),
  (r'\p{Greek}+', 'αβγabc'),
  (r'[\p{Nd}]+', 'abc123'),
  (r'\bрусский\b', 'вот русский текст'),
  (r'\d+', 'abc①②③123'),
  ('日本語', 'これは日本語です'),
  (r'.', 'é'),
  (r'\p{Hiragana}+', 'ひらがなカタカナ'),
  // escapes & named backrefs
  (r'a\Rb', 'a\r\nb'),
  (r'a\Rb', 'a\nb'),
  (r'\N+', 'abc\ndef'),
  (r'(?<w>\w+)-\k<w>', 'hi-hi'),
  (r"(?<w>\w+)-\k'w'", 'hi-hi'),
  (r'(?<w>\w+)-\k<w>', 'hi-bye'),
  (r'\O+', 'a\nb'),
  // look-behind (fixed length)
  (r'(?<=foo)bar', 'foobar'),
  (r'(?<=foo)bar', 'xxxbar'),
  (r'(?<!foo)bar', 'xxxbar'),
  (r'(?<!foo)bar', 'foobar'),
  (r'(?<=\d{3})x', '123x'),
  (r'(?<=ab|cd)e', 'cde'),
  // case-insensitive
  ('(?i)abc', 'ABC'),
  ('(?i)abc', 'AbC'),
  ('(?i)café', 'CAFÉ'),
  ('(?i)[a-z]+', 'HELLO'),
  ('(?i)é', 'É'),
  ('(?i)[α-ω]+', 'ΑΒΓ'),
  // conditionals
  ('(a)?(?(1)b|c)', 'ab'),
  ('(a)?(?(1)b|c)', 'c'),
  ('(a)?(?(1)b|c)', 'ac'),
  (r'(?<x>a)?(?(<x>)b|c)', 'ab'),
  (r'(?<x>a)?(?(<x>)b|c)', 'c'),
  // \K keep
  (r'foo\Kbar', 'foobar'),
  (r'\w+\K\d+', 'abc123'),
  (r'(?<=x)\Ky', 'xy'),
  // large counted repeats (OP_REPEAT path)
  (
    'a{100}',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  ),
  ('a{30}', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  ('a{5,50}', 'aaaaaaaaaaaaaaaaaaaa'),
  ('a{5,50}', 'aaa'),
  ('(ab){30}', 'abababababababababababababababababababababababababababababab'),
  ('a{40,}', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  // subexp calls (non-recursive: full parity). Recursive-call sub-capture
  // *values* differ from C (positions are correct) — see REPORT.md.
  (r'(\d)\g<1>', '42'),
  (r'(ab)\g<1>', 'abab'),
  (r'(\w)(\d)\g<1>', 'a1b'),
  // subexp-call recursion (capture values now match C)
  (r'(?<p>\((?:[^()]|\g<p>)*\))', '(a(b)c)'),
  (r'\A(?<x>a\g<x>?b)\z', 'aabb'),
  // callouts
  (r'a(*FAIL)|ab', 'ab'),
  (r'a(*MISMATCH)b|ab', 'ab'),
  (r'\d+(*MAX{2})', '123'),
  // backref-with-level (recursive palindrome)
  (r'\A(?<a>|.|(?:(?<b>.)\g<a>\k<b+0>))\z', 'reer'),
  (r'\A(?<a>|.|(?:(?<b>.)\g<a>\k<b+0>))\z', 'reeer'),
  (r'\A(?<a>|.|(?:(?<b>.)\g<a>\k<b+0>))\z', 'reet'),
  // \X extended grapheme cluster
  (r'\X', 'é'), // e + combining acute
  (r'\X+', 'áb́c'),
  (r'\X', '\u{1F1FA}\u{1F1F8}'), // US flag (RI pair)
  (r'\X', '\u{1F468}‍\u{1F469}'), // ZWJ emoji
  (r'\X', 'ぎ'), // hiragana + combining voiced sound mark
  // variable-length look-behind
  (r'(?<=[ab]+)c', 'aabc'),
  (r'(?<=\d+)x', '123x'),
  (r'(?<!\d+)x', 'abcx'),
  (r'(?<=foo|bar)!', 'bar!'),
  (r'(?<=a.*z)!', 'abcz!'),
  (r'(?<!\d+)x', '12x'),
  // \y text-segment (grapheme) boundary
  (r'\y\w+\y', '  hello  '),
  (r'a\yb', 'ab'),
  (r'\y', 'x'),
  // multi-char case folds
  ('(?i)straße', 'STRASSE'),
  ('(?i)ss', 'ß'),
  ('(?i)ß', 'ss'),
  ('(?i)ß', 'SS'),
];

Future<void> main(List<String> argv) async {
  final cliPath = argv.isNotEmpty ? argv.first : 'benchmark/c/onig_cli';
  if (!File(cliPath).existsSync()) {
    stderr.writeln('C reference CLI not found at $cliPath. Build it first.');
    exit(2);
  }
  final oracle = await COracle.start(cliPath);

  var pass = 0;
  var fail = 0;
  for (final (pat, subj) in cases) {
    final pb = b(pat);
    final sb = b(subj);
    final dart = runDart(pb, sb);
    final c = await oracle.run(pb, sb);
    final ok = dart == c;
    if (ok) {
      pass++;
    } else {
      fail++;
      stdout.writeln('MISMATCH  /$pat/  on  "${_esc(subj)}"');
      stdout.writeln('    C   : $c');
      stdout.writeln('    Dart: $dart');
    }
  }
  await oracle.close();
  stdout.writeln('\n$pass passed, $fail failed, ${cases.length} total');
  exit(fail == 0 ? 0 : 1);
}

String _esc(String s) => s.replaceAll('\n', r'\n');
