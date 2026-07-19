// WebAssembly module reliability tests, run under Node's built-in test runner:
//
//   node --test packages/oniguruma_native/test/wasm/
//
// These exercise the SHIPPED wasm artifact (prebuilt/web/oniguruma_native.wasm,
// whose SHA-256 wasm_provenance_test.dart checks against prebuilt/checksums.sha256)
// through the SAME WebAssembly API + UTF-8 marshalling that lib/src/web/ uses:
// backend_web.dart for the scanner (Layer 1) and lowlevel_web.dart for the raw
// onig_* accessors (Layer 0). Oniguruma runs in UTF-8; byte offsets are mapped
// back to UTF-16 code-unit indices via a per-string offset map (see
// lib/src/utf8_offsets.dart). So a failure here is a real bug in the wasm module
// or the marshalling contract, caught headlessly, no browser required, unlike
// test/oniguruma_web_test.dart.
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

// Encode to UTF-8 and (unless pure ASCII) build the byte<->UTF-16 offset maps.
// Mirrors lib/src/utf8_offsets.dart exactly.
function encodeUtf8WithMap(str) {
  const n = str.length;
  let byteLen = 0;
  let ascii = true;
  for (let i = 0; i < n; i++) {
    const c = str.charCodeAt(i);
    if (c < 0x80) { byteLen += 1; continue; }
    ascii = false;
    if (c < 0x800) byteLen += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < n &&
             str.charCodeAt(i + 1) >= 0xdc00 && str.charCodeAt(i + 1) <= 0xdfff) {
      byteLen += 4; i++;
    } else byteLen += 3;
  }
  if (ascii) {
    const bytes = new Uint8Array(n);
    for (let i = 0; i < n; i++) bytes[i] = str.charCodeAt(i);
    return { bytes, u16Length: n, ascii: true, byteToU16: null, u16ToByte: null };
  }
  const bytes = new Uint8Array(byteLen);
  const byteToU16 = new Int32Array(byteLen + 1);
  const u16ToByte = new Int32Array(n + 1);
  let b = 0;
  let u = 0;
  while (u < n) {
    const c = str.charCodeAt(u);
    const startByte = b;
    if (c < 0x80) {
      byteToU16[b] = u; bytes[b++] = c;
      u16ToByte[u] = startByte; u += 1;
    } else if (c < 0x800) {
      byteToU16[b] = u; bytes[b++] = 0xc0 | (c >> 6);
      byteToU16[b] = u; bytes[b++] = 0x80 | (c & 0x3f);
      u16ToByte[u] = startByte; u += 1;
    } else if (c >= 0xd800 && c <= 0xdbff && u + 1 < n &&
               str.charCodeAt(u + 1) >= 0xdc00 && str.charCodeAt(u + 1) <= 0xdfff) {
      const cp = 0x10000 + ((c - 0xd800) << 10) + (str.charCodeAt(u + 1) - 0xdc00);
      byteToU16[b] = u; bytes[b++] = 0xf0 | (cp >> 18);
      byteToU16[b] = u; bytes[b++] = 0x80 | ((cp >> 12) & 0x3f);
      byteToU16[b] = u; bytes[b++] = 0x80 | ((cp >> 6) & 0x3f);
      byteToU16[b] = u; bytes[b++] = 0x80 | (cp & 0x3f);
      u16ToByte[u] = startByte; u16ToByte[u + 1] = startByte; u += 2;
    } else {
      byteToU16[b] = u; bytes[b++] = 0xe0 | (c >> 12);
      byteToU16[b] = u; bytes[b++] = 0x80 | ((c >> 6) & 0x3f);
      byteToU16[b] = u; bytes[b++] = 0x80 | (c & 0x3f);
      u16ToByte[u] = startByte; u += 1;
    }
  }
  byteToU16[b] = u; u16ToByte[u] = b;
  return { bytes, u16Length: n, ascii: false, byteToU16, u16ToByte };
}

function u16ToByteOffset(enc, u16) {
  if (u16 <= 0) return 0;
  if (u16 >= enc.u16Length) return enc.bytes.length;
  return enc.ascii ? u16 : enc.u16ToByte[u16];
}

function byteToU16Offset(enc, b) {
  if (b < 0) return -1;
  return enc.ascii ? b : enc.byteToU16[b];
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

  // Allocate + write a UTF-8 subject/pattern; returns {p, byteLen, units, enc}.
  writeString(str) {
    const enc = encodeUtf8WithMap(str);
    const bytes = enc.bytes;
    const byteLen = bytes.length;
    const p = this.malloc(byteLen === 0 ? 1 : byteLen);
    if (byteLen !== 0) {
      // View derived AFTER malloc (growth-safe), one crossing, as backend_web.
      new Uint8Array(this.ex.memory.buffer, p, byteLen).set(bytes);
    }
    return { p, byteLen, units: str.length, enc };
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
    const enc = str.enc;
    const idx = this.ex.onig_shim_find(
      sc, str.p, str.byteLen, u16ToByteOffset(enc, startUnit),
      this.numRegs, this.beg, this.end, this.cap,
    );
    if (idx < 0) return null;
    const dv = new DataView(this.ex.memory.buffer);
    const nr = dv.getInt32(this.numRegs, true);
    const caps = [];
    for (let g = 0; g < nr; g++) {
      const b = dv.getInt32(this.beg + g * 4, true);
      const e = dv.getInt32(this.end + g * 4, true);
      caps.push([byteToU16Offset(enc, b), byteToU16Offset(enc, e)]);
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

  // --- Layer 0 (raw onig_* via flat-int shim accessors; byte offsets) ---

  _readRegs() {
    const dv = new DataView(this.ex.memory.buffer);
    const nr = dv.getInt32(this.numRegs, true);
    const regs = [];
    for (let g = 0; g < nr; g++) {
      regs.push([dv.getInt32(this.beg + g * 4, true),
                 dv.getInt32(this.end + g * 4, true)]);
    }
    return regs;
  }

  regexNew(pattern, { enc = 0, syntax = 0, options = 0 } = {}) {
    const p = this.writeString(pattern);
    const errOut = this.malloc(4);
    const reg = this.ex.onig_shim_regex_new(
      p.p, p.byteLen, options, enc, syntax, errOut);
    const code = new DataView(this.ex.memory.buffer).getInt32(errOut, true);
    this.free(p.p);
    this.free(errOut);
    return { reg, code };
  }

  regexFree(reg) { this.ex.onig_shim_regex_free(reg); }

  errorString(code) {
    const buf = this.malloc(96);
    const len = this.ex.onig_shim_error_string(code, buf, 90);
    const u8 = new Uint8Array(this.ex.memory.buffer);
    let s = '';
    for (let i = 0; i < len; i++) s += String.fromCharCode(u8[buf + i]);
    this.free(buf);
    return s;
  }

  search(reg, str, start = 0) {
    const pos = this.ex.onig_shim_search(
      reg, str.p, str.byteLen, start, str.byteLen, 0,
      this.numRegs, this.beg, this.end, this.cap);
    return { pos, regs: pos < 0 ? [] : this._readRegs() };
  }

  match(reg, str, at = 0) {
    const len = this.ex.onig_shim_match(
      reg, str.p, str.byteLen, at, 0,
      this.numRegs, this.beg, this.end, this.cap);
    return { len, regs: len < 0 ? [] : this._readRegs() };
  }

  numberOfCaptures(reg) { return this.ex.onig_shim_number_of_captures(reg); }
  numberOfNames(reg) { return this.ex.onig_shim_number_of_names(reg); }

  nameToGroupNumbers(reg, name) {
    const p = this.writeString(name);
    const out = this.malloc(4 * 32);
    const count = this.ex.onig_shim_name_to_group_numbers(
      reg, p.p, p.byteLen, out, 32);
    const nums = [];
    if (count > 0) {
      const dv = new DataView(this.ex.memory.buffer);
      for (let i = 0; i < count; i++) nums.push(dv.getInt32(out + i * 4, true));
    }
    this.free(p.p);
    this.free(out);
    return { count, nums };
  }

  regsetSearch(set, str, start = 0, lead = 0) {
    const mp = this.malloc(4);
    const idx = this.ex.onig_shim_regset_search(
      set, str.p, str.byteLen, start, str.byteLen, lead, 0,
      mp, this.numRegs, this.beg, this.end, this.cap);
    let matchPos = -1, regs = [];
    if (idx >= 0) {
      matchPos = new DataView(this.ex.memory.buffer).getInt32(mp, true);
      regs = this._readRegs();
    }
    this.free(mp);
    return { idx, matchPos, regs };
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
      // Layer 1: scanner
      'onig_shim_scanner_new', 'onig_shim_scanner_free', 'onig_shim_find',
      'onig_shim_scan_count', 'onig_shim_version',
      // Layer 0: raw onig_* accessors
      'onig_shim_regex_new', 'onig_shim_regex_free', 'onig_shim_error_string',
      'onig_shim_search', 'onig_shim_match', 'onig_shim_number_of_captures',
      'onig_shim_number_of_names', 'onig_shim_name_to_group_numbers',
      'onig_shim_name_to_backref_number', 'onig_shim_regset_new',
      'onig_shim_regset_add', 'onig_shim_regset_search', 'onig_shim_regset_free',
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

describe('\\xHH grammar parity (UTF-8)', () => {
  // The cases the old UTF-16LE marshalling got wrong: \xHH is a raw byte, and
  // TextMate grammars author those bytes as UTF-8. Running Oniguruma in UTF-8
  // fixes the parity while offsets stay UTF-16 code-unit indices.
  function first(pattern, subject) {
    const sc = onig.newScanner([pattern]);
    const s = onig.writeString(subject);
    const m = onig.find(sc, s, 0);
    onig.free(s.p);
    onig.ex.onig_shim_scanner_free(sc);
    return m === null ? null : m.caps[0];
  }

  test('\\x41 matches ASCII "A"', () => {
    assert.deepEqual(first(String.raw`\x41`, 'zzAzz'), [2, 3]);
  });

  test('\\xC3\\xA9 (UTF-8 bytes of é) matches é', () => {
    assert.deepEqual(first(String.raw`\xC3\xA9`, 'abécd'), [2, 3]);
  });

  test('wide-hex code-point class matches accented chars', () => {
    assert.deepEqual(
      first(String.raw`[a-zA-Z\x{00C0}-\x{00FF}]+`, 'café {'), [0, 4],
    );
  });

  test('\\x{...} wide-hex still matches BMP + non-BMP', () => {
    assert.deepEqual(first(String.raw`\x{00E9}`, 'abécd'), [2, 3]);
    assert.deepEqual(first(String.raw`\x{1F600}`, 'x\u{1F600}y'), [1, 3]);
  });

  test('a literal non-ASCII pattern matches its character', () => {
    assert.deepEqual(first('é', 'abécd'), [2, 3]);
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

describe('memory growth (buffer detachment): the web marshalling hazard', () => {
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

describe('Layer 0 (raw onig_* accessors, byte offsets)', () => {
  test('regex_new + search fills the region with byte offsets', () => {
    const { reg, code } = onig.regexNew(String.raw`(\d+)-(\d+)`);
    assert.equal(code, 0);
    assert.ok(reg !== 0);
    const s = onig.writeString('ab 12-345 cd');
    const { pos, regs } = onig.search(reg, s, 0);
    assert.equal(pos, 3);
    assert.deepEqual(regs, [[3, 9], [3, 5], [6, 9]]);
    onig.free(s.p);
    onig.regexFree(reg);
  });

  test('search returns ONIG_MISMATCH (-1) on no match', () => {
    const { reg } = onig.regexNew(String.raw`\d+`);
    const s = onig.writeString('abc');
    assert.equal(onig.search(reg, s, 0).pos, -1);
    onig.free(s.p);
    onig.regexFree(reg);
  });

  test('match anchors and reports the matched byte length', () => {
    const { reg } = onig.regexNew(String.raw`\w+`);
    const s = onig.writeString('foo bar');
    const { len, regs } = onig.match(reg, s, 0);
    assert.equal(len, 3);
    assert.deepEqual(regs[0], [0, 3]);
    onig.free(s.p);
    onig.regexFree(reg);
  });

  test('regex_new reports an error code + message for a bad pattern', () => {
    const { reg, code } = onig.regexNew('(');
    assert.equal(reg, 0);
    assert.ok(code < 0);
    assert.match(onig.errorString(code), /parenthesis/);
  });

  test('name / capture introspection', () => {
    const { reg } = onig.regexNew(String.raw`(?<year>\d{4})-(?<mon>\d{2})`);
    assert.equal(onig.numberOfCaptures(reg), 2);
    assert.equal(onig.numberOfNames(reg), 2);
    assert.deepEqual(onig.nameToGroupNumbers(reg, 'year').nums, [1]);
    assert.deepEqual(onig.nameToGroupNumbers(reg, 'mon').nums, [2]);
    onig.regexFree(reg);
  });

  test('regset returns the left-most match + region', () => {
    const set = onig.ex.onig_shim_regset_new();
    onig.ex.onig_shim_regset_add(set, onig.regexNew(String.raw`\d+`).reg);
    onig.ex.onig_shim_regset_add(set, onig.regexNew(String.raw`[a-z]+`).reg);
    const s = onig.writeString('  abc123');
    const { idx, matchPos, regs } = onig.regsetSearch(set, s, 0);
    assert.equal(idx, 1); // [a-z]+ @2 beats \d+ @5
    assert.equal(matchPos, 2);
    assert.deepEqual(regs[0], [2, 5]);
    onig.free(s.p);
    onig.ex.onig_shim_regset_free(set);
  });

  test('Layer 0 search agrees with the scanner on the same match', () => {
    const { reg } = onig.regexNew(String.raw`\d+`);
    const s = onig.writeString('abc 42');
    const l0 = onig.search(reg, s, 0);
    const sc = onig.newScanner([String.raw`\d+`]);
    const scm = onig.find(sc, s, 0); // ASCII → byte offsets == UTF-16 indices
    assert.deepEqual(l0.regs[0], scm.caps[0]);
    onig.free(s.p);
    onig.regexFree(reg);
    onig.ex.onig_shim_scanner_free(sc);
  });
});
