/// Low-level `dart:js_interop` bridge to the Oniguruma WebAssembly module.
///
/// The module is a wasm32-wasi *reactor* build of the exact same shim
/// (`src/oniguruma_shim.c`) + Oniguruma the FFI backend uses, so its behaviour
/// is byte-identical. It is a **separate** wasm instance that the JS host
/// creates via `WebAssembly.instantiate`; Dart never links it. This works the
/// same under dart2js and dart2wasm because everything goes through the browser
/// `WebAssembly` API and `dart:js_interop`.
///
/// There is no shared memory between Dart and the module, so subjects/patterns
/// are marshalled into the module's linear memory through its exported
/// `malloc`/`free`, exactly as the FFI backend marshals into native memory.
/// Strings are UTF-16LE (wasm memory is little-endian), so match offsets map
/// 1:1 to Dart `String` indices after dividing byte offsets by 2.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

// --- Browser WebAssembly / global bindings ---------------------------------

@JS('WebAssembly.instantiate')
external JSPromise<JSObject> _wasmInstantiate(
    JSUint8Array bytes, JSObject importObject);

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url);

extension type _Response._(JSObject _) implements JSObject {
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type _InstantiateResult(JSObject _) implements JSObject {
  external _Instance get instance;
}

extension type _Instance._(JSObject _) implements JSObject {
  external _Exports get exports;
}

/// The module's exports. Names match the wasm export table (see build_wasm.sh);
/// each shim function takes/returns 32-bit ints that js_interop marshals as JS
/// numbers.
extension type _Exports._(JSObject _) implements JSObject {
  external _Memory get memory;

  external int malloc(int size);
  external void free(int ptr);

  @JS('onig_shim_scanner_new')
  external int scannerNew(int patterns, int patLens, int count);
  @JS('onig_shim_scanner_free')
  external void scannerFree(int sc);
  @JS('onig_shim_find')
  external int find(int sc, int str, int endByte, int startByte, int outNumRegs,
      int beg, int end, int capacity);
  @JS('onig_shim_scan_count')
  external int scanCount(int sc, int str, int endByte);
  @JS('onig_shim_version')
  external int version();

  /// Present on reactor modules; runs libc constructors. Called once after
  /// instantiation.
  @JS('_initialize')
  external JSFunction? get initialize;
}

extension type _Memory._(JSObject _) implements JSObject {
  /// The current backing buffer. Memory growth detaches the old one, so views
  /// are always re-derived from a fresh read of this.
  external JSArrayBuffer get buffer;
}

// Typed-array / DataView views over the module's memory buffer. Constructing a
// view is cheap and never copies the heap; only the small slices we touch cross
// the JS boundary (important for dart2wasm, whose heap is separate from JS).

@JS('Uint8Array')
extension type _U8View._(JSObject _) implements JSObject {
  external factory _U8View(JSArrayBuffer buffer, int byteOffset, int length);
  external void set(JSUint8Array source);
}

@JS('Int32Array')
extension type _I32View._(JSInt32Array _) implements JSInt32Array {
  external factory _I32View(JSArrayBuffer buffer, int byteOffset, int length);
}

@JS('DataView')
extension type _DataView._(JSObject _) implements JSObject {
  external factory _DataView(JSArrayBuffer buffer);
  external int getUint8(int byteOffset);
  external int getInt32(int byteOffset, JSBoolean littleEndian);
  external void setUint32(int byteOffset, int value, JSBoolean littleEndian);
  external void setInt32(int byteOffset, int value, JSBoolean littleEndian);
}

// WASI import stubs. The reactor build imports exactly three functions
// (fd_close/fd_seek/fd_write) that libc keeps for its stdio machinery; none is
// reached on the matching path (compiled -DNDEBUG; errors return codes rather
// than printing). Returning 0 (success) is safe and mirrors the Node probe.
// The import object is a plain JS object literal, built with js_interop_unsafe.
JSObject _buildImports() {
  final zero1 = ((JSAny? a) => 0.toJS).toJS;
  final zero4 = ((JSAny? a, JSAny? b, JSAny? c, JSAny? d) => 0.toJS).toJS;
  final wasi = JSObject()
    ..setProperty('fd_close'.toJS, zero1)
    ..setProperty('fd_seek'.toJS, zero4)
    ..setProperty('fd_write'.toJS, zero4);
  return JSObject()..setProperty('wasi_snapshot_preview1'.toJS, wasi);
}

/// A loaded Oniguruma wasm instance plus typed heap access. Instantiation is
/// async (`WebAssembly.instantiate` returns a Promise, and browsers refuse to
/// instantiate a module this size synchronously on the main thread); after
/// [load] resolves, every operation here is synchronous.
class OnigWasmModule {
  OnigWasmModule._(this._exports);

  final _Exports _exports;

  static OnigWasmModule? _instance;

  /// True once [load] has completed successfully.
  static bool get isLoaded => _instance != null;

  /// The loaded module, or a clear error if [load] was never awaited.
  static OnigWasmModule get instance =>
      _instance ??
      (throw StateError(
        'Oniguruma wasm is not loaded. Call `await loadWasm()` once at '
        'startup before constructing an OnigScanner/OnigString on web.',
      ));

  /// Instantiates the module from [bytes] and runs its reactor initializer.
  /// Idempotent: a second call is a no-op (the first winning instance stays).
  static Future<void> load(Uint8List bytes) async {
    if (_instance != null) return;
    final resultObj = await _wasmInstantiate(bytes.toJS, _buildImports()).toDart;
    final exports = _InstantiateResult(resultObj).instance.exports;
    // Reactor modules export `_initialize`; call it once to run libc ctors.
    exports.initialize?.callAsFunction();
    _instance = OnigWasmModule._(exports);
  }

  /// Fetches wasm bytes from [url] (used by `loadWasm(url: ...)`).
  static Future<Uint8List> fetchBytes(String url) async {
    final resp = await _fetch(url.toJS).toDart;
    final buf = await resp.arrayBuffer().toDart;
    return buf.toDart.asUint8List();
  }

  // --- allocator + shim calls ---
  int malloc(int size) => _exports.malloc(size);
  void free(int ptr) => _exports.free(ptr);
  int scannerNew(int patterns, int patLens, int count) =>
      _exports.scannerNew(patterns, patLens, count);
  void scannerFree(int sc) => _exports.scannerFree(sc);
  int find(int sc, int str, int endByte, int startByte, int outNumRegs, int beg,
          int end, int capacity) =>
      _exports.find(sc, str, endByte, startByte, outNumRegs, beg, end, capacity);
  int scanCount(int sc, int str, int endByte) =>
      _exports.scanCount(sc, str, endByte);
  int version() => _exports.version();

  // --- heap access (views re-derived each call; growth detaches buffers) ---

  /// Copies [bytes] into the module's heap at [ptr] in one boundary crossing.
  void writeBytes(int ptr, Uint8List bytes) {
    if (bytes.isEmpty) return;
    _U8View(_exports.memory.buffer, ptr, bytes.length).set(bytes.toJS);
  }

  void writeUint32(int ptr, int value) =>
      _DataView(_exports.memory.buffer).setUint32(ptr, value, true.toJS);

  void writeInt32(int ptr, int value) =>
      _DataView(_exports.memory.buffer).setInt32(ptr, value, true.toJS);

  int readInt32(int ptr) =>
      _DataView(_exports.memory.buffer).getInt32(ptr, true.toJS);

  /// Reads [count] little-endian int32s starting at byte offset [ptr].
  Int32List readInt32List(int ptr, int count) {
    if (count <= 0) return Int32List(0);
    return _I32View(_exports.memory.buffer, ptr, count).toDart;
  }

  /// Reads a NUL-terminated ASCII C string at [ptr] (e.g. the version).
  String readCString(int ptr) {
    final dv = _DataView(_exports.memory.buffer);
    final sb = StringBuffer();
    for (var i = ptr;; i++) {
      final c = dv.getUint8(i);
      if (c == 0) break;
      sb.writeCharCode(c);
    }
    return sb.toString();
  }

  /// Encodes [text] as UTF-16LE bytes (matching the shim's UTF16_LE encoding).
  static Uint8List encodeUtf16le(String text) {
    final units = text.codeUnits;
    final bytes = Uint8List(units.length * 2);
    final bd = ByteData.view(bytes.buffer);
    for (var i = 0; i < units.length; i++) {
      bd.setUint16(i * 2, units[i], Endian.little);
    }
    return bytes;
  }
}
