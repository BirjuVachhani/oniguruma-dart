import 'package:oniguruma_dart/oniguruma_dart.dart';
import 'package:test/test.dart';

void main() {
  group('OnigScanner', () {
    test('tokenizes and reports the winning pattern index', () {
      final s = OnigScanner([r'\d+', r'[a-z]+', r'\s+']);
      final str = OnigString('abc 123');

      final m0 = s.findNextMatch(str, 0)!;
      expect(m0.index, 1); // [a-z]+
      expect(m0.captureIndices[0].start, 0);
      expect(m0.captureIndices[0].end, 3);
      expect(m0.captureIndices[0].length, 3);

      final m1 = s.findNextMatch(str, 3)!;
      expect(m1.index, 2); // \s+
      expect(m1.captureIndices[0].start, 3);
      expect(m1.captureIndices[0].end, 4);

      final m2 = s.findNextMatch(str, 4)!;
      expect(m2.index, 0); // \d+
      expect(m2.captureIndices[0].start, 4);
      expect(m2.captureIndices[0].end, 7);

      expect(s.findNextMatch(str, 7), isNull);
    });

    test('exact-start match wins immediately, earliest pattern on tie', () {
      final s = OnigScanner([r'foo', r'\w+']);
      final m = s.findNextMatch(OnigString('foobar'), 0)!;
      expect(m.index, 0); // both match at 0; earliest pattern wins, breaks
      expect(m.captureIndices[0].end, 3);
    });

    test('left-most wins when nothing matches at the start position', () {
      final s = OnigScanner([r'bar', r'foo']);
      final m = s.findNextMatch(OnigString('xfoobar'), 0)!;
      expect(m.index, 1); // foo@1 beats bar@4
      expect(m.captureIndices[0].start, 1);
    });

    test('forgiving: an uncompilable pattern never matches, index preserved', () {
      final s = OnigScanner([r'(', r'\d+']); // '(' is a compile error
      final m = s.findNextMatch(OnigString('42'), 0)!;
      expect(m.index, 1); // index 0 skipped, not renumbered
      expect(m.captureIndices[0].end, 2);
    });

    test('unmatched optional group reports (-1, -1)', () {
      final s = OnigScanner([r'(a)(b)?']);
      final m = s.findNextMatch(OnigString('a'), 0)!;
      expect(m.captureIndices.length, 3);
      expect(m.captureIndices[1].start, 0);
      expect(m.captureIndices[1].end, 1);
      expect(m.captureIndices[2].start, -1);
      expect(m.captureIndices[2].end, -1);
    });

    test('offsets are UTF-16 code units (BMP + surrogate pair)', () {
      // 'café🎉x': c a f é = 4 units, 🎉 = 2 units (surrogate pair), x @ 6.
      final s = OnigScanner([r'x']);
      final m = s.findNextMatch(OnigString('café🎉x'), 0)!;
      expect(m.captureIndices[0].start, 6);
      expect(m.captureIndices[0].end, 7);
    });

    test('scanCount counts non-overlapping matches in one pass', () {
      final s = OnigScanner([r'\d+', r'[a-z]+', r'\s+']);
      expect(s.scanCount(OnigString('abc 123 def')), 5); // abc _ 123 _ def
    });

    test('empty subject and empty pattern list', () {
      expect(OnigScanner([]).findNextMatch(OnigString('abc'), 0), isNull);
      final s = OnigScanner([r'\d+']);
      expect(s.findNextMatch(OnigString(''), 0), isNull);
      expect(s.scanCount(OnigString('')), 0);
    });

    test('OnigString reports UTF-16 length and UTF-8 byte length', () {
      final str = OnigString('é'); // 1 UTF-16 unit, 2 UTF-8 bytes
      expect(str.length, 1);
      expect(str.byteLength, 2);
    });
  });
}
