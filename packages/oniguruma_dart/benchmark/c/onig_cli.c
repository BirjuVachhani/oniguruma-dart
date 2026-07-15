/*
 * onig_cli.c — reference harness for the Dart port of Oniguruma.
 *
 * Two modes:
 *
 *   1) Differential testing (default / "diff"):
 *      Reads a stream of (pattern, subject) pairs from stdin using a
 *      length-prefixed binary protocol (so patterns/subjects may contain any
 *      bytes, including NUL and newlines):
 *
 *          u32le pattern_len, pattern bytes,
 *          u32le subject_len, subject bytes,   (repeat until EOF)
 *
 *      For each pair it prints one line to stdout:
 *          MATCH <start> <n> <b0> <e0> <b1> <e1> ...   (n = num_regs, byte offsets)
 *          NOMATCH
 *          ERROR <code>
 *
 *   2) Benchmark ("bench <pattern-hex> <file> <iters>"):
 *      Compiles <pattern-hex> (hex-encoded bytes), reads <file> as the subject,
 *      then repeatedly scans the whole subject for all non-overlapping matches,
 *      <iters> times. Prints: "<count> matches, <ns_per_op> ns/search, <total_ms> ms".
 *
 * Encoding: UTF-8, syntax: ONIG_SYNTAX_DEFAULT, options: ONIG_OPTION_DEFAULT.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include "oniguruma.h"

static OnigEncoding ENC;

static int read_exact(FILE* f, void* buf, size_t n) {
  return fread(buf, 1, n, f) == n;
}

static int read_u32(FILE* f, uint32_t* out) {
  unsigned char b[4];
  if (!read_exact(f, b, 4)) return 0;
  *out = (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
         ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
  return 1;
}

static int diff_mode(void) {
  OnigErrorInfo einfo;
  OnigRegion* region = onig_region_new();
  uint32_t plen, slen;
  unsigned char *pat = NULL, *sub = NULL;
  size_t pcap = 0, scap = 0;

  while (read_u32(stdin, &plen)) {
    if (plen > pcap) { pat = realloc(pat, plen ? plen : 1); pcap = plen; }
    if (plen && !read_exact(stdin, pat, plen)) break;
    if (!read_u32(stdin, &slen)) break;
    if (slen > scap) { sub = realloc(sub, slen ? slen : 1); scap = slen; }
    if (slen && !read_exact(stdin, sub, slen)) break;

    regex_t* reg;
    int r = onig_new(&reg, pat, pat + plen, ONIG_OPTION_DEFAULT, ENC,
                     ONIG_SYNTAX_DEFAULT, &einfo);
    if (r != ONIG_NORMAL) { printf("ERROR %d\n", r); fflush(stdout); continue; }

    onig_region_clear(region);
    r = onig_search(reg, sub, sub + slen, sub, sub + slen, region, ONIG_OPTION_NONE);
    if (r >= 0) {
      printf("MATCH %d %d", r, region->num_regs);
      for (int i = 0; i < region->num_regs; i++)
        printf(" %d %d", region->beg[i], region->end[i]);
      printf("\n");
    } else if (r == ONIG_MISMATCH) {
      printf("NOMATCH\n");
    } else {
      printf("ERROR %d\n", r);
    }
    fflush(stdout);
    onig_free(reg);
  }
  onig_region_free(region, 1);
  free(pat); free(sub);
  return 0;
}

static int hexval(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

/* decode hex string into a freshly malloc'd buffer; returns length or -1 */
static long hexdecode(const char* s, unsigned char** out) {
  size_t n = strlen(s);
  if (n % 2) return -1;
  unsigned char* buf = malloc(n / 2 ? n / 2 : 1);
  for (size_t i = 0; i < n; i += 2) {
    int hi = hexval(s[i]), lo = hexval(s[i + 1]);
    if (hi < 0 || lo < 0) { free(buf); return -1; }
    buf[i / 2] = (unsigned char)((hi << 4) | lo);
  }
  *out = buf;
  return (long)(n / 2);
}

static double now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
}

static int bench_mode(const char* pat_hex, const char* path, long iters) {
  unsigned char* pat;
  long plen = hexdecode(pat_hex, &pat);
  if (plen < 0) { fprintf(stderr, "bad hex pattern\n"); return 2; }

  FILE* f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "cannot open %s\n", path); return 2; }
  fseek(f, 0, SEEK_END);
  long slen = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char* sub = malloc(slen ? slen : 1);
  if (fread(sub, 1, slen, f) != (size_t)slen) { fprintf(stderr, "read fail\n"); return 2; }
  fclose(f);

  OnigErrorInfo einfo;
  regex_t* reg;
  int r = onig_new(&reg, pat, pat + plen, ONIG_OPTION_DEFAULT, ENC,
                   ONIG_SYNTAX_DEFAULT, &einfo);
  if (r != ONIG_NORMAL) {
    char msg[ONIG_MAX_ERROR_MESSAGE_LEN];
    onig_error_code_to_str((UChar*)msg, r, &einfo);
    fprintf(stderr, "compile error: %s\n", msg);
    return 2;
  }
  OnigRegion* region = onig_region_new();

  long total_matches = 0;
  double t0 = now_ns();
  for (long it = 0; it < iters; it++) {
    const unsigned char* start = sub;
    const unsigned char* end = sub + slen;
    long count = 0;
    while (start <= end) {
      onig_region_clear(region);
      int m = onig_search(reg, sub, end, start, end, region, ONIG_OPTION_NONE);
      if (m < 0) break;
      count++;
      const unsigned char* next = sub + region->end[0];
      if (next == start) next++;      /* zero-width: advance one byte */
      start = next;
    }
    total_matches = count;
  }
  double t1 = now_ns();
  double total = t1 - t0;
  printf("%ld matches, %.1f ns/search-scan, %.2f ms total (%ld iters)\n",
         total_matches, total / (double)iters, total / 1e6, iters);

  onig_region_free(region, 1);
  onig_free(reg);
  free(pat); free(sub);
  return 0;
}

/* Compile the pattern <iters> times, freeing each — measures compile ns/op. */
static int compile_mode(const char* pat_hex, long iters) {
  unsigned char* pat;
  long plen = hexdecode(pat_hex, &pat);
  if (plen < 0) { fprintf(stderr, "bad hex pattern\n"); return 2; }

  OnigErrorInfo einfo;
  regex_t* reg;
  /* warm up + validate once */
  int r = onig_new(&reg, pat, pat + plen, ONIG_OPTION_DEFAULT, ENC,
                   ONIG_SYNTAX_DEFAULT, &einfo);
  if (r != ONIG_NORMAL) {
    char msg[ONIG_MAX_ERROR_MESSAGE_LEN];
    onig_error_code_to_str((UChar*)msg, r, &einfo);
    fprintf(stderr, "compile error: %s\n", msg);
    return 2;
  }
  onig_free(reg);

  double t0 = now_ns();
  for (long it = 0; it < iters; it++) {
    r = onig_new(&reg, pat, pat + plen, ONIG_OPTION_DEFAULT, ENC,
                 ONIG_SYNTAX_DEFAULT, &einfo);
    if (r != ONIG_NORMAL) { fprintf(stderr, "compile error\n"); return 2; }
    onig_free(reg);
  }
  double total = now_ns() - t0;
  printf("compiled, %.1f ns/compile, %.2f ms total (%ld iters)\n",
         total / (double)iters, total / 1e6, iters);
  free(pat);
  return 0;
}

int main(int argc, char** argv) {
  ENC = ONIG_ENCODING_UTF8;
  onig_initialize(&ENC, 1);

  int rc;
  if (argc >= 2 && strcmp(argv[1], "bench") == 0) {
    if (argc < 5) { fprintf(stderr, "usage: %s bench <pat-hex> <file> <iters>\n", argv[0]); return 2; }
    rc = bench_mode(argv[2], argv[3], atol(argv[4]));
  } else if (argc >= 2 && strcmp(argv[1], "compile") == 0) {
    if (argc < 4) { fprintf(stderr, "usage: %s compile <pat-hex> <iters>\n", argv[0]); return 2; }
    rc = compile_mode(argv[2], atol(argv[3]));
  } else {
    rc = diff_mode();
  }
  onig_end();
  return rc;
}
