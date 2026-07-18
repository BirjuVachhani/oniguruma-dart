@TestOn('vm')
library;

import 'dart:io';

import 'package:oniguruma_native/src/release.dart';
import 'package:test/test.dart';

/// The web runtime builds the version-matched GitHub Release URL (and `setup`
/// downloads it) from the [packageVersion] constant, which can't be read from
/// `pubspec.yaml` at runtime on web. This guards it against drift: publishing
/// with a stale constant would point the release fallback at the wrong tag.
void main() {
  test('packageVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp(r'^version:\s*(.+)$', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'no `version:` found in pubspec.yaml');
    expect(
      packageVersion,
      match!.group(1)!.trim(),
      reason: 'lib/src/release.dart packageVersion must equal the pubspec version',
    );
  });
}
