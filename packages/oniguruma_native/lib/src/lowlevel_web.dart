/// Web (WebAssembly) implementation of the low-level Oniguruma C API (Layer 0).
///
/// The raw `onig_*` structs can't cross `js_interop`, so this drives the same
/// engine through small flat-int **shim accessors** (`onig_shim_regex_new`,
/// `onig_shim_search`, …, in `src/oniguruma_shim.c`) — all handles are heap
/// offsets and all results are ints/byte arrays. The public surface is identical
/// to the FFI backend (`lowlevel_ffi.dart`) and the pure-Dart `oniguruma_dart`,
/// so low-level code is swappable across all of them.
///
/// Requires the wasm module to be loaded first: `await loadWasm()`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'lowlevel_common.dart';
import 'web/wasm_bindings.dart';

export 'lowlevel_common.dart' show OnigRegion, OnigException, RegSetLead;

/// Default case-fold flag (accepted for parity; the native `onig_new` applies
/// its own default fold, so a non-default value is a no-op here too).
const int onigCaseFoldDefault = 1 << 30;

const int _capRegs = 64; // max capture groups read back per match
const int _capNames = 32; // max group numbers read back per name

OnigWasmModule get _m => OnigWasmModule.instance;

/// A built-in character encoding (`OnigEncoding`), selected by shim id.
class OnigEncoding {
  const OnigEncoding._(this.id, this.name);
  final int id;
  final String name;
  @override
  String toString() => 'OnigEncoding($name)';
}

/// A built-in syntax (`OnigSyntaxType*`), selected by shim id.
class OnigSyntax {
  const OnigSyntax._(this.id, this.name);
  final int id;
  final String name;
  @override
  String toString() => 'OnigSyntax($name)';
}

const OnigEncoding utf8Encoding = OnigEncoding._(0, 'UTF-8');
const OnigEncoding asciiEncoding = OnigEncoding._(1, 'US-ASCII');
const OnigSyntax onigSyntaxOniguruma = OnigSyntax._(0, 'Oniguruma');
const OnigSyntax onigSyntaxRuby = OnigSyntax._(1, 'Ruby');
const OnigSyntax onigSyntaxDefault = onigSyntaxOniguruma;

/// Write [bytes] into a fresh heap allocation; returns the pointer (caller frees).
int _alloc(Uint8List bytes) {
  final p = _m.malloc(bytes.isEmpty ? 1 : bytes.length);
  _m.writeBytes(p, bytes);
  return p;
}

String _errorMessage(int code) {
  final buf = _m.malloc(96);
  try {
    final len = _m.errorString(code, buf, 90);
    if (len <= 0) return 'Oniguruma error $code';
    return utf8.decode(_m.readBytes(buf, len), allowMalformed: true);
  } finally {
    _m.free(buf);
  }
}

/// Copy `numRegs` + `beg`/`end` from the shim's readback arrays into [region].
void _readRegion(int nrPtr, int begPtr, int endPtr, OnigRegion region) {
  final n = _m.readInt32(nrPtr);
  final begs = _m.readInt32List(begPtr, n);
  final ends = _m.readInt32List(endPtr, n);
  region.resize(n);
  for (var i = 0; i < n; i++) {
    region.beg[i] = begs[i];
    region.end[i] = ends[i];
  }
}

/// A compiled pattern (`regex_t*`, a wasm heap offset). Call [dispose] when done
/// (unless it was added to an [OnigRegSet], which then owns it).
class Regex {
  Regex._(this._ptr);

  final int _ptr;
  bool _freed = false;
  bool _ownedBySet = false;

  int get _handle {
    if (_freed) throw StateError('Regex used after dispose()');
    return _ptr;
  }

  /// Free the native pattern (`onig_free`). Idempotent; a no-op once added to an
  /// [OnigRegSet] (the set frees it).
  void dispose() {
    if (_freed || _ownedBySet) return;
    _freed = true;
    _m.regexFree(_ptr);
  }
}

/// Compile [pattern] `[0, end)` into a [Regex] (`onig_new`). Throws
/// [OnigException] on a malformed pattern.
Regex onigNew(
  Uint8List pattern,
  int end,
  OnigEncoding enc,
  OnigSyntax syntax,
  int options, {
  int caseFoldFlag = onigCaseFoldDefault,
}) {
  final m = _m;
  final patPtr = m.malloc(end == 0 ? 1 : end);
  if (end > 0) m.writeBytes(patPtr, Uint8List.sublistView(pattern, 0, end));
  final errOut = m.malloc(4);
  try {
    final handle = m.regexNew(patPtr, end, options, enc.id, syntax.id, errOut);
    if (handle == 0) {
      final code = m.readInt32(errOut);
      throw OnigException(code, _errorMessage(code));
    }
    return Regex._(handle);
  } finally {
    m.free(patPtr);
    m.free(errOut);
  }
}

/// Search [str] `[start, range)` within `[0, end)` for [reg] (`onig_search`).
/// Returns the match start byte offset (>= 0), `ONIG_MISMATCH` (-1), or a
/// negative error code; fills [region] on a match.
int onigSearch(
  Regex reg,
  Uint8List str,
  int end,
  int start,
  int range,
  OnigRegion? region, {
  int option = 0,
}) {
  final m = _m;
  final sp = _alloc(str);
  final nr = m.malloc(4);
  final beg = m.malloc(4 * _capRegs);
  final endp = m.malloc(4 * _capRegs);
  try {
    final r = m.search(
      reg._handle,
      sp,
      end,
      start,
      range,
      option,
      nr,
      beg,
      endp,
      _capRegs,
    );
    if (r >= 0 && region != null) _readRegion(nr, beg, endp, region);
    return r;
  } finally {
    m.free(sp);
    m.free(nr);
    m.free(beg);
    m.free(endp);
  }
}

/// Anchored match of [reg] at [at] within `[0, end)` (`onig_match`). Returns the
/// matched byte length (>= 0) or a negative code; fills [region] on a match.
int onigMatch(
  Regex reg,
  Uint8List str,
  int end,
  int at,
  OnigRegion? region, {
  int option = 0,
}) {
  final m = _m;
  final sp = _alloc(str);
  final nr = m.malloc(4);
  final beg = m.malloc(4 * _capRegs);
  final endp = m.malloc(4 * _capRegs);
  try {
    final r = m.match(reg._handle, sp, end, at, option, nr, beg, endp, _capRegs);
    if (r >= 0 && region != null) _readRegion(nr, beg, endp, region);
    return r;
  } finally {
    m.free(sp);
    m.free(nr);
    m.free(beg);
    m.free(endp);
  }
}

/// Number of capture groups in [reg], excluding the whole match.
int onigNumberOfCaptures(Regex reg) => _m.numberOfCaptures(reg._handle);

/// Number of distinct group names in [reg].
int onigNumberOfNames(Regex reg) => _m.numberOfNames(reg._handle);

/// The capture-group numbers bound to [name] in [reg]. Empty if not a name.
List<int> onigNameToGroupNumbers(Regex reg, String name) {
  final m = _m;
  final nb = utf8.encode(name);
  final np = _alloc(nb);
  final out = m.malloc(4 * _capNames);
  try {
    final count = m.nameToGroupNumbers(reg._handle, np, nb.length, out, _capNames);
    if (count <= 0) return const <int>[];
    final n = count > _capNames ? _capNames : count;
    return m.readInt32List(out, n).toList();
  } finally {
    m.free(np);
    m.free(out);
  }
}

/// The backref group number for [name] (`onig_name_to_backref_number`); the
/// [region] disambiguation argument is ignored on web. Returns a negative code
/// when the name is undefined.
int onigNameToBackrefNumber(Regex reg, String name, [OnigRegion? region]) {
  final m = _m;
  final nb = utf8.encode(name);
  final np = _alloc(nb);
  try {
    return m.nameToBackrefNumber(reg._handle, np, nb.length);
  } finally {
    m.free(np);
  }
}

/// A set of compiled patterns searched together (`OnigRegSet`).
///
/// A [Regex] added to a set is **owned** by the set: [dispose]ing the set frees
/// it, and the regex's own [Regex.dispose] becomes a no-op.
class OnigRegSet {
  OnigRegSet() {
    final h = _m.regsetNew();
    if (h == 0) {
      throw const OnigException(-1, 'onig_regset_new failed');
    }
    _set = h;
  }

  late final int _set;
  final List<Regex> _regexes = <Regex>[];
  bool _freed = false;

  /// The region of the most recent successful [search].
  OnigRegion? region;

  /// Match start byte offset of the most recent successful [search].
  int matchPos = -1;

  int add(Regex reg) {
    final r = _m.regsetAdd(_set, reg._handle);
    if (r != 0) throw OnigException(r, _errorMessage(r));
    reg._ownedBySet = true;
    _regexes.add(reg);
    return _regexes.length - 1;
  }

  int get length => _regexes.length;
  Regex operator [](int i) => _regexes[i];

  int search(
    Uint8List str,
    int end,
    int start,
    int range, {
    RegSetLead lead = RegSetLead.positionLead,
  }) {
    final m = _m;
    final sp = _alloc(str);
    final mp = m.malloc(4);
    final nr = m.malloc(4);
    final beg = m.malloc(4 * _capRegs);
    final endp = m.malloc(4 * _capRegs);
    try {
      final idx = m.regsetSearch(
        _set,
        sp,
        end,
        start,
        range,
        lead == RegSetLead.regexLead ? 1 : 0,
        0,
        mp,
        nr,
        beg,
        endp,
        _capRegs,
      );
      if (idx >= 0) {
        matchPos = m.readInt32(mp);
        _readRegion(nr, beg, endp, region ??= OnigRegion());
      } else {
        matchPos = -1;
      }
      return idx;
    } finally {
      m.free(sp);
      m.free(mp);
      m.free(nr);
      m.free(beg);
      m.free(endp);
    }
  }

  /// Free the set and every regex it contains (`onig_regset_free`). Idempotent.
  void dispose() {
    if (_freed) return;
    _freed = true;
    _m.regsetFree(_set);
  }
}
