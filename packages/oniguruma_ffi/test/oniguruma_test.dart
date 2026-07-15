import 'package:oniguruma_ffi/oniguruma_ffi.dart';
import 'package:test/test.dart';

void main() {
  test('native engine is available on this (IO) platform', () {
    expect(isOnigurumaSupported, isTrue);
  });

  test('links and reports a version', () {
    expect(onigVersion(), matches(RegExp(r'^\d+\.\d+\.\d+')));
  });

  test('scanner finds the left-most / earliest pattern', () {
    final scanner = OnigScanner([r'\d+', r'[a-z]+']);
    final s = OnigString('  abc123');
    addTearDown(() {
      s.dispose();
      scanner.dispose();
    });

    final m = scanner.findNextMatch(s, 0);
    expect(m, isNotNull);
    expect(m!.index, 1); // [a-z]+ matches at 2, before \d+ at 5
    expect(m.captureIndices[0].start, 2);
    expect(m.captureIndices[0].end, 5);
  });

  test('capture group offsets are correct (UTF-16 indices)', () {
    final scanner = OnigScanner([r'(\w+)@(\w+)']);
    final s = OnigString('x foo@bar');
    addTearDown(() {
      s.dispose();
      scanner.dispose();
    });

    final m = scanner.findNextMatch(s, 0)!;
    expect(m.captureIndices[0].start, 2); // whole match "foo@bar"
    expect(m.captureIndices[0].end, 9);
    expect(m.captureIndices[1].start, 2); // group 1 "foo"
    expect(m.captureIndices[1].end, 5);
    expect(m.captureIndices[2].start, 6); // group 2 "bar"
    expect(m.captureIndices[2].end, 9);
  });

  test('no match returns null', () {
    final scanner = OnigScanner([r'\d+']);
    final s = OnigString('no digits here');
    addTearDown(() {
      s.dispose();
      scanner.dispose();
    });
    expect(scanner.findNextMatch(s, 0), isNull);
  });

  test('scanCount counts every non-overlapping match in one native call', () {
    final scanner = OnigScanner([r'\w+']);
    final s = OnigString('foo 123 bar');
    addTearDown(() {
      s.dispose();
      scanner.dispose();
    });
    // "foo", "123", "bar" — three non-overlapping runs.
    expect(scanner.scanCount(s), 3);
  });

  test('scanCount agrees with a manual findNextMatch scan loop', () {
    final scanner = OnigScanner([r'\d+', r'[a-z]+']);
    final s = OnigString('ab 12 cd 34 ef');
    addTearDown(() {
      s.dispose();
      scanner.dispose();
    });

    var start = 0, manual = 0;
    while (true) {
      final m = scanner.findNextMatch(s, start);
      if (m == null) break;
      manual++;
      final end = m.captureIndices[0].end;
      start = end > start ? end : start + 1;
    }
    expect(scanner.scanCount(s), manual);
    expect(manual, 5); // ab, 12, cd, 34, ef
  });

  test('scanCount is 0 when nothing matches', () {
    final scanner = OnigScanner([r'\d+']);
    final s = OnigString('no digits here');
    addTearDown(() {
      s.dispose();
      scanner.dispose();
    });
    expect(scanner.scanCount(s), 0);
  });
}
