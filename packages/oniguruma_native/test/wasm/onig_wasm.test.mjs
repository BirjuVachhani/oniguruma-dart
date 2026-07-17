// WebAssembly module reliability tests — run under Node's built-in test runner:
//
//   node --test packages/oniguruma_native/test/wasm/
//
// These exercise the SHIPPED wasm artifact (prebuilt/web/oniguruma_native.wasm —
// the exact bytes embedded as base64 into lib/src/web/oniguruma_wasm.g.dart;
// oniguruma_web_embed_test.dart proves they are byte-identical) through the SAME
// WebAssembly API + UTF-16LE marshalling that lib/src/web/backend_web.dart uses.
// So a failure here is a real bug in the wasm module or the marshalling contract,
// caught headlessly — no browser required, unlike test/oniguruma_web_test.dart.
//
// The behavioural cases mirror the IO/FFI suite (test/oniguruma_test.dart) so the
// web engine is held to byte-identical semantics. On top of that they cover what
// a browser can't easily reach: multi-megabyte subjects that force wasm linear
// memory to grow (detaching every view), many capture groups, and the full
// Unicode property tables linked into the module.
import { test, describe, before } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const WASM_PATH = fileURLToPath(
  new URL('../../prebuilt/web/oniguruma_native.wasm', import.meta.url),
);

// The reactor build imports exactly these three WASI functions for libc's stdio
// machinery; none is reached on the matching path. Anything else is a surprise.
const EXPECTED_WASI_IMPORTS = ['fd_close', 'fd_seek', 'fd_write'];

// --- A faithful re-implementation of backend_web.dart's marshalling ----------
// Every heap view is re-derived from memory.buffer AFTER any malloc, because a
// malloc that grows the memory detaches previously-created views. This mirrors
// OnigWasmModule exactly; if the wasm or this contract drifts, tests fail.

function encodeUtf16le(str) {
  const n = str.length;
  const u8 = new Uint8Array(n * 2);
  for (let i = 0; i < n; i++) {
    const c = str.charCodeAt(i);
    u8[i * 2] = c & 0xff;
    u8[i * 2 + 1] = c >>> 8;
  }
  return u8;
}

class OnigWasm {
  constructor(exports) {
    this.ex = exports;
    // Scratch region-readback buffers (as in backend_web.dart: cap 64).
    this.cap = 64;
    this.numRegs = this.malloc(4);
    this.beg = this.malloc(this.cap * 4);
    this.end = this.malloc(this.cap * 4);
  }

  static instantiate(bytes) {
    const mod = new WebAssembly.Module(bytes);
    const wasiNames = WebAssembly.Module.imports(mod)
      .filter((i) => i.module === 'wasi_snapshot_preview1')
      .map((i) => i.name);
    const wasi = {};
    for (const name of wasiNames) wasi[name] = () => 0; // success
    const inst = new WebAssembly.Instance(mod, {
      wasi_snapshot_preview1: wasi,
    });
    inst.exports._initialize?.();
    return { onig: new OnigWasm(inst.exports), mod };
  }

  get memBytes() {
    return this.ex.memory.buffer.byteLength;
  }

  malloc(n) {
    return this.ex.malloc(n);
  }

  free(p) {
    this.ex.free(p);
  }

  // Allocate + write a UTF-16LE subject/pattern; returns {p, byteLen, units}.
  writeString(str) {
    const bytes = encodeUtf16le(str);
    const byteLen = bytes.length;
    const p = this.malloc(byteLen === 0 ? 2 : byteLen);
    if (byteLen !== 0) {
      // View derived AFTER malloc (growth-safe), one crossing — as backend_web.
      new Uint8Array(this.ex.memory.buffer, p, byteLen).set(bytes);
    }
    return { p, byteLen, units: str.length };
  }

  newScanner(patterns) {
    const n = patterns.length;
    const patsPtr = this.malloc((n === 0 ? 1 : n) * 4);
    const lensPtr = this.malloc((n === 0 ? 1 : n) * 4);
    const tmp = [];
    for (let i = 0; i < n; i++) {
      const b = this.writeString(patterns[i]);
      const dv = new DataView(this.ex.memory.buffer);
      dv.setUint32(patsPtr + i * 4, b.p, true);
      dv.setInt32(lensPtr + i * 4, b.byteLen, true);
      tmp.push(b.p);
    }
    const sc = this.ex.onig_shim_scanner_new(patsPtr, lensPtr, n);
    for (const p of tmp) this.free(p);
    this.free(patsPtr);
    this.free(lensPtr);
    return sc;
  }

  // Returns {index, caps:[[start,end],...]} in UTF-16 code-unit indices, or null.
  find(sc, str, startUnit) {
    const idx = this.ex.onig_shim_find(
      sc, str.p, str.byteLen, startUnit * 2, this.numRegs, this.beg, this.end,
      this.cap,
    );
    if (idx < 0) return null;
    const dv = new DataView(this.ex.memory.buffer);
    const nr = dv.getInt32(this.numRegs, true);
    const caps = [];
    for (let g = 0; g < nr; g++) {
      const b = dv.getInt32(this.beg + g * 4, true);
      const e = dv.getInt32(this.end + g * 4, true);
      caps.push([b < 0 ? -1 : b >> 1, e < 0 ? -1 : e >> 1]);
    }
    return { index: idx, caps };
  }

  scanCount(sc, str) {
    return this.ex.onig_shim_scan_count(sc, str.p, str.byteLen);
  }

  version() {
    const p = this.ex.onig_shim_version();
    const u8 = new Uint8Array(this.ex.memory.buffer);
    let s = '';
    for (let i = p; u8[i] !== 0; i++) s += String.fromCharCode(u8[i]);
    return s;
  }
}

let onig;
let module_;

before(() => {
  const { onig: o, mod } = OnigWasm.instantiate(readFileSync(WASM_PATH));
  onig = o;
  module_ = mod;
});

describe('wasm module structure', () => {
  test('imports are exactly the three expected WASI stubs', () => {
    const imports = WebAssembly.Module.imports(module_);
    for (const i of imports) {
      assert.equal(
        i.module, 'wasi_snapshot_preview1',
        `unexpected import module "${i.module}.${i.name}"`,
      );
    }
    const names = imports.map((i) => i.name).sort();
    assert.deepEqual(names, [...EXPECTED_WASI_IMPORTS].sort());
  });

  test('exports the full shim + allocator + memory surface', () => {
    const names = WebAssembly.Module.exports(module_).map((e) => e.name);
    for (const required of [
      'memory', '_initialize', 'malloc', 'free',
      'onig_shim_scanner_new', 'onig_shim_scanner_free', 'onig_shim_find',
      'onig_shim_scan_count', 'onig_shim_version',
    ]) {
      assert.ok(names.includes(required), `missing export: ${required}`);
    }
  });

  test('links and reports the pinned Oniguruma version', () => {
    assert.equal(onig.version(), '6.9.10');
  });
});

describe('matching semantics (byte-identical to the FFI backend)', () => {
  test('scanner finds the left-most / earliest pattern', () => {
    const sc = onig.newScanner([String.raw`\d+`, String.raw`[a-z]+`]);
    const s = onig.writeString('  abc123');
    const m = onig.find(sc, s, 0);
    assert.equal(m.index, 1); // [a-z]+ at 2 beats \d+ at 5
    assert.deepEqual(m.caps[0], [2, 5]);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });

  test('capture group offsets are correct (UTF-16 indices)', () => {
    const sc = onig.newScanner([String.raw`(\w+)@(\w+)`]);
    const s = onig.writeString('x foo@bar');
    const m = onig.find(sc, s, 0);
    assert.deepEqual(m.caps[0], [2, 9]); // whole match
    assert.deepEqual(m.caps[1], [2, 5]); // group 1
    assert.deepEqual(m.caps[2], [6, 9]); // group 2
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });

  test('no match returns null', () => {
    const sc = onig.newScanner([String.raw`\d+`]);
    const s = onig.writeString('no digits here');
    assert.equal(onig.find(sc, s, 0), null);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });

  test('findNextMatch resumes from a non-zero start position', () => {
    const sc = onig.newScanner([String.raw`cat`]);
    const s = onig.writeString('cat dog cat');
    const first = onig.find(sc, s, 0);
    assert.deepEqual(first.caps[0], [0, 3]);
    const next = onig.find(sc, s, first.caps[0][1]);
    assert.deepEqual(next.caps[0], [8, 11]);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });

  test('patterns that fail to compile are skipped, not fatal', () => {
    const sc = onig.newScanner([String.raw`(`, String.raw`\d+`]);
    const s = onig.writeString('abc123');
    const m = onig.find(sc, s, 0);
    assert.equal(m.index, 1); // bad pattern 0 skipped; pattern 1 matched
    assert.deepEqual(m.caps[0], [3, 6]);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });

  test('an unmatched optional group reports (-1, -1)', () => {
    const sc = onig.newScanner([String.raw`(a)(b)?c`]);
    const s = onig.writeString('ac');
    const m = onig.find(sc, s, 0);
    assert.deepEqual(m.caps[0], [0, 2]);
    assert.deepEqual(m.caps[1], [0, 1]);
    assert.deepEqual(m.caps[2], [-1, -1]);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });

  test('multi-pattern tokenize: left-most wins, advancing the input', () => {
    const sc = onig.newScanner([String.raw`\d+`, String.raw`[a-z]+`, String.raw`\s+`]);
    const s = onig.writeString('ab 12');
    const seen = [];
    let start = 0;
    for (;;) {
      const m = onig.find(sc, s, start);
      if (m === null) break;
      const [b, e] = m.caps[0];
      seen.push([m.index, b, e]);
      start = e > start ? e : start + 1;
    }
    assert.deepEqual(seen, [
      [1, 0, 2], // "ab" -> [a-z]+
      [2, 2, 3], // " "  -> \s+
      [0, 3, 5], // "12" -> \d+
    ]);
    assert.equal(onig.scanCount(sc, s), 3);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });
});

describe('scanCount', () => {
  test('counts every non-overlapping match in one crossing', () => {
    const sc = onig.newScanner([String.raw`\w+`]);
    const s = onig.writeString('foo 123 bar');
    assert.equal(onig.scanCount(sc, s), 3);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });

  test('agrees with a manual findNextMatch scan loop', () => {
    const sc = onig.newScanner([String.raw`\d+`, String.raw`[a-z]+`]);
    const s = onig.writeString('ab 12 cd 34 ef');
    let start = 0;
    let manual = 0;
    for (;;) {
      const m = onig.find(sc, s, start);
      if (m === null) break;
      manual++;
      const e = m.caps[0][1];
      start = e > start ? e : start + 1;
    }
    assert.equal(manual, 5);
    assert.equal(onig.scanCount(sc, s), manual);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });

  test('is 0 when nothing matches', () => {
    const sc = onig.newScanner([String.raw`\d+`]);
    const s = onig.writeString('no digits here');
    assert.equal(onig.scanCount(sc, s), 0);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });
});

describe('UTF-16 offset correctness', () => {
  test('multibyte BMP (CJK) offsets are code-unit indices', () => {
    const sc = onig.newScanner([String.raw`[a-z]+`]);
    const s = onig.writeString('日本語abc');
    const m = onig.find(sc, s, 0);
    assert.deepEqual(m.caps[0], [3, 6]);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });

  test('non-BMP (surrogate pair) shifts later offsets by 2 code units', () => {
    const sc = onig.newScanner([String.raw`[a-z]+`]);
    const s = onig.writeString('\u{1F600}ab'); // 😀 = 2 UTF-16 units
    const m = onig.find(sc, s, 0);
    assert.deepEqual(m.caps[0], [2, 4]);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });

  test('a non-BMP code point is matched as a single character', () => {
    const sc = onig.newScanner([String.raw`.`]);
    const s = onig.writeString('\u{1F600}x');
    const m = onig.find(sc, s, 0);
    assert.deepEqual(m.caps[0], [0, 2]);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });

  test('Unicode property classes work (full tables linked into wasm)', () => {
    const sc = onig.newScanner([String.raw`\p{Han}+`]);
    const s = onig.writeString('東京タワー'); // 東京 are Han; タワー are not
    const m = onig.find(sc, s, 0);
    assert.deepEqual(m.caps[0], [0, 2]);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });
});

describe('capture-group readback', () => {
  test('many capture groups are read back correctly', () => {
    // 10 single-char groups -> whole match + 10 groups = 11 regions.
    const sc = onig.newScanner([String.raw`(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)`]);
    const s = onig.writeString('abcdefghij');
    const m = onig.find(sc, s, 0);
    assert.equal(m.caps.length, 11);
    assert.deepEqual(m.caps[0], [0, 10]); // whole match
    for (let g = 1; g <= 10; g++) {
      assert.deepEqual(m.caps[g], [g - 1, g], `group ${g}`);
    }
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });
});

describe('edge cases', () => {
  test('empty subject: no match, zero count', () => {
    const sc = onig.newScanner([String.raw`\d+`]);
    const s = onig.writeString('');
    assert.equal(onig.find(sc, s, 0), null);
    assert.equal(onig.scanCount(sc, s), 0);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });

  test('empty pattern list: no match, zero count', () => {
    const sc = onig.newScanner([]);
    const s = onig.writeString('anything at all');
    assert.equal(onig.find(sc, s, 0), null);
    assert.equal(onig.scanCount(sc, s), 0);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });
});

describe('memory growth (buffer detachment) — the web marshalling hazard', () => {
  test('a subject larger than the initial heap forces growth and still matches', () => {
    // Initial linear memory is ~4.3 MB. A subject well past that forces malloc
    // to grow the memory, detaching every previously-created view. If the
    // marshalling ever cached a stale view, this would read garbage or throw.
    const before = onig.memBytes;
    const filler = ' '.repeat(6 * 1024 * 1024); // 6M spaces -> 12 MB UTF-16
    const subject = `${filler}needle${filler}`;
    const needleAt = filler.length; // UTF-16 index of "needle"

    const sc = onig.newScanner([String.raw`needle`]);
    const s = onig.writeString(subject);
    assert.ok(
      onig.memBytes > before,
      `expected wasm memory to grow past ${before}, got ${onig.memBytes}`,
    );

    // Offsets read back from a region deep past the growth point must be exact.
    const m = onig.find(sc, s, 0);
    assert.deepEqual(m.caps[0], [needleAt, needleAt + 'needle'.length]);

    // And a whole-buffer bulk scan over the grown memory counts correctly.
    assert.equal(onig.scanCount(sc, s), 1);

    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });

  test('bulk scanCount over a multi-megabyte subject is exact', () => {
    // "x " repeated: each "x" is one \w+ match. Big enough to have grown memory.
    const n = 500000;
    const sc = onig.newScanner([String.raw`\w+`]);
    const s = onig.writeString('x '.repeat(n)); // 1M units = 2 MB
    assert.equal(onig.scanCount(sc, s), n);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
  });
});

describe('resource churn (no corruption across many alloc/free cycles)', () => {
  test('1000 scanner+string create/scan/free cycles stay correct', () => {
    for (let i = 0; i < 1000; i++) {
      const sc = onig.newScanner([String.raw`\d+`, String.raw`[a-z]+`]);
      const s = onig.writeString('ab 12 cd 34 ef');
      assert.equal(onig.scanCount(sc, s), 5);
      const m = onig.find(sc, s, 0);
      assert.deepEqual(m.caps[0], [0, 2]);
      onig.free(s.p);
      onig.ex.onig_shim_scanner_free(sc);
    }
  });
});
