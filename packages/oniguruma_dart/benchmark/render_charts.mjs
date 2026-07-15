// Renders static PNG chart images from benchmark/index.html for embedding in
// the README / benchmarks.md (GitHub & pub.dev can't run the dashboard's JS).
//
// It reuses the dashboard's OWN chart-rendering code: the <script> is run under
// a tiny DOM shim, and each chart div's captured innerHTML *is* the SVG markup.
// Each SVG is sized explicitly and screenshotted with headless Chrome (perfect
// SVG + text fidelity, at 2x for crisp images).
//
//   node benchmark/render_charts.mjs
//
// Output: benchmark/charts/{geomean,ffi-vs-port,absolute}.png
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'fs';
import { execFileSync } from 'child_process';
import { dirname, resolve } from 'path';
import { fileURLToPath } from 'url';

const HERE = dirname(fileURLToPath(import.meta.url));         // benchmark/
const OUT = resolve(HERE, 'charts');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// Which dashboard chart ids to export, the CSS render width (px), and the id of
// the legend div to bake in (grouped-bar charts encode series by colour only;
// the hbars geomean chart labels each bar, so it needs no legend).
const TARGETS = [
  { id: 'c0', name: 'geomean',     width: 980 },              // hbars, self-labeled
  { id: 'cp', name: 'ffi-vs-port', width: 1000, legend: 'lgp' }, // primary comparison
  { id: 'c1', name: 'absolute',    width: 1400, legend: 'lg1' }, // per-pattern, all engines
];

// Legend styling mirrors the dashboard's.
const LEGEND_CSS =
  '.legend{display:flex;flex-wrap:wrap;gap:16px;margin:0 0 12px}' +
  '.legend span{display:inline-flex;align-items:center;gap:7px;font-size:14px;color:#334155}' +
  '.legend i{width:14px;height:14px;border-radius:3px}';
const MAGICK = 'magick';

// --- 1. Run the dashboard script under a DOM shim to capture chart SVGs. ---
const html = readFileSync(resolve(HERE, 'index.html'), 'utf8');
const code = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const store = {};
const el = id => ({
  set innerHTML(v) { store[id] = v; }, get innerHTML() { return store[id] || ''; },
  set textContent(v) { store['txt:' + id] = v; }, get textContent() { return store['txt:' + id] || ''; },
});
globalThis.document = { getElementById: el };
new Function(code)();

// --- 2. Size each SVG explicitly, wrap in a white page, screenshot it. ---
mkdirSync(OUT, { recursive: true });
const FONT = '-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif';

for (const { id, name, width, legend } of TARGETS) {
  let svg = store[id];
  if (!svg) { console.error(`no SVG for #${id}`); process.exit(1); }
  const [, vw, vh] = svg.match(/viewBox="0 0 ([\d.]+) ([\d.]+)"/).map(Number);
  const h = Math.round(width * vh / vw);
  // Replace the responsive style with an explicit pixel size.
  svg = svg.replace(/style="width:100%[^"]*"/, `width="${width}" height="${h}"`);
  const legendHtml = legend ? `<div class="legend">${store[legend]}</div>` : '';
  // Pad generously (top + legend + bottom); `magick -trim` crops to content.
  const winH = h + 80;
  const page = `<!doctype html><meta charset="utf-8"><style>${LEGEND_CSS}</style>` +
    `<body style="margin:0;padding:20px;background:#fff;font-family:${FONT}">` +
    `${legendHtml}${svg}</body>`;
  const tmp = resolve(OUT, `_${name}.html`);
  const png = resolve(OUT, name + '.png');
  writeFileSync(tmp, page);
  execFileSync(CHROME, [
    '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-sandbox',
    '--force-device-scale-factor=2', `--window-size=${width + 40},${winH}`,
    `--screenshot=${png}`, `file://${tmp}`,
  ], { stdio: 'ignore' });
  // Crop the surrounding white to a tight frame, then re-pad a small margin.
  execFileSync(MAGICK, [png, '-trim', '+repage', '-bordercolor', 'white',
    '-border', '24', png], { stdio: 'ignore' });
  rmSync(tmp);
  console.log(`wrote charts/${name}.png  (~${width}px @2x, legend=${legend || 'n/a'})`);
}
