@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:oniguruma_native/oniguruma_native.dart';
import 'package:test/test.dart';

Regex _compile(String pattern, {int options = 0}) {
  final b = Uint8List.fromList(utf8.encode(pattern));
  return onigNew(b, b.length, utf8Encoding, onigSyntaxOniguruma, options);
}

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('Layer 0 (raw onig_* over FFI)', () {
    test('onigNew + onigSearch fills a region with byte offsets', () {
      final r = _compile(r'(\d+)-(\d+)');
      final str = _b('ab 12-345 cd');
      final region = OnigRegion();
      final pos = onigSearch(r, str, str.length, 0, str.length, region);
      expect(pos, 3); // '12-345' starts at byte 3
      expect(region.numRegs, 3);
      expect(region.beg[0], 3);
      expect(region.end[0], 9);
      expect(region.beg[1], 3);
      expect(region.end[1], 5); // '12'
      expect(region.beg[2], 6);
      expect(region.end[2], 9); // '345'
      r.dispose();
    });

    test('onigSearch returns ONIG_MISMATCH (-1) on no match', () {
      final r = _compile(r'\d+');
      final str = _b('abc');
      expect(onigSearch(r, str, str.length, 0, str.length, null), -1);
      r.dispose();
    });

    test('onigMatch anchors at a position and reports matched length', () {
      final r = _compile(r'\w+');
      final str = _b('foo bar');
      final region = OnigRegion();
      final len = onigMatch(r, str, str.length, 0, region);
      expect(len, 3); // matched 'foo'
      expect(region.end[0], 3);
      r.dispose();
    });

    test('onigNew throws OnigException on a malformed pattern', () {
      expect(() => _compile('('), throwsA(isA<OnigException>()));
    });

    test('name / capture introspection', () {
      final r = _compile(r'(?<year>\d{4})-(?<mon>\d{2})');
      expect(onigNumberOfCaptures(r), 2);
      expect(onigNumberOfNames(r), 2);
      expect(onigNameToGroupNumbers(r, 'year'), [1]);
      expect(onigNameToGroupNumbers(r, 'mon'), [2]);
      expect(onigNameToGroupNumbers(r, 'nope'), isEmpty);
      r.dispose();
    });

    test('OnigRegion.copyFrom copies every register', () {
      final r = _compile(r'(a)(b)');
      final str = _b('ab');
      final region = OnigRegion();
      onigSearch(r, str, str.length, 0, str.length, region);
      final copy = OnigRegion()..copyFrom(region);
      expect(copy.numRegs, region.numRegs);
      for (var i = 0; i < region.numRegs; i++) {
        expect(copy.beg[i], region.beg[i]);
        expect(copy.end[i], region.end[i]);
      }
      r.dispose();
    });

    test('OnigRegSet returns the left-most match and its region', () {
      final set = OnigRegSet();
      set.add(_compile(r'\d+'));
      set.add(_compile(r'[a-z]+'));
      final str = _b('  abc123');
      final idx = set.search(str, str.length, 0, str.length);
      expect(idx, 1); // [a-z]+ @2 beats \d+ @5
      expect(set.matchPos, 2);
      expect(set.region!.beg[0], 2);
      expect(set.region!.end[0], 5);
      set.dispose();
    });

    test('encoding / syntax handles expose names', () {
      expect(utf8Encoding.name, 'UTF-8');
      expect(onigSyntaxOniguruma.name, 'Oniguruma');
    });
  });

  group('swappability: Layer 0 vs the scanner', () {
    test('scanner UTF-16 offsets equal Layer-0 byte offsets for ASCII', () {
      final r = _compile(r'\d+');
      final bytes = _b('abc 42');
      final region = OnigRegion();
      onigSearch(r, bytes, bytes.length, 0, bytes.length, region);

      final scanner = OnigScanner([r'\d+']);
      final m = scanner.findNextMatch(OnigString('abc 42'), 0)!;
      expect(m.captureIndices[0].start, region.beg[0]);
      expect(m.captureIndices[0].end, region.end[0]);

      r.dispose();
      scanner.dispose();
    });
  });
}
