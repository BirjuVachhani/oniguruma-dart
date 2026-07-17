// Regenerates lib/src/web/oniguruma_wasm.g.dart from the committed
// prebuilt/web/oniguruma_native.wasm — the base64 of the wasm module, embedded so
// the web backend loads with zero hosting/fetch.
//
// Run after the prebuild-oniguruma workflow refreshes the wasm blob:
//   dart run tool/gen_wasm_embed.dart
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

void main() {
  final toolDir = File.fromUri(Platform.script).parent; // .../oniguruma_native/tool
  final pkg = toolDir.parent;
  final wasm = File.fromUri(pkg.uri.resolve('prebuilt/web/oniguruma_native.wasm'));
  final out = File.fromUri(pkg.uri.resolve('lib/src/web/oniguruma_wasm.g.dart'));

  if (!wasm.existsSync()) {
    stderr.writeln('missing ${wasm.path}\n'
        'Build it first: WASI_SDK=… ONIG_SRC=… tool/prebuilt/build_wasm.sh');
    exit(1);
  }

  final bytes = wasm.readAsBytesSync();
  final b64 = base64.encode(bytes);

  // Emit the base64 as adjacent string literals (concatenated at compile time,
  // no runtime cost and no embedded whitespace) so no single source line is
  // enormous.
  const width = 100;
  final buf = StringBuffer();
  for (var i = 0; i < b64.length; i += width) {
    final end = (i + width < b64.length) ? i + width : b64.length;
    buf.writeln("    '${b64.substring(i, end)}'");
  }

  out.writeAsStringSync('''
// GENERATED — do not edit by hand.
//
// Base64 of prebuilt/web/oniguruma_native.wasm (Oniguruma 6.9.10 + our shim,
// compiled to wasm32-wasi), embedded so the web backend needs no hosting or
// fetch. Regenerate with: dart run tool/gen_wasm_embed.dart
//
// Source wasm size: ${bytes.length} bytes.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Decodes the embedded Oniguruma wasm module.
Uint8List onigWasmBytes() => base64.decode(_wasmBase64);

const String _wasmBase64 =
${buf.toString().trimRight()};
''');

  print('wrote ${out.path} '
      '(${bytes.length} wasm bytes -> ${b64.length} base64 chars)');
}
