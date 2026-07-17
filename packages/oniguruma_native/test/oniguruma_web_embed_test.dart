@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
// The embedded module is what actually ships and loads on web (the raw
// prebuilt/web/*.wasm is .pubignore'd). This is a pure base64 decode — no
// js_interop — so it runs on the plain VM, giving a reliable, headless guard
// that the shipped bytes are exactly the audited artifact. If someone rebuilds
// the wasm but forgets `dart run tool/gen_wasm_embed.dart`, or hand-edits the
// generated file, this fails instead of shipping a stale/corrupt web engine.
import 'package:oniguruma_native/src/web/oniguruma_wasm.g.dart';
import 'package:test/test.dart';

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
  test('embedded wasm decodes to a valid WebAssembly module header', () {
    final bytes = onigWasmBytes();
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

  test(
    'embedded wasm is byte-identical to prebuilt/web/oniguruma_native.wasm',
    () async {
      final file = await _pkgFile('prebuilt/web/oniguruma_native.wasm');
      if (!file.existsSync()) {
        // The raw blob is committed for provenance but not published; skip if a
        // stripped checkout removed it (the checksum test below still guards).
        markTestSkipped('prebuilt/web/oniguruma_native.wasm not present');
        return;
      }
      final onDisk = await file.readAsBytes();
      final embedded = onigWasmBytes();
      expect(
        embedded.length,
        onDisk.length,
        reason: 'embedded base64 is stale — re-run tool/gen_wasm_embed.dart',
      );
      expect(
        embedded,
        orderedEquals(onDisk),
        reason:
            'embedded base64 differs from the prebuilt wasm — '
            're-run tool/gen_wasm_embed.dart',
      );
    },
  );

  test(
    'embedded wasm SHA-256 matches the committed checksum manifest',
    () async {
      final manifest = await _pkgFile('prebuilt/checksums.sha256');
      if (!manifest.existsSync()) {
        markTestSkipped('prebuilt/checksums.sha256 not present');
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

      final actual = sha256.convert(onigWasmBytes()).toString().toLowerCase();
      expect(
        actual,
        expected,
        reason:
            'embedded wasm SHA-256 does not match the audited artifact — '
            'refresh prebuilt/web + re-run tool/gen_wasm_embed.dart',
      );
    },
  );
}
