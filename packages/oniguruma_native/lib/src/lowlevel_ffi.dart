/// Native (dart:ffi) implementation of the low-level Oniguruma C API (Layer 0).
///
/// Drives the engine through the flat-int **shim accessors** (`onig_shim_*` in
/// `src/oniguruma_shim.c`) rather than binding the raw `onig_*` symbols. On
/// Windows a DLL only exports `__declspec(dllexport)` symbols, so the raw
/// functions and the encoding/syntax data globals aren't resolvable there; the
/// shim (which IS exported) keeps all struct/ABI/global handling in C and works
/// on every platform. This is the same path the web backend uses, so the two
/// backends share one ABI and this API matches `lowlevel_web.dart` and the
/// pure-Dart `oniguruma_dart` exactly. Subjects/patterns are `Uint8List` with
/// **byte offsets**.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart' as c;
import 'lowlevel_common.dart';

export 'lowlevel_common.dart' show OnigRegion, OnigException, RegSetLead;

/// Default case-fold flag (`ONIGENC_CASE_FOLD_MIN`). Accepted by [onigNew] for
/// signature parity; the native `onig_new` always applies its own default fold,
/// so a non-default value is a no-op in this backend.
const int onigCaseFoldDefault = 1 << 30;

const int _capRegs = 64; // max capture groups read back per match
const int _capNames = 32; // max group numbers read back per name

/// A built-in character encoding (`OnigEncoding`), selected by shim id. Only the
/// encodings whose globals survive in the prebuilt libraries are available here
/// (more require a prebuilt refresh); `oniguruma_dart` implements the full set.
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

/// The default syntax (`ONIG_SYNTAX_DEFAULT`), i.e. Oniguruma.
const OnigSyntax onigSyntaxDefault = onigSyntaxOniguruma;

Pointer<Uint8> _copyBytes(Uint8List src, int len) {
  final p = malloc<Uint8>(len == 0 ? 1 : len);
  if (len > 0) p.asTypedList(len).setRange(0, len, src);
  return p;
}

String _errorMessage(int code) {
  final buf = malloc<Uint8>(96);
  try {
    final len = c.shimErrorString(code, buf, 90);
    if (len <= 0) return 'Oniguruma error $code';
    return utf8.decode(buf.asTypedList(len), allowMalformed: true);
  } finally {
    malloc.free(buf);
  }
}

void _readRegion(
  Pointer<Int32> nr,
  Pointer<Int32> beg,
  Pointer<Int32> end,
  OnigRegion region,
) {
  final n = nr.value;
  region.resize(n);
  for (var i = 0; i < n; i++) {
    region.beg[i] = beg[i];
    region.end[i] = end[i];
  }
}

/// A compiled pattern (`regex_t*`). Holds native memory; call [dispose] when
/// done (unless it was handed to an [OnigRegSet], which then owns it).
class Regex {
  Regex._(this._ptr);

  final Pointer<c.ShimRegex> _ptr;
  bool _freed = false;
  bool _ownedBySet = false;

  Pointer<c.ShimRegex> get _handle {
    if (_freed) throw StateError('Regex used after dispose()');
    return _ptr;
  }

  /// Free the native pattern (`onig_free`). Idempotent; a no-op once the regex
  /// has been added to an [OnigRegSet] (the set frees it).
  void dispose() {
    if (_freed || _ownedBySet) return;
    _freed = true;
    c.shimRegexFree(_ptr);
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
  final patPtr = _copyBytes(pattern, end);
  final errOut = malloc<Int32>();
  try {
    final handle = c.shimRegexNew(patPtr, end, options, enc.id, syntax.id, errOut);
    if (handle == nullptr) {
      final code = errOut.value;
      throw OnigException(code, _errorMessage(code));
    }
    return Regex._(handle);
  } finally {
    malloc.free(patPtr);
    malloc.free(errOut);
  }
}

/// Search [str] `[start, range)` within `[0, end)` for [reg] (`onig_search`).
/// Returns the match start byte offset (>= 0), `ONIG_MISMATCH` (-1), or a
/// negative error code; fills [region] when a match is found.
int onigSearch(
  Regex reg,
  Uint8List str,
  int end,
  int start,
  int range,
  OnigRegion? region, {
  int option = 0,
}) {
  final sp = _copyBytes(str, str.length);
  final nr = malloc<Int32>();
  final beg = malloc<Int32>(_capRegs);
  final endp = malloc<Int32>(_capRegs);
  try {
    final r = c.shimSearch(
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
    malloc.free(sp);
    malloc.free(nr);
    malloc.free(beg);
    malloc.free(endp);
  }
}

/// Anchored match of [reg] at [at] within `[0, end)` (`onig_match`). Returns the
/// matched byte length (>= 0), or a negative code; fills [region] on a match.
int onigMatch(
  Regex reg,
  Uint8List str,
  int end,
  int at,
  OnigRegion? region, {
  int option = 0,
}) {
  final sp = _copyBytes(str, str.length);
  final nr = malloc<Int32>();
  final beg = malloc<Int32>(_capRegs);
  final endp = malloc<Int32>(_capRegs);
  try {
    final r = c.shimMatch(reg._handle, sp, end, at, option, nr, beg, endp, _capRegs);
    if (r >= 0 && region != null) _readRegion(nr, beg, endp, region);
    return r;
  } finally {
    malloc.free(sp);
    malloc.free(nr);
    malloc.free(beg);
    malloc.free(endp);
  }
}

/// Number of capture groups in [reg], excluding the whole match.
int onigNumberOfCaptures(Regex reg) => c.shimNumberOfCaptures(reg._handle);

/// Number of distinct group names in [reg].
int onigNumberOfNames(Regex reg) => c.shimNumberOfNames(reg._handle);

/// The capture-group numbers bound to [name] in [reg]. Empty if not a name.
List<int> onigNameToGroupNumbers(Regex reg, String name) {
  final nb = utf8.encode(name);
  final np = _copyBytes(nb, nb.length);
  final out = malloc<Int32>(_capNames);
  try {
    final count = c.shimNameToGroupNumbers(reg._handle, np, nb.length, out, _capNames);
    if (count <= 0) return const <int>[];
    final n = count > _capNames ? _capNames : count;
    return List<int>.generate(n, (i) => out[i]);
  } finally {
    malloc.free(np);
    malloc.free(out);
  }
}

/// The backref group number for [name] (`onig_name_to_backref_number`). The
/// [region] disambiguation argument is ignored in this backend. Returns a
/// negative code when the name is undefined.
int onigNameToBackrefNumber(Regex reg, String name, [OnigRegion? region]) {
  final nb = utf8.encode(name);
  final np = _copyBytes(nb, nb.length);
  try {
    return c.shimNameToBackrefNumber(reg._handle, np, nb.length);
  } finally {
    malloc.free(np);
  }
}

/// A set of compiled patterns searched together (`OnigRegSet`).
///
/// A [Regex] added to a set is **owned** by the set: [dispose]ing the set frees
/// it, and the regex's own [Regex.dispose] becomes a no-op.
class OnigRegSet {
  OnigRegSet() {
    final h = c.shimRegsetNew();
    if (h == nullptr) {
      throw const OnigException(-1, 'onig_regset_new failed');
    }
    _set = h;
  }

  late final Pointer<c.ShimRegSet> _set;
  final List<Regex> _regexes = <Regex>[];
  bool _freed = false;

  /// The region of the most recent successful [search].
  OnigRegion? region;

  /// Match start byte offset of the most recent successful [search].
  int matchPos = -1;

  int add(Regex reg) {
    final r = c.shimRegsetAdd(_set, reg._handle);
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
    final sp = _copyBytes(str, str.length);
    final mp = malloc<Int32>();
    final nr = malloc<Int32>();
    final beg = malloc<Int32>(_capRegs);
    final endp = malloc<Int32>(_capRegs);
    try {
      final idx = c.shimRegsetSearch(
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
        matchPos = mp.value;
        _readRegion(nr, beg, endp, region ??= OnigRegion());
      } else {
        matchPos = -1;
      }
      return idx;
    } finally {
      malloc.free(sp);
      malloc.free(mp);
      malloc.free(nr);
      malloc.free(beg);
      malloc.free(endp);
    }
  }

  /// Free the set and every regex it contains (`onig_regset_free`). Idempotent.
  void dispose() {
    if (_freed) return;
    _freed = true;
    c.shimRegsetFree(_set);
  }
}
