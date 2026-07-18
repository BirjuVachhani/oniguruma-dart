// Example usage of oniguruma_native — the real Oniguruma C engine driven from
// Dart (via dart:ffi on IO, WebAssembly on web) behind a
// vscode-oniguruma-compatible OnigScanner. This is the API you'd use to drive a
// TextMate grammar / Shiki tokenizer.
//
// Run on the VM:  dart run example/oniguruma_native_example.dart
// ignore_for_file: avoid_print

import 'package:oniguruma_native/oniguruma_native.dart';

Future<void> main() async {
  // On web, the WebAssembly module is instantiated asynchronously, so load it
  // once before use. It resolves a local `web/oniguruma_native.wasm` (created by
  // `dart run oniguruma_native:setup`) or falls back to the GitHub Release. On IO
  // (dart:ffi) this is a no-op, so the same startup code is portable everywhere.
  await loadWasm();

  print('oniguruma ${onigVersion()}');

  // A scanner compiles several patterns at once and, from a given position,
  // returns the left-most/earliest match across all of them — exactly the
  // operation a tokenizer performs for each token.
  final scanner = OnigScanner([r'\d+', r'[a-z]+', r'\s+']);
  final input = OnigString('ab 12');

  var pos = 0;
  while (true) {
    final m = scanner.findNextMatch(input, pos);
    if (m == null) break;
    final span = m.captureIndices.first; // whole match, in UTF-16 code units
    final text = input.text.substring(span.start, span.end);
    print(
      'pattern #${m.index} matched "$text" at [${span.start}, ${span.end})',
    );
    pos = span.end > pos ? span.end : pos + 1;
  }

  // scanCount runs the whole non-overlapping scan inside the engine in a single
  // crossing (one FFI call on IO / one JS→wasm call on web).
  print('total matches: ${scanner.scanCount(input)}');

  input.dispose();
  scanner.dispose();
}
