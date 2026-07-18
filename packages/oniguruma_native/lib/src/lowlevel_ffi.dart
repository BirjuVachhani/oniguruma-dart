/// Native (dart:ffi) implementation of the low-level Oniguruma C API (Layer 0).
///
/// Binds the real `onig_*` functions directly (see [bindings]) and presents them
/// with the same names/shapes as the sibling `oniguruma_dart` package, so
/// low-level code is swappable between the two. Subjects and patterns are
/// `Uint8List` with **byte offsets**, exactly like the C library.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart' as c;
import 'lowlevel_common.dart';

export 'lowlevel_common.dart' show OnigRegion, OnigException, RegSetLead;

/// Default case-fold flag (`ONIGENC_CASE_FOLD_MIN`). Accepted by [onigNew] for
/// signature parity with `oniguruma_dart`; the native `onig_new` always applies
/// its own default fold, so a non-default value is a no-op in this backend.
const int onigCaseFoldDefault = 1 << 30;

/// A built-in character encoding (`OnigEncoding`). Only the encodings whose
/// globals survive in the prebuilt libraries are available here (more require a
/// prebuilt refresh); `oniguruma_dart` implements the full set.
class OnigEncoding {
  OnigEncoding._(this._ptr, this.name);
  final Pointer<c.OnigEncodingType> _ptr;
  final String name;
  @override
  String toString() => 'OnigEncoding($name)';
}

/// A built-in syntax (`OnigSyntaxType*`).
class OnigSyntax {
  OnigSyntax._(this._ptr, this.name);
  final Pointer<c.OnigSyntaxTypeStruct> _ptr;
  final String name;
  @override
  String toString() => 'OnigSyntax($name)';
}

final OnigEncoding utf8Encoding = OnigEncoding._(
  Native.addressOf<c.OnigEncodingType>(c.gEncUtf8),
  'UTF-8',
);
final OnigEncoding asciiEncoding = OnigEncoding._(
  Native.addressOf<c.OnigEncodingType>(c.gEncAscii),
  'US-ASCII',
);

final OnigSyntax onigSyntaxOniguruma = OnigSyntax._(
  Native.addressOf<c.OnigSyntaxTypeStruct>(c.gSynOniguruma),
  'Oniguruma',
);
final OnigSyntax onigSyntaxRuby = OnigSyntax._(
  Native.addressOf<c.OnigSyntaxTypeStruct>(c.gSynRuby),
  'Ruby',
);

/// The default syntax (`ONIG_SYNTAX_DEFAULT`), i.e. Oniguruma.
final OnigSyntax onigSyntaxDefault = onigSyntaxOniguruma;

/// A compiled pattern (`regex_t*`). Holds native memory; call [dispose] when
/// done (unless it was handed to an [OnigRegSet], which then owns it).
class Regex {
  Regex._(this._ptr);

  final Pointer<c.OnigRegexT> _ptr;
  bool _freed = false;
  bool _ownedBySet = false;

  Pointer<c.OnigRegexT> get _handle {
    if (_freed) throw StateError('Regex used after dispose()');
    return _ptr;
  }

  /// Free the native pattern (`onig_free`). Idempotent; a no-op once the regex
  /// has been added to an [OnigRegSet] (the set frees it).
  void dispose() {
    if (_freed || _ownedBySet) return;
    _freed = true;
    c.onigFree(_ptr);
  }
}

String _errorMessage(int code) {
  const maxLen = 90; // ONIG_MAX_ERROR_MESSAGE_LEN
  final buf = malloc<Uint8>(maxLen + 1);
  try {
    final len = c.onigErrorCodeToStr(buf, code);
    if (len <= 0) return 'Oniguruma error $code';
    return utf8.decode(buf.asTypedList(len), allowMalformed: true);
  } finally {
    malloc.free(buf);
  }
}

Pointer<Uint8> _copyBytes(Uint8List src, int len) {
  final p = malloc<Uint8>(len == 0 ? 1 : len);
  if (len > 0) p.asTypedList(len).setRange(0, len, src);
  return p;
}

void _copyRegionOut(Pointer<c.OnigRegionStruct> src, OnigRegion dst) {
  final ref = src.ref;
  final nr = ref.numRegs;
  dst.resize(nr);
  final beg = ref.beg;
  final end = ref.end;
  for (var i = 0; i < nr; i++) {
    dst.beg[i] = beg[i];
    dst.end[i] = end[i];
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
  final regOut = malloc<Pointer<c.OnigRegexT>>();
  try {
    final r = c.onigNew(
      regOut,
      patPtr,
      patPtr + end,
      options,
      enc._ptr,
      syntax._ptr,
      nullptr, // OnigErrorInfo* — omitted; message via onig_error_code_to_str
    );
    if (r != 0) {
      // 0 == ONIG_NORMAL
      throw OnigException(r, _errorMessage(r));
    }
    return Regex._(regOut.value);
  } finally {
    malloc.free(patPtr);
    malloc.free(regOut);
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
  final nreg = c.onigRegionNew();
  try {
    final r = c.onigSearch(
      reg._handle,
      sp,
      sp + end,
      sp + start,
      sp + range,
      nreg,
      option,
    );
    if (r >= 0 && region != null) _copyRegionOut(nreg, region);
    return r;
  } finally {
    c.onigRegionFree(nreg, 1);
    malloc.free(sp);
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
  final nreg = c.onigRegionNew();
  try {
    final r = c.onigMatch(reg._handle, sp, sp + end, sp + at, nreg, option);
    if (r >= 0 && region != null) _copyRegionOut(nreg, region);
    return r;
  } finally {
    c.onigRegionFree(nreg, 1);
    malloc.free(sp);
  }
}

/// Number of capture groups in [reg], excluding the whole match
/// (`onig_number_of_captures`).
int onigNumberOfCaptures(Regex reg) => c.onigNumberOfCaptures(reg._handle);

/// Number of distinct group names in [reg] (`onig_number_of_names`).
int onigNumberOfNames(Regex reg) => c.onigNumberOfNames(reg._handle);

/// The capture-group numbers bound to [name] in [reg]
/// (`onig_name_to_group_numbers`). Empty if [name] is not a group name.
List<int> onigNameToGroupNumbers(Regex reg, String name) {
  final nb = utf8.encode(name);
  final np = _copyBytes(nb, nb.length);
  final numsOut = malloc<Pointer<Int32>>();
  try {
    final count = c.onigNameToGroupNumbers(
      reg._handle,
      np,
      np + nb.length,
      numsOut,
    );
    if (count <= 0) return const <int>[];
    final arr = numsOut.value; // owned by the regex — do not free
    return List<int>.generate(count, (i) => arr[i]);
  } finally {
    malloc.free(np);
    malloc.free(numsOut);
  }
}

/// The backref group number for [name] (`onig_name_to_backref_number`); uses
/// [region] to disambiguate a duplicated name. Returns a negative code when the
/// name is undefined.
int onigNameToBackrefNumber(Regex reg, String name, [OnigRegion? region]) {
  final nb = utf8.encode(name);
  final np = _copyBytes(nb, nb.length);
  Pointer<c.OnigRegionStruct> nreg = nullptr;
  try {
    if (region != null) {
      nreg = c.onigRegionNew();
      c.onigRegionResize(nreg, region.numRegs);
      final ref = nreg.ref;
      ref.numRegs = region.numRegs;
      for (var i = 0; i < region.numRegs; i++) {
        ref.beg[i] = region.beg[i];
        ref.end[i] = region.end[i];
      }
    }
    return c.onigNameToBackrefNumber(reg._handle, np, np + nb.length, nreg);
  } finally {
    if (nreg != nullptr) c.onigRegionFree(nreg, 1);
    malloc.free(np);
  }
}

/// A set of compiled patterns searched together (`OnigRegSet`).
///
/// A [Regex] added to a set is **owned** by the set: [dispose]ing the set frees
/// it, and the regex's own [Regex.dispose] becomes a no-op.
class OnigRegSet {
  OnigRegSet() {
    final out = malloc<Pointer<c.OnigRegSetT>>();
    try {
      final r = c.onigRegsetNew(out, 0, nullptr);
      if (r != 0) throw OnigException(r, _errorMessage(r));
      _set = out.value;
    } finally {
      malloc.free(out);
    }
  }

  late final Pointer<c.OnigRegSetT> _set;
  final List<Regex> _regexes = <Regex>[];
  bool _freed = false;

  /// The region of the most recent successful [search].
  OnigRegion? region;

  /// Match start byte offset of the most recent successful [search].
  int matchPos = -1;

  /// Add a compiled pattern (`onig_regset_add`); returns its index.
  int add(Regex reg) {
    final r = c.onigRegsetAdd(_set, reg._handle);
    if (r != 0) throw OnigException(r, _errorMessage(r));
    reg._ownedBySet = true;
    _regexes.add(reg);
    return _regexes.length - 1;
  }

  int get length => _regexes.length;
  Regex operator [](int i) => _regexes[i];

  /// Search all patterns over `[start, range)` within `[0, end)`
  /// (`onig_regset_search`). Returns the matching pattern index (and sets
  /// [region] + [matchPos]), or -1 for no match / a negative error code.
  int search(
    Uint8List str,
    int end,
    int start,
    int range, {
    RegSetLead lead = RegSetLead.positionLead,
  }) {
    final sp = _copyBytes(str, str.length);
    final rmatch = malloc<Int32>();
    try {
      final idx = c.onigRegsetSearch(
        _set,
        sp,
        sp + end,
        sp + start,
        sp + range,
        lead == RegSetLead.regexLead ? 1 : 0,
        0,
        rmatch,
      );
      if (idx >= 0) {
        matchPos = rmatch.value;
        final out = region ??= OnigRegion();
        _copyRegionOut(c.onigRegsetGetRegion(_set, idx), out);
      } else {
        matchPos = -1;
      }
      return idx;
    } finally {
      malloc.free(sp);
      malloc.free(rmatch);
    }
  }

  /// Free the set and every regex it contains (`onig_regset_free`). Idempotent.
  void dispose() {
    if (_freed) return;
    _freed = true;
    c.onigRegsetFree(_set);
  }
}
