// 1:1 translation of Oniguruma's test/test_regset.c (the OnigRegSet API).
//
// The C harness builds a regset from an array of patterns, searches a subject
// under a lead mode (POSITION_LEAD / REGEX_LEAD), and checks the matched
// region. Patterns/subjects are UTF-8; the file-backed (kofu-utf8.txt) cases
// are omitted since that corpus isn't shipped.
import 'dart:convert';
import 'dart:typed_data';

import 'package:oniguruma_dart/oniguruma_dart.dart';
import 'package:test/test.dart';

Uint8List _u8(String s) => Uint8List.fromList(utf8.encode(s));

OnigRegSet _set(List<String> pats) {
  final set = OnigRegSet();
  for (final p in pats) {
    final pb = _u8(p);
    set.add(
      onigNew(pb, pb.length, utf8Encoding, onigSyntaxDefault, OnigOption.none),
    );
  }
  return set;
}

/// C `x2`/`x3`: pattern [mem] of the winning regex spans [from,to].
void x3(
  List<String> pats,
  String s,
  int from,
  int to,
  int mem,
  RegSetLead lead,
  int line,
) {
  test('#$line ${lead.name} /${pats.join("|")}/', () {
    final set = _set(pats);
    final sb = _u8(s);
    final idx = set.search(sb, sb.length, 0, sb.length, lead: lead);
    expect(idx, greaterThanOrEqualTo(0), reason: 'expected a match');
    final region = set.region!;
    expect([region.beg[mem], region.end[mem]], [from, to]);
  });
}

void x2(
  List<String> pats,
  String s,
  int from,
  int to,
  RegSetLead lead,
  int line,
) => x3(pats, s, from, to, 0, lead, line);

/// C `n` / `NZERO`: no pattern in the set matches.
void n(List<String> pats, String s, RegSetLead lead, int line) {
  test('#$line ${lead.name} /${pats.join("|")}/ (no match)', () {
    final set = _set(pats);
    final sb = _u8(s);
    final idx = set.search(sb, sb.length, 0, sb.length, lead: lead);
    expect(idx, lessThan(0), reason: 'expected no match');
  });
}

const p1 = ['abc', '(bca)', '(cab)'];
const p2 = ['小説', '9', '夏目漱石'];
const p7 = ['0+', '1+', '2+', '3+', '4+', '5+', '6+', '7+', '8+', '9+'];
const p8 = ['a', '.*'];

void main() {
  group('test_regset', () {
    for (final lead in [RegSetLead.positionLead, RegSetLead.regexLead]) {
      final ln = lead == RegSetLead.positionLead ? 410 : 418;
      n(const <String>[], ' abab bccab ca', lead, ln);
      x2(p1, ' abab bccab ca', 8, 11, lead, ln + 1);
      x3(p1, ' abab bccab ca', 8, 11, 1, lead, ln + 2);
      n(p2, ' XXXX AAA 1223 012345678bbb', lead, ln + 3);
      x2(p2, '0123456789', 9, 10, lead, ln + 4);
      x2(p7, 'abcde 555 qwert', 6, 9, lead, ln + 5);
      // POSITION_LEAD also checks the empty-match `.*` case (p8).
      if (lead == RegSetLead.positionLead) {
        x2(p8, '', 0, 0, lead, ln + 6);
      }
    }
  });
}
