// Proves the package compiles for web (no dart:ffi leakage) and that the web
// backend's API is wired. Not a runtime test — the check is that
// `dart compile js` and `dart compile wasm` both succeed.
//
//   dart compile js   tool/web_smoke.dart -o /tmp/oniguruma_web_smoke.js
//   dart compile wasm tool/web_smoke.dart -o /tmp/oniguruma_web_smoke.wasm
// ignore_for_file: avoid_print

import 'package:oniguruma_native/oniguruma_native.dart';

Future<void> main() async {
  await loadWasm(); // loads the embedded module on web; no-op on IO
  print('isOnigurumaSupported = $isOnigurumaSupported');
  print('oniguruma ${onigVersion()}');

  final scanner = OnigScanner([r'\d+']);
  final s = OnigString('abc123');
  print(scanner.findNextMatch(s, 0)?.captureIndices.first.start);
  print('scanCount = ${scanner.scanCount(s)}');
  s.dispose();
  scanner.dispose();
}
