@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

/// The web wasm ships as a GitHub Release asset, verified against
/// `prebuilt/checksums.sha256` by both `dart run oniguruma_native:setup` (at
/// download time) and the `release-wasm` workflow (before upload). This guards
/// the source of truth those rely on: the committed
/// `prebuilt/web/oniguruma_native.wasm` is a valid module and matches the
/// manifest — so a blob refreshed without an updated checksum (or vice-versa)
/// fails here rather than shipping a mismatch.

/// Resolves a path relative to the package root, independent of the directory
/// `dart test` was invoked from (root workspace vs. package dir).
Future<File> _pkgFile(String relative) async {
  final libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:oniguruma_native/oniguruma_native.dart'),
  );
  // .../lib/oniguruma_native.dart -> lib/ -> package root
  final pkgRoot = File.fromUri(libUri!).parent.parent;
  return File.fromUri(pkgRoot.uri.resolve(relative));
}

void main() {
  test('prebuilt web wasm has a valid WebAssembly header', () async {
    final file = await _pkgFile('prebuilt/web/oniguruma_native.wasm');
    if (!file.existsSync()) {
      // Committed for provenance but not published; a stripped checkout may lack
      // it, and the published package delivers the wasm via the GitHub Release.
      markTestSkipped('prebuilt/web/oniguruma_native.wasm not present');
      return;
    }
    final bytes = await file.readAsBytes();
    expect(bytes, isNotEmpty);
    // "\0asm" magic + version 1 — the 8-byte WebAssembly preamble.
    expect(bytes.sublist(0, 8), [
      0x00,
      0x61,
      0x73,
      0x6d,
      0x01,
      0x00,
      0x00,
      0x00,
    ]);
  });

  test('prebuilt web wasm SHA-256 matches the committed checksum manifest', () async {
    final file = await _pkgFile('prebuilt/web/oniguruma_native.wasm');
    final manifest = await _pkgFile('prebuilt/checksums.sha256');
    if (!file.existsSync() || !manifest.existsSync()) {
      markTestSkipped('prebuilt/web wasm or checksums.sha256 not present');
      return;
    }
    // Manifest lines: "<sha256>␠␠web/oniguruma_native.wasm".
    final line = (await manifest.readAsLines()).firstWhere(
      (l) => l.trimRight().endsWith('web/oniguruma_native.wasm'),
      orElse: () => '',
    );
    expect(
      line,
      isNotEmpty,
      reason: 'no web/oniguruma_native.wasm entry in checksums.sha256',
    );
    final expected = line.split(RegExp(r'\s+')).first.toLowerCase();

    final actual =
        sha256.convert(await file.readAsBytes()).toString().toLowerCase();
    expect(
      actual,
      expected,
      reason:
          'prebuilt/web/oniguruma_native.wasm does not match its checksum — '
          'refresh prebuilt/web and regenerate checksums.sha256',
    );
  });
}
