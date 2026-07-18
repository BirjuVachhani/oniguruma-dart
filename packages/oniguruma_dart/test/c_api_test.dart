import 'dart:convert';
import 'dart:typed_data';

import 'package:oniguruma_dart/oniguruma_dart.dart';
import 'package:test/test.dart';

Regex _compile(String pattern, {int options = OnigOption.none}) {
  final b = Uint8List.fromList(utf8.encode(pattern));
  return onigNew(b, b.length, utf8Encoding, onigSyntaxOniguruma, options);
}

void main() {
  group('Layer 0 introspection (C API)', () {
    test('onigVersion mirrors the ported Oniguruma release', () {
      expect(onigVersion(), '6.9.10');
      expect(onigVersionString, '6.9.10');
    });

    test('onigNumberOfCaptures', () {
      expect(onigNumberOfCaptures(_compile(r'(a)(b)(c)')), 3);
      expect(onigNumberOfCaptures(_compile(r'abc')), 0);
      expect(onigNumberOfCaptures(_compile(r'(a(b))')), 2);
    });

    test('onigNumberOfNames', () {
      expect(onigNumberOfNames(_compile(r'(?<x>a)(?<y>b)')), 2);
      expect(onigNumberOfNames(_compile(r'(a)(b)')), 0);
    });

    test('onigNameToGroupNumbers', () {
      final r = _compile(r'(?<x>a)(?<y>b)');
      expect(onigNameToGroupNumbers(r, 'x'), [1]);
      expect(onigNameToGroupNumbers(r, 'y'), [2]);
      expect(onigNameToGroupNumbers(r, 'z'), isEmpty);
    });

    test('onigNameToBackrefNumber', () {
      final r = _compile(r'(?<x>a)');
      expect(onigNameToBackrefNumber(r, 'x'), 1);
      expect(
        onigNameToBackrefNumber(r, 'nope'),
        OnigErr.undefinedNameReference,
      );
    });
  });

  group('OnigRegion.copyFrom', () {
    test('copies every register from the source', () {
      final r = _compile(r'(a)(b)');
      final bytes = Uint8List.fromList(utf8.encode('ab'));
      final region = OnigRegion();
      expect(onigSearch(r, bytes, 2, 0, 2, region), 0);

      final copy = OnigRegion();
      copy.copyFrom(region);
      expect(copy.numRegs, region.numRegs);
      for (var i = 0; i < region.numRegs; i++) {
        expect(copy.beg[i], region.beg[i]);
        expect(copy.end[i], region.end[i]);
      }
    });
  });
}
