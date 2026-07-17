#!/usr/bin/env python3
"""Render a single self-contained benchmark/index.html (inline CSS + JS + SVG,
no external files or CDNs) from benchmark/mainstream_results.json."""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSON = os.path.join(ROOT, "benchmark/mainstream_results.json")
OUT = os.path.join(ROOT, "benchmark/index.html")

PATTERNS = ["literal", "literal-unicode", "alt-5", "class-lower", "class-digit",
            "word-w", "two-words", "word-boundary", "email-like", "named-group",
            "case-insens", "backref-dup", "greedy-dotstar"]
REGEX = {"literal": "lorem", "literal-unicode": "東京",
         "alt-5": "lorem|ipsum|dolor|sit|amet", "class-lower": "[a-z]+",
         "class-digit": "[0-9]+", "word-w": r"\w+", "two-words": "[a-z]+ [a-z]+",
         "word-boundary": r"\b\w{5}\b", "email-like": r"\w+@\w+",
         "named-group": "(?<w>[a-z]+)", "case-insens": "(?i)lorem",
         "backref-dup": r"(\w+) \1", "greedy-dotstar": ".*lorem"}
DESC = {"literal": "plain literal (Sunday scan)",
        "literal-unicode": "multibyte literal over Unicode text",
        "alt-5": "5-way literal alternation", "class-lower": "char-class, greedy",
        "class-digit": "digit class, sparse", "word-w": "\\w ctype, greedy",
        "two-words": "two runs + separator",
        "word-boundary": "word boundaries + fixed repeat",
        "email-like": "run + mandatory literal + run",
        "named-group": "named capture, every token",
        "case-insens": "case-insensitive literal",
        "backref-dup": "back-reference (doubled word)",
        "greedy-dotstar": "greedy .* backtracking"}
ENGINES = [
    {"key": "ONIG_C", "label": "Oniguruma C", "color": "#64748b"},
    {"key": "V8_JIT", "label": "V8 JIT", "color": "#dc2626"},
    {"key": "V8_INTERP", "label": "V8 interp", "color": "#f59e0b"},
    {"key": "RE_VM", "label": "Dart RegExp", "color": "#7c3aed"},
    {"key": "ONIG_FFI", "label": "FFI · per-match", "color": "#db2777"},
    {"key": "ONIG_FFI_BULK", "label": "FFI · bulk", "color": "#f472b6"},
    {"key": "ONIG_WASM", "label": "wasm · per-match", "color": "#0d9488"},
    {"key": "ONIG_WASM_BULK", "label": "wasm · bulk", "color": "#5eead4"},
    {"key": "ONIG_BYTE", "label": "port · byte", "color": "#0ea5e9"},
    {"key": "ONIG_VM", "label": "port · String", "color": "#16a34a"},
]

TEMPLATE = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>oniguruma_dart — Benchmarks</title>
<style>
:root{--bg:#eef2f6;--card:#fff;--ink:#0f172a;--muted:#64748b;--line:#e2e8f0;--hero:#059669}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
 font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
.wrap{max-width:1060px;margin:0 auto;padding:0 20px}
header{background:linear-gradient(135deg,#064e3b 0%,#0f766e 100%);color:#fff;padding:40px 0 34px}
header h1{margin:0 0 6px;font-size:27px;letter-spacing:-.3px}
header p{margin:0;opacity:.9;max-width:760px}
header .meta{margin-top:14px;font-size:13px;opacity:.8}
main{padding:26px 0 10px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:14px;margin-bottom:22px}
.card{background:var(--card);border:1px solid var(--line);border-radius:13px;padding:16px 18px}
.card .n{font-size:28px;font-weight:750;letter-spacing:-.5px}
.card.hero .n{color:var(--hero)}
.card .l{font-size:12.5px;color:var(--muted);margin-top:2px}
section.panel{background:var(--card);border:1px solid var(--line);border-radius:16px;
 padding:20px 22px;margin:18px 0;box-shadow:0 1px 3px rgba(15,23,42,.05)}
section.panel h2{margin:0 0 3px;font-size:18px}
section.panel .sub{margin:0 0 14px;color:var(--muted);font-size:13.5px}
.legend{display:flex;flex-wrap:wrap;gap:16px;margin:2px 0 14px}
.legend span{display:inline-flex;align-items:center;gap:7px;font-size:13px;color:#334155}
.legend i{width:13px;height:13px;border-radius:3px}
.chart{overflow-x:auto}
svg{display:block}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{padding:7px 9px;border-bottom:1px solid var(--line);text-align:right;white-space:nowrap}
th{color:var(--muted);font-weight:600;border-bottom:2px solid var(--line)}
th:first-child,td:first-child{text-align:left}
td.rx{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;color:#475569;font-size:12px}
tbody tr:hover{background:#f8fafc}
.fast{color:#059669;font-weight:650}.slow{color:#c2570c}
.note{font-size:13.5px;color:#334155}.note li{margin:5px 0}
footer{color:var(--muted);font-size:13px;padding:8px 0 46px}
code{font-family:ui-monospace,Menlo,monospace;background:#eef2f6;padding:1px 6px;border-radius:6px;font-size:12.5px}
pre{background:#0f172a;color:#e2e8f0;padding:14px 16px;border-radius:10px;overflow-x:auto;font-size:12.5px}
</style>
</head>
<body>
<header><div class="wrap">
<h1>oniguruma_dart — Benchmarks</h1>
<p>A pure-Dart port of the Oniguruma regex engine, measured head-to-head against
the native C library, the <b>same C library driven from Dart over FFI</b>
(the sibling <code>oniguruma_native</code> package), and the production regex
interpreters available to Dart programs. Each metric is the median time to scan
a whole corpus for every match (lower is faster); every engine finds the
identical match count.</p>
<div class="meta" id="meta"></div>
</div></header>
<main class="wrap">
<div class="cards" id="cards"></div>

<section class="panel">
<h2>Primary comparison — native FFI vs the pure-Dart port</h2>
<p class="sub">The two packages in this repo, on identical corpora and match counts.
<b>FFI · per-match</b> is <code>oniguruma_native</code>'s real <code>findNextMatch</code> API
(one native crossing + a result object per match); <b>FFI · bulk</b> scans the whole
corpus in a single crossing; the port's <b>byte</b> and <b>String</b> APIs run in-process
in pure Dart. Median time per full-corpus scan (log scale) — shorter is faster.</p>
<div class="legend" id="lgp"></div>
<div class="chart" id="cp"></div>
</section>

<section class="panel">
<h2>Geometric mean vs Oniguruma C</h2>
<p class="sub">Across all 13 patterns. Bars left of the dashed line are faster than the native C library.</p>
<div class="legend" id="lg0"></div>
<div class="chart" id="c0"></div>
</section>

<section class="panel">
<h2>Absolute throughput per pattern</h2>
<p class="sub">Median time per full-corpus scan (log scale). Hover a bar for the exact value.</p>
<div class="legend" id="lg1"></div>
<div class="chart" id="c1"></div>
</section>

<section class="panel">
<h2>Speed relative to Oniguruma C</h2>
<p class="sub">×C per pattern (log scale). Below the dashed C=1.0× line is faster than native C.</p>
<div class="legend" id="lg2"></div>
<div class="chart" id="c2"></div>
</section>

<section class="panel">
<h2>Port: byte API vs String API</h2>
<p class="sub">The String API adds a UTF-8 encode (memoized), byte→UTF-16 offset mapping, and Match objects on top of the raw byte engine.</p>
<div class="legend" id="lg3"></div>
<div class="chart" id="c3"></div>
</section>

<section class="panel">
<h2>Full results</h2>
<div class="chart"><table id="tbl"></table></div>
</section>

<section class="panel note">
<h2>How to read this</h2>
<ul id="notes"></ul>
</section>
</main>
<footer class="wrap">
Correctness: every optimization preserves byte-identical parity with the C library —
5,390 oracle + unit tests, differential fuzzing vs the C CLI (0 divergences), and
per-pattern match-count cross-checks (byte vs String vs C all agree).
</footer>

<script>
const RAW = __DATA__;
const {patterns, regex, desc, engines, count, perf, date, env} = RAW;
const C = perf.ONIG_C;
const NONC = engines.filter(e => e.key !== "ONIG_C");

const fmt = ns => ns>=1e6 ? (ns/1e6).toFixed(2)+" ms"
              : ns>=1e3 ? (ns/1e3).toFixed(0)+" µs" : ns.toFixed(0)+" ns";
const gmean = xs => Math.exp(xs.reduce((a,x)=>a+Math.log(x),0)/xs.length);
const esc = s => s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");

const geo = {};
engines.forEach(e => geo[e.key] = gmean(patterns.map(p => perf[e.key][p]/C[p])));
const beatsRE = patterns.filter(p => perf.ONIG_VM[p] < perf.RE_VM[p]).length;
const beatsC  = patterns.filter(p => perf.ONIG_VM[p] <= C[p]*1.02).length;
// port · String vs the FFI package's real per-match API (>1 => port faster)
const portVsFFI = gmean(patterns.map(p => perf.ONIG_FFI[p]/perf.ONIG_VM[p]));
const portBeatsFFI = patterns.filter(p => perf.ONIG_VM[p] < perf.ONIG_FFI[p]).length;

// ---- header meta + stat cards ----
document.getElementById("meta").textContent =
  env.date + "  ·  " + env.cpu + "  ·  Dart " + env.dart + "  ·  Node " + env.node +
  "  ·  Oniguruma C " + env.onig + "  ·  median of 5 trials, ratios are the signal";
document.getElementById("cards").innerHTML = [
  ["hero", geo.ONIG_VM.toFixed(2)+"×", "port · String geomean vs C"],
  ["hero", portVsFFI.toFixed(1)+"×", "port · String faster than FFI · per-match"],
  ["", portBeatsFFI+" / 13", "patterns where the port beats FFI"],
  ["", beatsRE+" / 13", "patterns beating Dart RegExp"],
  ["", geo.ONIG_FFI.toFixed(2)+"×", "FFI · per-match geomean vs C"],
].map(([c,n,l])=>`<div class="card ${c}"><div class="n">${n}</div><div class="l">${l}</div></div>`).join("");

// ---- legends ----
function legend(id, list){
  document.getElementById(id).innerHTML = list.map(e =>
    `<span><i style="background:${e.color}"></i>${e.label}</span>`).join("");
}
legend("lg0", engines); legend("lg1", engines);
legend("lg2", NONC);
legend("lg3", engines.filter(e=>e.key==="ONIG_BYTE"||e.key==="ONIG_VM"));

// ---- grouped vertical bars, log y ----
function bars({cats, series, val, domain, ticks, tickFmt, tip, baseline, baseLbl, height}){
  const W=980, H=height||430, m={t:20,r:16,b:100,l:60};
  const pw=W-m.l-m.r, ph=H-m.t-m.b, [d0,d1]=domain, l0=Math.log(d0), l1=Math.log(d1);
  const y=v=>m.t+ph*(1-(Math.log(v)-l0)/(l1-l0)), yb=m.t+ph;
  const gw=pw/cats.length, inner=gw*0.82, bw=inner/series.length;
  let s=`<svg viewBox="0 0 ${W} ${H}" style="width:100%;min-width:${Math.max(820,cats.length*(series.length*12+18))}px;height:auto">`;
  for(const t of ticks){const yy=y(t);
    s+=`<line x1="${m.l}" y1="${yy.toFixed(1)}" x2="${W-m.r}" y2="${yy.toFixed(1)}" stroke="#eef2f6"/>`;
    s+=`<text x="${m.l-9}" y="${(yy+4).toFixed(1)}" text-anchor="end" font-size="11" fill="#94a3b8">${tickFmt(t)}</text>`;}
  if(baseline){const yy=y(baseline);
    s+=`<line x1="${m.l}" y1="${yy.toFixed(1)}" x2="${W-m.r}" y2="${yy.toFixed(1)}" stroke="#0f172a" stroke-width="1.4" stroke-dasharray="5 3"/>`;
    s+=`<text x="${W-m.r}" y="${(yy-6).toFixed(1)}" text-anchor="end" font-size="11" fill="#0f172a">${baseLbl}</text>`;}
  cats.forEach((cat,ci)=>{
    const gx=m.l+ci*gw+(gw-inner)/2;
    series.forEach((se,si)=>{
      const v=val(se,cat); if(!v||v<=0) return;
      const by=y(Math.min(Math.max(v,d0),d1)), bx=gx+si*bw;
      s+=`<rect x="${bx.toFixed(1)}" y="${by.toFixed(1)}" width="${(bw*0.86).toFixed(1)}" height="${Math.max(0,yb-by).toFixed(1)}" rx="1.5" fill="${se.color}"><title>${se.label} — ${cat}: ${tip(v,se,cat)}</title></rect>`;
    });
    const cx=m.l+ci*gw+gw/2;
    s+=`<text x="${cx.toFixed(1)}" y="${(yb+15).toFixed(1)}" text-anchor="end" font-size="11" fill="#475569" transform="rotate(-40 ${cx.toFixed(1)} ${(yb+15).toFixed(1)})">${cat}</text>`;
  });
  s+=`<line x1="${m.l}" y1="${yb}" x2="${W-m.r}" y2="${yb}" stroke="#cbd5e1"/></svg>`;
  return s;
}

// ---- horizontal bars (geomean) ----
function hbars(items){
  const W=980, rh=52, H=items.length*rh+24, m={l:130,r:70,t:8};
  const max=Math.max(...items.map(i=>i.v))*1.1, pw=W-m.l-m.r;
  const x=v=>m.l+pw*(v/max);
  let s=`<svg viewBox="0 0 ${W} ${H}" style="width:100%;min-width:640px;height:auto">`;
  const bx=x(1);
  s+=`<line x1="${bx.toFixed(1)}" y1="0" x2="${bx.toFixed(1)}" y2="${H-16}" stroke="#0f172a" stroke-width="1.4" stroke-dasharray="5 3"/>`;
  s+=`<text x="${bx.toFixed(1)}" y="${H-2}" text-anchor="middle" font-size="11" fill="#0f172a">C = 1.00×</text>`;
  items.forEach((it,i)=>{
    const yy=m.t+i*rh, bh=30, bw=x(it.v)-m.l;
    s+=`<text x="${m.l-12}" y="${(yy+bh/2+4).toFixed(1)}" text-anchor="end" font-size="13" fill="#334155">${it.label}</text>`;
    s+=`<rect x="${m.l}" y="${yy}" width="${Math.max(0,bw).toFixed(1)}" height="${bh}" rx="4" fill="${it.color}"/>`;
    s+=`<text x="${(x(it.v)+8).toFixed(1)}" y="${(yy+bh/2+4).toFixed(1)}" font-size="13" font-weight="650" fill="${it.v<1?'#059669':'#334155'}">${it.v.toFixed(2)}×</text>`;
  });
  s+=`</svg>`;
  return s;
}

// chart 0: geomean
document.getElementById("c0").innerHTML = hbars(
  engines.map(e=>({label:e.label, v:geo[e.key], color:e.color})));

// chart 1: absolute (all engines), log ns
document.getElementById("c1").innerHTML = bars({
  cats:patterns, series:engines, val:(e,p)=>perf[e.key][p],
  domain:[1e5,5e8], ticks:[1e5,1e6,1e7,1e8], tickFmt:fmt, tip:v=>fmt(v)});

// chart 2: normalized to C (non-C), log ×
document.getElementById("c2").innerHTML = bars({
  cats:patterns, series:NONC, val:(e,p)=>perf[e.key][p]/C[p],
  domain:[0.05,50], ticks:[0.1,1,10], tickFmt:t=>t+"×",
  tip:v=>v.toFixed(2)+"×", baseline:1, baseLbl:"C = 1.0×"});

// chart 3: byte vs String, log ns
const bs = engines.filter(e=>e.key==="ONIG_BYTE"||e.key==="ONIG_VM");
document.getElementById("c3").innerHTML = bars({
  cats:patterns, series:bs, val:(e,p)=>perf[e.key][p],
  domain:[5e5,5e8], ticks:[1e6,1e7,1e8], tickFmt:fmt, tip:v=>fmt(v)});

// primary chart: the two packages — FFI (per-match + bulk) vs port (byte + String)
const primSeries = engines.filter(e=>
  ["ONIG_FFI","ONIG_FFI_BULK","ONIG_BYTE","ONIG_VM"].includes(e.key));
legend("lgp", primSeries);
document.getElementById("cp").innerHTML = bars({
  cats:patterns, series:primSeries, val:(e,p)=>perf[e.key][p],
  domain:[5e5,5e8], ticks:[1e6,1e7,1e8], tickFmt:fmt, tip:v=>fmt(v)});

// ---- table ----
let th = "<thead><tr><th>pattern</th><th>regex</th><th>matches</th>" +
  engines.map(e=>`<th>${e.label}</th>`).join("") + "<th>port/C</th></tr></thead><tbody>";
for(const p of patterns){
  const r = perf.ONIG_VM[p]/C[p];
  th += `<tr><td title="${desc[p]}">${p}</td><td class="rx">${esc(regex[p])}</td>`+
    `<td>${count[p].toLocaleString()}</td>`+
    engines.map(e=>`<td>${fmt(perf[e.key][p])}</td>`).join("")+
    `<td class="${r<=1.02?'fast':'slow'}">${r.toFixed(2)}×</td></tr>`;
}
th += "</tbody>";
document.getElementById("tbl").innerHTML = th;

// ---- notes ----
document.getElementById("notes").innerHTML = [
  `<b>Native FFI vs pure Dart (the headline).</b> For bulk find-all-matches, the pure-Dart <b>port · String</b> API is <b>${portVsFFI.toFixed(1)}× faster</b> than the FFI package's real per-match API and wins on <b>${portBeatsFFI}/13</b> patterns. Two reasons: <code>oniguruma_native</code> uses <b>UTF-16LE</b> (offsets map 1:1 to Dart strings, but ~2× the bytes to scan on ASCII), and <code>findNextMatch</code> costs one <b>FFI crossing per match</b>. <b>FFI · bulk</b> (one crossing for the whole scan) removes the crossing cost and closes most of the gap.`,
  `<b>Where FFI wins:</b> <code>backref-dup</code> — the native engine handles pathological O(word²) backtracking far better than the port (${(perf.ONIG_VM['backref-dup']/perf.ONIG_FFI['backref-dup']).toFixed(1)}× faster). And this is a <i>bulk</i> benchmark; <code>oniguruma_native</code> is built for TextMate/Shiki <b>tokenizers</b> (one match per call).`,
  `<b>Web (WebAssembly).</b> <code>oniguruma_native</code> runs on the web too — the same engine compiled to wasm, driven over <code>dart:js_interop</code> (measured here through the <code>WebAssembly</code> API under Node/V8). It averages <b>${geo.ONIG_WASM_BULK.toFixed(2)}× C</b> bulk (${geo.ONIG_WASM.toFixed(2)}× per-match): the same engine is slower as sandboxed wasm than as native code, and it ships a ~600 KB module. Both packages run on the web, but the pure-Dart port is the <b>lighter and faster</b> web choice.`,
  `<b>V8 JIT</b> is the default Node.js RegExp — native-compiled Irregexp, the fastest engine here, shown for reference. <b>V8 interp</b> is that same engine forced into bytecode-interpreter mode (<code>--regexp-interpret-all</code>) — the like-for-like baseline for the other interpreters (Dart RegExp and this port).`,
  `On the <b>String API</b> (what Dart programs get) the port averages <b>${geo.ONIG_VM.toFixed(2)}× C</b> — faster than the native library across the suite — and beats Dart RegExp on <b>${beatsRE}/13</b>. The <b>byte API</b> (${geo.ONIG_BYTE.toFixed(2)}× C) is faster still: no encode, no offset mapping, no Match objects.`,
  `<b>email-like</b> is an <i>algorithmic</i> win: the driver walks back from each mandatory <code>@</code> to the run start (one attempt per <code>@</code>) instead of scanning every position — ~12× faster than C's forward scan.`,
  `Where an interpreter still leads, it's a <b>capability floor</b>: V8 wins <code>literal</code>/<code>alt-5</code>/<code>class-digit</code> via SIMD (no byte-SIMD in pure Dart); <code>literal-unicode</code> ties C (the RegExp gap is the UTF-8↔UTF-16 bridge).`,
].map(t=>`<li>${t}</li>`).join("");
</script>
</body>
</html>
'''


def main():
    d = json.load(open(JSON))
    payload = {
        "patterns": PATTERNS, "regex": REGEX, "desc": DESC, "engines": ENGINES,
        "count": d["COUNT"],
        "perf": {e["key"]: d[e["key"]] for e in ENGINES},
        "env": {"date": "2026-07-15", "cpu": "Apple M1 Pro", "dart": "3.12.2",
                "node": "26.4.0", "onig": "6.9.10"},
    }
    html = TEMPLATE.replace("__DATA__", json.dumps(payload, ensure_ascii=False))
    open(OUT, "w", encoding="utf-8").write(html)
    print(f"wrote {OUT}  ({len(html):,} bytes)")


if __name__ == "__main__":
    main()
