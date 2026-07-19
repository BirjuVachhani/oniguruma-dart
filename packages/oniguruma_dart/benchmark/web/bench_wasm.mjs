// Web/WASM benchmark: the `oniguruma_native` package's WebAssembly backend, the
// SAME Oniguruma 6.9.10 + shim the FFI backend uses, compiled to wasm32-wasi and
// driven through the browser `WebAssembly` API (here under Node/V8, the engine
// Chrome runs too). This is the engine cost of oniguruma_native's *web* path,
// isolated from the dart2js/dart2wasm compiler's own marshalling; it is measured
// the same way the V8 engines in this suite are (Node), so it drops straight
// into mainstream_results.json alongside them.
//
// Two numbers per pattern, both "median ns to scan the whole corpus for every
// non-overlapping match", identical corpora + patterns as every other engine:
//
//   per-match  : the package's real OnigScanner.findNextMatch loop: one wasm
//                crossing + one result object per match (what a web consumer pays
//                to enumerate matches).
//   bulk       : onig_shim_scan_count: the entire scan in a single crossing into
//                wasm, no per-match allocation (the wasm throughput ceiling).
//
//   node benchmark/web/bench_wasm.mjs
//
// Invoked by benchmark/wasm_bench.py, which folds the RAW lines into the JSON as
// ONIG_WASM (per-match) and ONIG_WASM_BULK.
import { readFileSync } from 'fs';

const HERE = new URL('.', import.meta.url);
const WASM = new URL('../../../oniguruma_native/prebuilt/web/oniguruma_native.wasm', HERE);
const ASCII = new URL('../datasets/corpus.txt', HERE);
const UNI = new URL('../datasets/unicode_corpus.txt', HERE);

const trials = 5;
const minMs = 250; // per timed run, adaptive, matches the FFI Dart harness

// label, pattern, corpus: identical set to the pure-Dart + FFI mainstream runs.
const patterns = [
  ['literal', 'lorem', 'ascii'],
  ['literal-unicode', '東京', 'uni'],
  ['alt-5', 'lorem|ipsum|dolor|sit|amet', 'ascii'],
  ['class-lower', '[a-z]+', 'ascii'],
  ['class-digit', '[0-9]+', 'ascii'],
  ['word-w', String.raw`\w+`, 'ascii'],
  ['two-words', '[a-z]+ [a-z]+', 'ascii'],
  ['word-boundary', String.raw`\b\w{5}\b`, 'ascii'],
  ['email-like', String.raw`\w+@\w+`, 'ascii'],
  ['named-group', '(?<w>[a-z]+)', 'ascii'],
  ['case-insens', '(?i)lorem', 'ascii'],
  ['backref-dup', String.raw`(\w+) \1`, 'ascii'],
  ['greedy-dotstar', '.*lorem', 'ascii'],
];

// --- instantiate the reactor module (same 3 WASI stubs the Dart backend uses) ---
const mod = new WebAssembly.Module(readFileSync(WASM));
const wasi = { fd_close: () => 0, fd_seek: () => 0, fd_write: () => 0 };
const ex = new WebAssembly.Instance(mod, { wasi_snapshot_preview1: wasi }).exports;
ex._initialize?.();

const { malloc, free } = ex;
const dv = () => new DataView(ex.memory.buffer); // re-view: growth detaches

function writeUtf16le(str) {
  const byteLen = str.length * 2;
  const p = malloc(byteLen || 2);
  const v = dv();
  for (let i = 0; i < str.length; i++) v.setUint16(p + i * 2, str.charCodeAt(i), true);
  return { p, byteLen };
}

function newScanner(pats) {
  const n = pats.length;
  const bufs = pats.map(writeUtf16le);
  const patsPtr = malloc((n || 1) * 4);
  const lensPtr = malloc((n || 1) * 4);
  const v = dv();
  for (let i = 0; i < n; i++) {
    v.setUint32(patsPtr + i * 4, bufs[i].p, true);
    v.setInt32(lensPtr + i * 4, bufs[i].byteLen, true);
  }
  const sc = ex.onig_shim_scanner_new(patsPtr, lensPtr, n);
  for (const b of bufs) free(b.p);
  free(patsPtr); free(lensPtr);
  return sc;
}

const CAP = 64;
const numRegsPtr = malloc(4), begPtr = malloc(CAP * 4), endPtr = malloc(CAP * 4);

// Mirrors OnigScanner.findNextMatch: returns {index, caps:[[begUnit,endUnit],…]}
// with a fresh result object per match, exactly like the Dart web backend.
function find(sc, subj, startUnit) {
  const idx = ex.onig_shim_find(sc, subj.p, subj.byteLen, startUnit * 2,
    numRegsPtr, begPtr, endPtr, CAP);
  if (idx < 0) return null;
  const v = dv();
  const nr = v.getInt32(numRegsPtr, true);
  const caps = new Array(nr);
  for (let g = 0; g < nr; g++) {
    const b = v.getInt32(begPtr + g * 4, true);
    const e = v.getInt32(endPtr + g * 4, true);
    caps[g] = [b < 0 ? -1 : b >> 1, e < 0 ? -1 : e >> 1];
  }
  return { index: idx, caps };
}

// Walk the per-match API over the whole corpus, exactly as a consumer would.
function perMatchScan(sc, subj) {
  let start = 0, n = 0;
  for (;;) {
    const m = find(sc, subj, start);
    if (m === null) break;
    n++;
    const e = m.caps[0][1];
    start = e > start ? e : start + 1;
  }
  return n;
}

function readCString(p) {
  const b = new Uint8Array(ex.memory.buffer);
  let s = '';
  for (let i = p; b[i] !== 0; i++) s += String.fromCharCode(b[i]);
  return s;
}

let sink = 0;
function nsPerCall(fn) {
  let iters = 0;
  const t0 = process.hrtime.bigint();
  let elapsed;
  do {
    sink += fn();
    iters++;
    elapsed = Number(process.hrtime.bigint() - t0) / 1e6; // ms
  } while (elapsed < minMs);
  return (Number(process.hrtime.bigint() - t0) / iters) | 0; // ns/call
}

const median = xs => {
  xs = [...xs].sort((a, b) => a - b);
  const n = xs.length;
  return n % 2 ? xs[n >> 1] : (xs[(n >> 1) - 1] + xs[n >> 1]) / 2;
};
const medianOf = fn => median(Array.from({ length: trials }, () => nsPerCall(fn)));

const fmt = ns => ns >= 1e6 ? (ns / 1e6).toFixed(2) + 'ms'
  : ns >= 1e3 ? (ns / 1e3).toFixed(1) + 'µs' : ns.toFixed(0) + 'ns';

const corpora = {
  ascii: readFileSync(ASCII, 'utf8'),
  uni: readFileSync(UNI, 'utf8'),
};

console.log('# oniguruma_native WebAssembly backend: mainstream benchmark');
console.log(`# ${readCString(ex.onig_shim_version())}  ·  WebAssembly under Node ${process.version}`);
console.log(`# trials=${trials}, adaptive (>= ${minMs}ms/run)\n`);
console.log('| pattern | matches | per-match (findNextMatch) | bulk (scanCount) |');
console.log('|---|--:|--:|--:|');

for (const [label, pat, corpus] of patterns) {
  const text = corpora[corpus];
  const sc = newScanner([pat]);
  const subj = writeUtf16le(text);

  const cPer = perMatchScan(sc, subj);
  const cBulk = ex.onig_shim_scan_count(sc, subj.p, subj.byteLen);
  const agree = cPer === cBulk;

  for (let i = 0; i < 3; i++) { perMatchScan(sc, subj); ex.onig_shim_scan_count(sc, subj.p, subj.byteLen); }

  const perNs = medianOf(() => perMatchScan(sc, subj));
  const bulkNs = medianOf(() => ex.onig_shim_scan_count(sc, subj.p, subj.byteLen));

  console.log(`| ${label} | ${agree ? cPer : `${cPer}≠${cBulk} ⚠`} | ${fmt(perNs)} | ${fmt(bulkNs)} |`);
  // machine-parseable: RAW <label> <matches> <perMatchNs> <bulkNs>
  console.log(`RAW\t${label}\t${cPer}\t${perNs.toFixed(1)}\t${bulkNs.toFixed(1)}`);

  free(subj.p);
  ex.onig_shim_scanner_free(sc);
}
if (sink === -1) console.log(''); // keep sink live (blocks DCE)
