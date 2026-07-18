#!/usr/bin/env bash
# Builds the prebuilt WebAssembly library for the web backend: Oniguruma +
# our shim (src/oniguruma_shim.c) compiled to ONE self-contained wasm32-wasi
# "reactor" module that exports the onig_shim_* symbols plus malloc/free and
# its linear memory. Used by .github/workflows/prebuild-oniguruma.yml and for
# local verification; not part of the published package.
#
# The web backend (lib/src/backend_web.dart) drives this module over
# dart:js_interop. This blob is committed under prebuilt/web/ and published to
# the GitHub Release by the release-wasm workflow; consumers fetch it via
# `dart run oniguruma_native:setup` (or loadWasm's runtime fallback).
#
# Usage:
#   WASI_SDK=/path/to/wasi-sdk ONIG_SRC=/path/to/onig-6.9.10 \
#     OUT=/path/to/oniguruma_native.wasm tool/prebuilt/build_wasm.sh
#
# ONIG_SRC must be the extracted upstream source (the same tree the from-source
# build hook fetches); tool/prebuilt/fetch_onig.cmake produces it in CI.
set -euo pipefail

: "${WASI_SDK:?set WASI_SDK to the wasi-sdk root}"
: "${ONIG_SRC:?set ONIG_SRC to the extracted onig-6.9.10 source tree}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"           # packages/oniguruma_native
OUT="${OUT:-$PKG/prebuilt/web/oniguruma_native.wasm}"

CLANG="$WASI_SDK/bin/clang"
SYSROOT="$WASI_SDK/share/wasi-sysroot"
SHIM="$PKG/src/oniguruma_shim.c"

[ -x "$CLANG" ] || { echo "clang not found at $CLANG" >&2; exit 1; }
[ -d "$ONIG_SRC/src" ] || { echo "onig src not found at $ONIG_SRC/src" >&2; exit 1; }

# Install the wasm32 config.h into the source tree (the release ships only
# config.h.in). Mirrors _installConfigHeader in hook/build.dart.
cp "$PKG/src/config/config.h.wasm" "$ONIG_SRC/src/config.h"

# The exact set that makes up libonig (src/Makefile.am libonig_la_SOURCES),
# kept in sync with _onigSources in hook/build.dart. The unicode_*_data.c files
# are #included by unicode.c, so they are on disk but not compiled directly.
ONIG_SOURCES=(
  regparse.c regcomp.c regexec.c regenc.c regerror.c regext.c
  regsyntax.c regtrav.c regversion.c st.c reggnu.c onig_init.c
  unicode.c unicode_unfold_key.c unicode_fold1_key.c
  unicode_fold2_key.c unicode_fold3_key.c
  ascii.c utf8.c utf16_be.c utf16_le.c utf32_be.c utf32_le.c
  euc_jp.c euc_jp_prop.c sjis.c sjis_prop.c
  iso8859_1.c iso8859_2.c iso8859_3.c iso8859_4.c iso8859_5.c
  iso8859_6.c iso8859_7.c iso8859_8.c iso8859_9.c iso8859_10.c
  iso8859_11.c iso8859_13.c iso8859_14.c iso8859_15.c iso8859_16.c
  euc_tw.c euc_kr.c big5.c gb18030.c koi8_r.c cp1251.c
)

SRCS=("$SHIM")
for s in "${ONIG_SOURCES[@]}"; do SRCS+=("$ONIG_SRC/src/$s"); done

mkdir -p "$(dirname "$OUT")"
echo "wasm: compiling ${#SRCS[@]} sources -> $OUT"

# Reactor model: no _start; wasm-ld emits _initialize (call once after
# instantiation to run libc ctors). Export the shim ABI + allocator + memory so
# the Dart side can marshal into the heap. -w: onig is warning-heavy.
"$CLANG" \
  --target=wasm32-wasi \
  --sysroot="$SYSROOT" \
  -mexec-model=reactor \
  -O3 -DNDEBUG -DHAVE_CONFIG_H -DONIG_STATIC -w \
  -I"$ONIG_SRC/src" \
  -Wl,--export=onig_shim_scanner_new \
  -Wl,--export=onig_shim_scanner_free \
  -Wl,--export=onig_shim_find \
  -Wl,--export=onig_shim_scan_count \
  -Wl,--export=onig_shim_version \
  -Wl,--export=onig_shim_regex_new \
  -Wl,--export=onig_shim_regex_free \
  -Wl,--export=onig_shim_error_string \
  -Wl,--export=onig_shim_search \
  -Wl,--export=onig_shim_match \
  -Wl,--export=onig_shim_number_of_captures \
  -Wl,--export=onig_shim_number_of_names \
  -Wl,--export=onig_shim_name_to_group_numbers \
  -Wl,--export=onig_shim_name_to_backref_number \
  -Wl,--export=onig_shim_regset_new \
  -Wl,--export=onig_shim_regset_add \
  -Wl,--export=onig_shim_regset_search \
  -Wl,--export=onig_shim_regset_free \
  -Wl,--export=malloc \
  -Wl,--export=free \
  -Wl,--export-memory \
  -Wl,-z,stack-size=4194304 \
  -o "$OUT" \
  "${SRCS[@]}"

echo "wasm: wrote $OUT ($(wc -c < "$OUT") bytes)"
