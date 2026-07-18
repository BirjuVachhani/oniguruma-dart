// FFI bindings to the C shim (src/oniguruma_shim.c), resolved against the
// `package:oniguruma_native/oniguruma_native` code asset produced by hook/build.dart.
@DefaultAsset('package:oniguruma_native/oniguruma_native')
library;

import 'dart:ffi';

/// Opaque handle to a compiled multi-pattern scanner (C `ShimScanner*`).
final class ShimScanner extends Opaque {}

@Native<
  Pointer<ShimScanner> Function(Pointer<Pointer<Uint8>>, Pointer<Int32>, Int32)
>(symbol: 'onig_shim_scanner_new')
external Pointer<ShimScanner> shimScannerNew(
  Pointer<Pointer<Uint8>> patterns,
  Pointer<Int32> patLens,
  int count,
);

@Native<Void Function(Pointer<ShimScanner>)>(symbol: 'onig_shim_scanner_free')
external void shimScannerFree(Pointer<ShimScanner> sc);

@Native<
  Int32 Function(
    Pointer<ShimScanner>,
    Pointer<Uint8>,
    Int32,
    Int32,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Int32>,
    Int32,
  )
>(symbol: 'onig_shim_find')
external int shimFind(
  Pointer<ShimScanner> sc,
  Pointer<Uint8> str,
  int endByte,
  int startByte,
  Pointer<Int32> outNumRegs,
  Pointer<Int32> beg,
  Pointer<Int32> end,
  int capacity,
);

@Native<Int32 Function(Pointer<ShimScanner>, Pointer<Uint8>, Int32)>(
  symbol: 'onig_shim_scan_count',
)
external int shimScanCount(
  Pointer<ShimScanner> sc,
  Pointer<Uint8> str,
  int endByte,
);

@Native<Pointer<Char> Function()>(symbol: 'onig_shim_version')
external Pointer<Char> shimVersion();

// ---------------------------------------------------------------------------
// Layer 0 — flat-int shim accessors over the raw onig_* API.
//
// These bind the `onig_shim_*` Layer-0 helpers, NOT the raw `onig_*` symbols.
// Reason: on Windows a DLL only exports `__declspec(dllexport)` symbols — that
// covers the shim (SHIM_EXPORT) but NOT the raw `onig_*` functions or the
// encoding/syntax data globals, so binding those directly fails to resolve on
// Windows. Going through the shim keeps all struct/ABI/global handling in C and
// works on every platform (it's also exactly what the web backend does).
// Encodings/syntaxes are selected by id: encoding 0=UTF-8/1=ASCII,
// syntax 0=Oniguruma/1=Ruby (only the globals that survive in the prebuilts).
// ---------------------------------------------------------------------------

/// Opaque `regex_t*` handle from `onig_shim_regex_new`.
final class ShimRegex extends Opaque {}

/// Opaque `OnigRegSet*` handle from `onig_shim_regset_new`.
final class ShimRegSet extends Opaque {}

@Native<
  Pointer<ShimRegex> Function(
    Pointer<Uint8>,
    Int32,
    Int32,
    Int32,
    Int32,
    Pointer<Int32>,
  )
>(symbol: 'onig_shim_regex_new')
external Pointer<ShimRegex> shimRegexNew(
  Pointer<Uint8> pat,
  int patLen,
  int options,
  int encId,
  int synId,
  Pointer<Int32> errOut,
);

@Native<Void Function(Pointer<ShimRegex>)>(symbol: 'onig_shim_regex_free')
external void shimRegexFree(Pointer<ShimRegex> reg);

@Native<Int32 Function(Int32, Pointer<Uint8>, Int32)>(
  symbol: 'onig_shim_error_string',
)
external int shimErrorString(int code, Pointer<Uint8> buf, int cap);

@Native<
  Int32 Function(
    Pointer<ShimRegex>,
    Pointer<Uint8>,
    Int32,
    Int32,
    Int32,
    Int32,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Int32>,
    Int32,
  )
>(symbol: 'onig_shim_search')
external int shimSearch(
  Pointer<ShimRegex> reg,
  Pointer<Uint8> str,
  int endByte,
  int startByte,
  int rangeByte,
  int option,
  Pointer<Int32> outNumRegs,
  Pointer<Int32> beg,
  Pointer<Int32> end,
  int capacity,
);

@Native<
  Int32 Function(
    Pointer<ShimRegex>,
    Pointer<Uint8>,
    Int32,
    Int32,
    Int32,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Int32>,
    Int32,
  )
>(symbol: 'onig_shim_match')
external int shimMatch(
  Pointer<ShimRegex> reg,
  Pointer<Uint8> str,
  int endByte,
  int atByte,
  int option,
  Pointer<Int32> outNumRegs,
  Pointer<Int32> beg,
  Pointer<Int32> end,
  int capacity,
);

@Native<Int32 Function(Pointer<ShimRegex>)>(
  symbol: 'onig_shim_number_of_captures',
)
external int shimNumberOfCaptures(Pointer<ShimRegex> reg);

@Native<Int32 Function(Pointer<ShimRegex>)>(symbol: 'onig_shim_number_of_names')
external int shimNumberOfNames(Pointer<ShimRegex> reg);

@Native<
  Int32 Function(Pointer<ShimRegex>, Pointer<Uint8>, Int32, Pointer<Int32>, Int32)
>(symbol: 'onig_shim_name_to_group_numbers')
external int shimNameToGroupNumbers(
  Pointer<ShimRegex> reg,
  Pointer<Uint8> name,
  int nameLen,
  Pointer<Int32> out,
  int cap,
);

@Native<Int32 Function(Pointer<ShimRegex>, Pointer<Uint8>, Int32)>(
  symbol: 'onig_shim_name_to_backref_number',
)
external int shimNameToBackrefNumber(
  Pointer<ShimRegex> reg,
  Pointer<Uint8> name,
  int nameLen,
);

@Native<Pointer<ShimRegSet> Function()>(symbol: 'onig_shim_regset_new')
external Pointer<ShimRegSet> shimRegsetNew();

@Native<Int32 Function(Pointer<ShimRegSet>, Pointer<ShimRegex>)>(
  symbol: 'onig_shim_regset_add',
)
external int shimRegsetAdd(Pointer<ShimRegSet> set, Pointer<ShimRegex> reg);

@Native<
  Int32 Function(
    Pointer<ShimRegSet>,
    Pointer<Uint8>,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Int32>,
    Int32,
  )
>(symbol: 'onig_shim_regset_search')
external int shimRegsetSearch(
  Pointer<ShimRegSet> set,
  Pointer<Uint8> str,
  int endByte,
  int startByte,
  int rangeByte,
  int lead,
  int option,
  Pointer<Int32> outMatchPos,
  Pointer<Int32> outNumRegs,
  Pointer<Int32> beg,
  Pointer<Int32> end,
  int capacity,
);

@Native<Void Function(Pointer<ShimRegSet>)>(symbol: 'onig_shim_regset_free')
external void shimRegsetFree(Pointer<ShimRegSet> set);
