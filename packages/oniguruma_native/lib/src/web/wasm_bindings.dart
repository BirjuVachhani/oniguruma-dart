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
/// Strings are UTF-8 (see utf8_offsets.dart); Oniguruma reports UTF-8 byte
/// offsets which backend_web.dart maps back to UTF-16 (Dart `String`) indices.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

// --- Browser WebAssembly / global bindings ---------------------------------

@JS('WebAssembly.instantiate')
external JSPromise<JSObject> _wasmInstantiate(
  JSUint8Array bytes,
  JSObject importObject,
);

@JS('WebAssembly.instantiateStreaming')
external JSPromise<JSObject> _wasmInstantiateStreaming(
  JSPromise<_Response> source,
  JSObject importObject,
);

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
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
  external int find(
    int sc,
    int str,
    int endByte,
    int startByte,
    int outNumRegs,
    int beg,
    int end,
    int capacity,
  );
  @JS('onig_shim_scan_count')
  external int scanCount(int sc, int str, int endByte);
  @JS('onig_shim_version')
  external int version();

  // --- Layer 0 (raw onig_* via flat-int shim accessors) ---
  @JS('onig_shim_regex_new')
  external int regexNew(
    int pat,
    int patLen,
    int options,
    int encId,
    int synId,
    int errOut,
  );
  @JS('onig_shim_regex_free')
  external void regexFree(int reg);
  @JS('onig_shim_error_string')
  external int errorString(int code, int buf, int cap);
  @JS('onig_shim_search')
  external int search(
    int reg,
    int str,
    int endByte,
    int startByte,
    int rangeByte,
    int option,
    int outNumRegs,
    int beg,
    int end,
    int capacity,
  );
  @JS('onig_shim_match')
  external int match(
    int reg,
    int str,
    int endByte,
    int atByte,
    int option,
    int outNumRegs,
    int beg,
    int end,
    int capacity,
  );
  @JS('onig_shim_number_of_captures')
  external int numberOfCaptures(int reg);
  @JS('onig_shim_number_of_names')
  external int numberOfNames(int reg);
  @JS('onig_shim_name_to_group_numbers')
  external int nameToGroupNumbers(int reg, int name, int nameLen, int out, int cap);
  @JS('onig_shim_name_to_backref_number')
  external int nameToBackrefNumber(int reg, int name, int nameLen);
  @JS('onig_shim_regset_new')
  external int regsetNew();
  @JS('onig_shim_regset_add')
  external int regsetAdd(int set, int reg);
  @JS('onig_shim_regset_search')
  external int regsetSearch(
    int set,
    int str,
    int endByte,
    int startByte,
    int rangeByte,
    int lead,
    int option,
    int outMatchPos,
    int outNumRegs,
    int beg,
    int end,
    int capacity,
  );
  @JS('onig_shim_regset_free')
  external void regsetFree(int set);

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
    _install(resultObj);
  }

  /// Instantiates the module fetched from [url]. Idempotent.
  ///
  /// Prefers `WebAssembly.instantiateStreaming` — it compiles while downloading
  /// and lets the browser cache the compiled module — and falls back to
  /// fetch → arrayBuffer → instantiate when the server sends the wrong MIME type
  /// (streaming requires `application/wasm`). Throws a [StateError] if the
  /// resource is missing (e.g. a 404 when `setup` was never run), so callers can
  /// fall back to another URL.
  static Future<void> loadFromUrl(String url) async {
    if (_instance != null) return;
    JSObject resultObj;
    try {
      resultObj = await _wasmInstantiateStreaming(
        _fetch(url.toJS),
        _buildImports(),
      ).toDart;
    } catch (_) {
      // Wrong MIME, missing file, or no streaming support: refetch explicitly so
      // we can distinguish "absent" (404) from "served but not application/wasm".
      final resp = await _fetch(url.toJS).toDart;
      if (!resp.ok) {
        throw StateError('fetch $url failed with HTTP ${resp.status}');
      }
      final buf = await resp.arrayBuffer().toDart;
      resultObj = await _wasmInstantiate(
        buf.toDart.asUint8List().toJS,
        _buildImports(),
      ).toDart;
    }
    _install(resultObj);
  }

  /// Reads exports from an `instantiate`/`instantiateStreaming` result, runs the
  /// reactor initializer (libc ctors), and stores the winning singleton.
  static void _install(JSObject resultObj) {
    final exports = _InstantiateResult(resultObj).instance.exports;
    exports.initialize?.callAsFunction();
    _instance = OnigWasmModule._(exports);
  }

  // --- allocator + shim calls ---
  int malloc(int size) => _exports.malloc(size);
  void free(int ptr) => _exports.free(ptr);
  int scannerNew(int patterns, int patLens, int count) =>
      _exports.scannerNew(patterns, patLens, count);
  void scannerFree(int sc) => _exports.scannerFree(sc);
  int find(
    int sc,
    int str,
    int endByte,
    int startByte,
    int outNumRegs,
    int beg,
    int end,
    int capacity,
  ) => _exports.find(
    sc,
    str,
    endByte,
    startByte,
    outNumRegs,
    beg,
    end,
    capacity,
  );
  int scanCount(int sc, int str, int endByte) =>
      _exports.scanCount(sc, str, endByte);
  int version() => _exports.version();

  // --- Layer 0 (raw onig_* via the flat-int shim accessors) ---
  int regexNew(int pat, int patLen, int options, int encId, int synId, int errOut) =>
      _exports.regexNew(pat, patLen, options, encId, synId, errOut);
  void regexFree(int reg) => _exports.regexFree(reg);
  int errorString(int code, int buf, int cap) =>
      _exports.errorString(code, buf, cap);
  int search(int reg, int str, int endByte, int startByte, int rangeByte,
          int option, int outNumRegs, int beg, int end, int capacity) =>
      _exports.search(reg, str, endByte, startByte, rangeByte, option,
          outNumRegs, beg, end, capacity);
  int match(int reg, int str, int endByte, int atByte, int option,
          int outNumRegs, int beg, int end, int capacity) =>
      _exports.match(
          reg, str, endByte, atByte, option, outNumRegs, beg, end, capacity);
  int numberOfCaptures(int reg) => _exports.numberOfCaptures(reg);
  int numberOfNames(int reg) => _exports.numberOfNames(reg);
  int nameToGroupNumbers(int reg, int name, int nameLen, int out, int cap) =>
      _exports.nameToGroupNumbers(reg, name, nameLen, out, cap);
  int nameToBackrefNumber(int reg, int name, int nameLen) =>
      _exports.nameToBackrefNumber(reg, name, nameLen);
  int regsetNew() => _exports.regsetNew();
  int regsetAdd(int set, int reg) => _exports.regsetAdd(set, reg);
  int regsetSearch(int set, int str, int endByte, int startByte, int rangeByte,
          int lead, int option, int outMatchPos, int outNumRegs, int beg,
          int end, int capacity) =>
      _exports.regsetSearch(set, str, endByte, startByte, rangeByte, lead,
          option, outMatchPos, outNumRegs, beg, end, capacity);
  void regsetFree(int set) => _exports.regsetFree(set);

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

  /// Reads [len] bytes starting at heap offset [ptr] (e.g. an error message).
  Uint8List readBytes(int ptr, int len) {
    if (len <= 0) return Uint8List(0);
    final dv = _DataView(_exports.memory.buffer);
    final out = Uint8List(len);
    for (var i = 0; i < len; i++) {
      out[i] = dv.getUint8(ptr + i);
    }
    return out;
  }

  /// Reads a NUL-terminated ASCII C string at [ptr] (e.g. the version).
  String readCString(int ptr) {
    final dv = _DataView(_exports.memory.buffer);
    final sb = StringBuffer();
    for (var i = ptr; ; i++) {
      final c = dv.getUint8(i);
      if (c == 0) break;
      sb.writeCharCode(c);
    }
    return sb.toString();
  }
}
