// Thin C shim over Oniguruma for the Dart FFI bridge.
//
// It encapsulates the parts that are awkward to bind directly from Dart:
//   * the global encoding/syntax pointers (ONIG_ENCODING_UTF8, etc.),
//   * OnigRegion struct field access, and
//   * the multi-pattern "scanner" scan loop (kept in C so there is exactly one
//     FFI crossing per findNextMatch, like vscode-oniguruma).
//
// Strings are UTF-8 — the encoding TextMate/VS Code grammars are authored
// against, so `\xHH` byte escapes in those grammars match as intended. Oniguruma
// reports UTF-8 byte offsets; the Dart side maps them back to UTF-16 code-unit
// (Dart String) indices via a per-string offset map (see utf8_offsets.dart).

#include <stdlib.h>
#include <string.h>
#include <oniguruma.h>

#if defined(_WIN32)
#define SHIM_EXPORT __declspec(dllexport)
#else
#define SHIM_EXPORT __attribute__((visibility("default")))
#endif

static int g_inited = 0;

static void ensure_init(void) {
  if (g_inited) return;
  OnigEncoding encs[1];
  encs[0] = ONIG_ENCODING_UTF8;
  onig_initialize(encs, 1);
  g_inited = 1;
}

typedef struct {
  int count;
  regex_t** regs; // NULL entries for patterns that failed to compile
  OnigRegion* region;
} ShimScanner;

// patterns: `count` UTF-8 byte buffers; patLens: their byte lengths.
// Patterns that fail to compile become NULL (skipped), mirroring the Dart
// engine's forgiving behavior.
SHIM_EXPORT
ShimScanner* onig_shim_scanner_new(const unsigned char** patterns,
                                   const int* patLens, int count) {
  ensure_init();
  ShimScanner* sc = (ShimScanner*)calloc(1, sizeof(ShimScanner));
  sc->count = count;
  sc->regs = (regex_t**)calloc(count, sizeof(regex_t*));
  sc->region = onig_region_new();
  OnigErrorInfo einfo;
  for (int i = 0; i < count; i++) {
    regex_t* reg = NULL;
    const unsigned char* p = patterns[i];
    int r = onig_new(&reg, p, p + patLens[i], ONIG_OPTION_CAPTURE_GROUP,
                     ONIG_ENCODING_UTF8, ONIG_SYNTAX_ONIGURUMA, &einfo);
    sc->regs[i] = (r == ONIG_NORMAL) ? reg : NULL;
  }
  return sc;
}

SHIM_EXPORT
void onig_shim_scanner_free(ShimScanner* sc) {
  if (!sc) return;
  for (int i = 0; i < sc->count; i++) {
    if (sc->regs[i]) onig_free(sc->regs[i]);
  }
  onig_region_free(sc->region, 1);
  free(sc->regs);
  free(sc);
}

// Mirrors OnigScanner.findNextMatch: tries patterns in order; a match exactly
// at `startByte` wins immediately; otherwise the left-most match wins (ties ->
// earliest pattern). Returns the winning pattern index, or -1 for no match.
// On a match, *outNumRegs is set and beg/end are filled with byte offsets of
// each capture group (0 = whole match), up to `capacity` groups.
SHIM_EXPORT
int onig_shim_find(ShimScanner* sc, const unsigned char* str, int endByte,
                   int startByte, int* outNumRegs, int* beg, int* end,
                   int capacity) {
  const unsigned char* s = str;
  const unsigned char* e = str + endByte;
  const unsigned char* start = str + startByte;

  int bestIdx = -1;
  int bestStart = 0x7fffffff;
  OnigRegion* region = sc->region;

  for (int i = 0; i < sc->count; i++) {
    regex_t* reg = sc->regs[i];
    if (!reg) continue;
    int r = onig_search(reg, s, e, start, e, region, ONIG_OPTION_NONE);
    if (r >= 0) {
      int ms = region->beg[0];
      int wins = (ms == startByte) || (ms < bestStart);
      if (wins) {
        bestIdx = i;
        bestStart = ms;
        int n = region->num_regs;
        if (n > capacity) n = capacity;
        *outNumRegs = n;
        for (int g = 0; g < n; g++) {
          beg[g] = region->beg[g];
          end[g] = region->end[g];
        }
        if (ms == startByte) break; // exact-start match wins immediately
      }
    }
  }
  return bestIdx;
}

// Scans the whole [str, str+endByte) for every non-overlapping match in a
// SINGLE FFI crossing and returns the total count. At each position it picks
// the winning pattern exactly as onig_shim_find does (exact-start wins, else
// left-most, ties -> earliest pattern), then advances past the whole match.
//
// Offsets are deliberately NOT marshalled back: this measures native scan
// throughput with one boundary crossing, directly comparable to the C
// benchmark loop (which also only counts). It is the "native-from-Dart
// ceiling" for a find-all-matches scan; use onig_shim_find when you need the
// per-match offsets.
SHIM_EXPORT
int onig_shim_scan_count(ShimScanner* sc, const unsigned char* str,
                         int endByte) {
  const unsigned char* s = str;
  const unsigned char* e = str + endByte;
  OnigRegion* region = sc->region;

  int count = 0;
  int startByte = 0;
  while (startByte <= endByte) {
    const unsigned char* start = str + startByte;
    int bestBeg = -1, bestEnd = -1, bestStart = 0x7fffffff;
    for (int i = 0; i < sc->count; i++) {
      regex_t* reg = sc->regs[i];
      if (!reg) continue;
      int r = onig_search(reg, s, e, start, e, region, ONIG_OPTION_NONE);
      if (r >= 0) {
        int ms = region->beg[0];
        if (ms == startByte) { // exact-start match wins immediately
          bestBeg = ms; bestEnd = region->end[0];
          break;
        }
        if (ms < bestStart) {
          bestStart = ms; bestBeg = ms; bestEnd = region->end[0];
        }
      }
    }
    if (bestBeg < 0) break;
    count++;
    int next = bestEnd;
    if (next == startByte) {
      // Zero-width match: advance one whole UTF-8 character so we never split a
      // multibyte sequence (mirrors how onig_search advances internally).
      int clen = ONIGENC_MBC_ENC_LEN(ONIG_ENCODING_UTF8, s + startByte);
      next += (clen > 0 ? clen : 1);
    }
    startByte = next;
  }
  return count;
}

SHIM_EXPORT
const char* onig_shim_version(void) { return onig_version(); }

// ===========================================================================
// Layer 0 — flat-int accessors over the raw onig_* API for the WEB backend.
//
// The FFI (IO) backend binds onig_* directly, but the web/js_interop bridge
// can't marshal OnigRegion / regex_t structs across the boundary. These helpers
// keep all struct/ABI handling in C and expose only ints (opaque handles as
// pointers, byte offsets, codes), so the Dart web layer can present the same
// low-level API the IO backend does. Encodings/syntaxes are selected by id:
//   encoding: 0 = UTF-8, 1 = US-ASCII
//   syntax:   0 = Oniguruma, 1 = Ruby
// (only the globals that survive in the prebuilt module are available).
// ===========================================================================

static OnigEncoding shim_encoding(int id) {
  switch (id) {
    case 1:  return ONIG_ENCODING_ASCII;
    case 0:
    default: return ONIG_ENCODING_UTF8;
  }
}

static OnigSyntaxType* shim_syntax(int id) {
  switch (id) {
    case 1:  return ONIG_SYNTAX_RUBY;
    case 0:
    default: return ONIG_SYNTAX_ONIGURUMA;
  }
}

// Copy the winning region's group byte offsets into the caller's int arrays.
static void shim_fill_region(OnigRegion* region, int* outNumRegs, int* beg,
                             int* end, int capacity) {
  int n = region->num_regs;
  if (n > capacity) n = capacity;
  *outNumRegs = n;
  for (int g = 0; g < n; g++) {
    beg[g] = region->beg[g];
    end[g] = region->end[g];
  }
}

// Compile a pattern. Returns the regex handle, or NULL on failure with *errOut
// set to the Oniguruma error code (0 == ONIG_NORMAL on success).
SHIM_EXPORT
regex_t* onig_shim_regex_new(const unsigned char* pat, int patLen, int options,
                             int encId, int synId, int* errOut) {
  ensure_init();
  regex_t* reg = NULL;
  int r = onig_new(&reg, pat, pat + patLen, (OnigOptionType)options,
                   shim_encoding(encId), shim_syntax(synId), NULL);
  if (errOut) *errOut = r;
  if (r != ONIG_NORMAL) return NULL;
  return reg;
}

SHIM_EXPORT
void onig_shim_regex_free(regex_t* reg) {
  if (reg) onig_free(reg);
}

// Format an error code into buf (up to cap bytes); returns the length written.
// A zeroed OnigErrorInfo is passed so a code that wants a "%n" detail reads a
// safe (empty) value rather than an uninitialised vararg (which would trap in
// wasm). Detail is omitted, matching the FFI backend.
SHIM_EXPORT
int onig_shim_error_string(int code, unsigned char* buf, int cap) {
  unsigned char tmp[ONIG_MAX_ERROR_MESSAGE_LEN];
  OnigErrorInfo einfo;
  memset(&einfo, 0, sizeof(einfo));
  int n = onig_error_code_to_str(tmp, code, &einfo);
  if (n < 0) n = 0;
  if (n > cap) n = cap;
  memcpy(buf, tmp, n);
  return n;
}

// Search [startByte, rangeByte) within [0, endByte). Fills the caller's beg/end
// arrays with the match's group byte offsets (up to capacity) and *outNumRegs.
// Returns the match start byte offset (>=0), ONIG_MISMATCH (-1), or a negative
// error code.
SHIM_EXPORT
int onig_shim_search(regex_t* reg, const unsigned char* str, int endByte,
                     int startByte, int rangeByte, int option, int* outNumRegs,
                     int* beg, int* end, int capacity) {
  OnigRegion* region = onig_region_new();
  int r = onig_search(reg, str, str + endByte, str + startByte, str + rangeByte,
                      region, (OnigOptionType)option);
  if (r >= 0) shim_fill_region(region, outNumRegs, beg, end, capacity);
  onig_region_free(region, 1);
  return r;
}

// Anchored match at atByte within [0, endByte). Returns the matched byte length
// (>=0) or a negative code; fills beg/end like onig_shim_search.
SHIM_EXPORT
int onig_shim_match(regex_t* reg, const unsigned char* str, int endByte,
                    int atByte, int option, int* outNumRegs, int* beg, int* end,
                    int capacity) {
  OnigRegion* region = onig_region_new();
  int r = onig_match(reg, str, str + endByte, str + atByte, region,
                     (OnigOptionType)option);
  if (r >= 0) shim_fill_region(region, outNumRegs, beg, end, capacity);
  onig_region_free(region, 1);
  return r;
}

SHIM_EXPORT
int onig_shim_number_of_captures(regex_t* reg) {
  return onig_number_of_captures(reg);
}

SHIM_EXPORT
int onig_shim_number_of_names(regex_t* reg) {
  return onig_number_of_names(reg);
}

// Writes up to `cap` group numbers for `name` into out[]; returns the total
// count (>=0), or a negative code if the name is undefined.
SHIM_EXPORT
int onig_shim_name_to_group_numbers(regex_t* reg, const unsigned char* name,
                                    int nameLen, int* out, int cap) {
  int* nums = NULL;
  int n = onig_name_to_group_numbers(reg, name, name + nameLen, &nums);
  if (n < 0) return n;
  int m = n > cap ? cap : n;
  for (int i = 0; i < m; i++) out[i] = nums[i];
  return n;
}

SHIM_EXPORT
int onig_shim_name_to_backref_number(regex_t* reg, const unsigned char* name,
                                     int nameLen) {
  return onig_name_to_backref_number(reg, name, name + nameLen, NULL);
}

// --- RegSet (the set owns its regexes; onig_regset_free frees them) ---

SHIM_EXPORT
OnigRegSet* onig_shim_regset_new(void) {
  ensure_init();
  OnigRegSet* set = NULL;
  int r = onig_regset_new(&set, 0, NULL);
  return (r == ONIG_NORMAL) ? set : NULL;
}

SHIM_EXPORT
int onig_shim_regset_add(OnigRegSet* set, regex_t* reg) {
  return onig_regset_add(set, reg);
}

// Search all patterns. On a match returns the winning pattern index (>=0), sets
// *outMatchPos to the match start byte and *outNumRegs + beg/end to the winner's
// region (up to capacity). Returns -1 for no match or a negative error code.
SHIM_EXPORT
int onig_shim_regset_search(OnigRegSet* set, const unsigned char* str,
                            int endByte, int startByte, int rangeByte, int lead,
                            int option, int* outMatchPos, int* outNumRegs,
                            int* beg, int* end, int capacity) {
  int matchPos = 0;
  OnigRegSetLead l =
      (lead == 1) ? ONIG_REGSET_REGEX_LEAD : ONIG_REGSET_POSITION_LEAD;
  int idx = onig_regset_search(set, str, str + endByte, str + startByte,
                               str + rangeByte, l, (OnigOptionType)option,
                               &matchPos);
  if (idx >= 0) {
    *outMatchPos = matchPos;
    shim_fill_region(onig_regset_get_region(set, idx), outNumRegs, beg, end,
                     capacity);
  }
  return idx;
}

SHIM_EXPORT
void onig_shim_regset_free(OnigRegSet* set) {
  if (set) onig_regset_free(set);
}
