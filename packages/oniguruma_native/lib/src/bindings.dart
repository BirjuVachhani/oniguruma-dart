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
// Raw Oniguruma C public API (Layer 0).
//
// These bind the real `onig_*` symbols directly — every one is already exported
// by the shipped prebuilt libraries (193 `onig_*` symbols), so no rebuild is
// needed to expose them; only these externs. Struct field access uses the
// native (LP64) layout, which is the only ABI these FFI bindings run under
// (the web/WASM backend reaches the same functions a different way).
// ---------------------------------------------------------------------------

/// Opaque `regex_t*` handle (a compiled pattern).
final class OnigRegexT extends Opaque {}

/// Opaque `OnigRegSet*` handle.
final class OnigRegSetT extends Opaque {}

/// `OnigRegion` (`struct re_registers`, oniguruma.h) — native LP64 layout.
final class OnigRegionStruct extends Struct {
  @Int32()
  external int allocated;
  @Int32()
  external int numRegs;
  external Pointer<Int32> beg;
  external Pointer<Int32> end;
  external Pointer<Void> historyRoot;
}

/// Stand-in for the global `OnigEncodingType` / `OnigSyntaxType` structs. We
/// only ever take their address ([Native.addressOf]) and hand it to `onig_new`;
/// the fields are never read from Dart, so the declared size is irrelevant.
final class OnigEncodingType extends Struct {
  @Int32()
  external int reserved;
}

final class OnigSyntaxTypeStruct extends Struct {
  @Int32()
  external int reserved;
}

// The built-in encoding/syntax globals that survive in the prebuilts (only
// those the shim references are kept; the rest are dead-stripped). Their
// addresses are the `OnigEncoding` / `OnigSyntaxType*` values `onig_new` wants.
@Native<OnigEncodingType>(symbol: 'OnigEncodingUTF8')
external final OnigEncodingType gEncUtf8;

@Native<OnigEncodingType>(symbol: 'OnigEncodingASCII')
external final OnigEncodingType gEncAscii;

@Native<OnigSyntaxTypeStruct>(symbol: 'OnigSyntaxOniguruma')
external final OnigSyntaxTypeStruct gSynOniguruma;

@Native<OnigSyntaxTypeStruct>(symbol: 'OnigSyntaxRuby')
external final OnigSyntaxTypeStruct gSynRuby;

@Native<
  Int32 Function(
    Pointer<Pointer<OnigRegexT>>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Uint32,
    Pointer<OnigEncodingType>,
    Pointer<OnigSyntaxTypeStruct>,
    Pointer<Void>,
  )
>(symbol: 'onig_new')
external int onigNew(
  Pointer<Pointer<OnigRegexT>> reg,
  Pointer<Uint8> pattern,
  Pointer<Uint8> patternEnd,
  int option,
  Pointer<OnigEncodingType> enc,
  Pointer<OnigSyntaxTypeStruct> syntax,
  Pointer<Void> einfo,
);

@Native<Void Function(Pointer<OnigRegexT>)>(symbol: 'onig_free')
external void onigFree(Pointer<OnigRegexT> reg);

@Native<
  Int32 Function(
    Pointer<OnigRegexT>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<OnigRegionStruct>,
    Uint32,
  )
>(symbol: 'onig_search')
external int onigSearch(
  Pointer<OnigRegexT> reg,
  Pointer<Uint8> str,
  Pointer<Uint8> end,
  Pointer<Uint8> start,
  Pointer<Uint8> range,
  Pointer<OnigRegionStruct> region,
  int option,
);

@Native<
  Int32 Function(
    Pointer<OnigRegexT>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<OnigRegionStruct>,
    Uint32,
  )
>(symbol: 'onig_match')
external int onigMatch(
  Pointer<OnigRegexT> reg,
  Pointer<Uint8> str,
  Pointer<Uint8> end,
  Pointer<Uint8> at,
  Pointer<OnigRegionStruct> region,
  int option,
);

@Native<Pointer<OnigRegionStruct> Function()>(symbol: 'onig_region_new')
external Pointer<OnigRegionStruct> onigRegionNew();

@Native<Void Function(Pointer<OnigRegionStruct>, Int32)>(
  symbol: 'onig_region_free',
)
external void onigRegionFree(Pointer<OnigRegionStruct> region, int freeSelf);

@Native<Void Function(Pointer<OnigRegionStruct>)>(symbol: 'onig_region_clear')
external void onigRegionClear(Pointer<OnigRegionStruct> region);

@Native<Int32 Function(Pointer<OnigRegionStruct>, Int32)>(
  symbol: 'onig_region_resize',
)
external int onigRegionResize(Pointer<OnigRegionStruct> region, int n);

@Native<Void Function(Pointer<OnigRegionStruct>, Pointer<OnigRegionStruct>)>(
  symbol: 'onig_region_copy',
)
external void onigRegionCopy(
  Pointer<OnigRegionStruct> to,
  Pointer<OnigRegionStruct> from,
);

@Native<Int32 Function(Pointer<OnigRegexT>)>(symbol: 'onig_number_of_captures')
external int onigNumberOfCaptures(Pointer<OnigRegexT> reg);

@Native<Int32 Function(Pointer<OnigRegexT>)>(symbol: 'onig_number_of_names')
external int onigNumberOfNames(Pointer<OnigRegexT> reg);

@Native<
  Int32 Function(
    Pointer<OnigRegexT>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Pointer<Int32>>,
  )
>(symbol: 'onig_name_to_group_numbers')
external int onigNameToGroupNumbers(
  Pointer<OnigRegexT> reg,
  Pointer<Uint8> name,
  Pointer<Uint8> nameEnd,
  Pointer<Pointer<Int32>> nums,
);

@Native<
  Int32 Function(
    Pointer<OnigRegexT>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<OnigRegionStruct>,
  )
>(symbol: 'onig_name_to_backref_number')
external int onigNameToBackrefNumber(
  Pointer<OnigRegexT> reg,
  Pointer<Uint8> name,
  Pointer<Uint8> nameEnd,
  Pointer<OnigRegionStruct> region,
);

@Native<Pointer<OnigEncodingType> Function(Pointer<OnigRegexT>)>(
  symbol: 'onig_get_encoding',
)
external Pointer<OnigEncodingType> onigGetEncoding(Pointer<OnigRegexT> reg);

@Native<Uint32 Function(Pointer<OnigRegexT>)>(symbol: 'onig_get_options')
external int onigGetOptions(Pointer<OnigRegexT> reg);

@Native<Int32 Function(Pointer<Uint8>, Int32)>(
  symbol: 'onig_error_code_to_str',
)
external int onigErrorCodeToStr(Pointer<Uint8> s, int errCode);

@Native<
  Int32 Function(Pointer<Pointer<OnigRegSetT>>, Int32, Pointer<Pointer<OnigRegexT>>)
>(symbol: 'onig_regset_new')
external int onigRegsetNew(
  Pointer<Pointer<OnigRegSetT>> rset,
  int n,
  Pointer<Pointer<OnigRegexT>> regs,
);

@Native<Int32 Function(Pointer<OnigRegSetT>, Pointer<OnigRegexT>)>(
  symbol: 'onig_regset_add',
)
external int onigRegsetAdd(Pointer<OnigRegSetT> set, Pointer<OnigRegexT> reg);

@Native<
  Int32 Function(
    Pointer<OnigRegSetT>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Int32,
    Uint32,
    Pointer<Int32>,
  )
>(symbol: 'onig_regset_search')
external int onigRegsetSearch(
  Pointer<OnigRegSetT> set,
  Pointer<Uint8> str,
  Pointer<Uint8> end,
  Pointer<Uint8> start,
  Pointer<Uint8> range,
  int lead,
  int option,
  Pointer<Int32> rmatchPos,
);

@Native<Void Function(Pointer<OnigRegSetT>)>(symbol: 'onig_regset_free')
external void onigRegsetFree(Pointer<OnigRegSetT> set);

@Native<Int32 Function(Pointer<OnigRegSetT>)>(
  symbol: 'onig_regset_number_of_regex',
)
external int onigRegsetNumberOfRegex(Pointer<OnigRegSetT> set);

@Native<Pointer<OnigRegexT> Function(Pointer<OnigRegSetT>, Int32)>(
  symbol: 'onig_regset_get_regex',
)
external Pointer<OnigRegexT> onigRegsetGetRegex(
  Pointer<OnigRegSetT> set,
  int at,
);

@Native<Pointer<OnigRegionStruct> Function(Pointer<OnigRegSetT>, Int32)>(
  symbol: 'onig_regset_get_region',
)
external Pointer<OnigRegionStruct> onigRegsetGetRegion(
  Pointer<OnigRegSetT> set,
  int at,
);
