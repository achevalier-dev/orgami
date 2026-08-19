# shellcheck shell=bash
# map/graph.html — the map as one page you can open.
#
# ARCHITECTURE.md is the readable form and `orgami view` is the fast one, but
# both are lists, and a list is the one shape a graph is bad at. Three repos all
# reaching the same host, the one service everything depends on, the corner of
# the org nothing points at — you see those in a picture in a second and never
# find them by scrolling a table.
#
# The rules the rest of orgami runs on hold here too. The file is generated from
# map/graph.json and nothing else, it is self-contained — no CDN, no fonts, no
# network at all, so it works from a file:// URL and inside a private repo — and
# every edge you click shows the evidence it came from and whether that evidence
# is a line you can open or a match somebody's tooling made. Layout is seeded
# from the node names, so the same map draws the same way on every machine.

# The data the page needs, and no more: enough to draw, filter, and show
# evidence. Symbol listings and PR history stay in their own files.
html_payload() {
  local g="$DIR/map/graph.json" d="$DIR/map/depth.json" l="$DIR/map/live.json"
  local depth='null' live='null'
  [[ -f $d ]] && depth=$(jq -c '{generated, totals,
      repos: [.repos[] | select(.parsed > 0)
              | {name, parsed, symbol_count, exported_count, external_modules,
                 languages}]}' "$d" 2>/dev/null || echo null)
  [[ -f $l ]] && live=$(jq -c '{generated,
      deployments: [.deployments[] | {repo, provider, name, state, urls}]}' "$l" \
    2>/dev/null || echo null)

  jq -c --argjson depth "$depth" --argjson live "$live" \
    --arg company "$COMPANY" '
    def conf: (.confidence // (if (.kind | IN("calls", "shares-config", "changes-with"))
                               then "inferred" else "extracted" end));
    {company: $company, org: .org, generated: .generated,
     nodes: [.nodes[] | {id, kind, name,
                         language: (.meta.language // null),
                         description: (.meta.description // null),
                         url: (.meta.url // null),
                         pushed: (.meta.pushed_at // null),
                         private: (.meta.private // null)}],
     edges: [.edges[] | {from, to, kind, evidence, confidence: conf}],
     depth: $depth, live: $live}' "$g"
}

cmd_html() {
  load_company
  [[ $# -eq 0 ]] || die "unknown flag: $1"
  html_render
  echo "$DIR/map/graph.html"
}

html_render() {
  local g="$DIR/map/graph.json"
  [[ -f $g ]] || die "no map yet — run: orgami scan"
  local out="$DIR/map/graph.html"
  local payload
  payload=$(html_payload)

  # `</script>` inside the data would end the block early. Escaping the slash
  # keeps the JSON identical to a parser and inert to the HTML tokenizer.
  payload=${payload//<\//<\\/}

  {
    cat <<'HTMLHEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>
HTMLHEAD
    printf '%s — the map</title>\n' "$(html_escape "$COMPANY")"
    cat <<'HTMLHEAD2'
<style>
:root {
  --bg: #ffffff; --panel: #f6f7f9; --line: #e3e6ea; --ink: #16181d;
  --muted: #6b7280; --faint: #9aa1ab;
  --repo: #2f6feb; --host: #b45309; --tool: #7c3aed; --service: #0f766e;
  --vendor: #be185d; --lang: #64748b; --accent: #2f6feb; --shadow: rgba(16,24,40,.10);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0f1115; --panel: #161a21; --line: #262c36; --ink: #e6e9ef;
    --muted: #98a1af; --faint: #6b7482;
    --repo: #6ea8ff; --host: #f0b45c; --tool: #b98cff; --service: #4fd1c5;
    --vendor: #f472b6; --lang: #94a3b8; --accent: #6ea8ff; --shadow: rgba(0,0,0,.5);
  }
}
* { box-sizing: border-box; }
html, body { height: 100%; margin: 0; }
body {
  background: var(--bg); color: var(--ink); overflow: hidden;
  font: 14px/1.5 ui-sans-serif, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
}
code, .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12px; }
header {
  position: fixed; inset: 0 0 auto 0; z-index: 3; display: flex; flex-wrap: wrap;
  gap: 10px 16px; align-items: center; padding: 10px 16px;
  background: color-mix(in srgb, var(--bg) 88%, transparent);
  backdrop-filter: blur(8px); border-bottom: 1px solid var(--line);
}
header h1 { font-size: 14px; margin: 0; font-weight: 650; letter-spacing: -.01em; }
header .sub { color: var(--muted); font-size: 12px; }
input[type=search] {
  background: var(--panel); border: 1px solid var(--line); color: var(--ink);
  border-radius: 7px; padding: 5px 9px; width: 190px; font-size: 13px;
}
input[type=search]:focus { outline: 2px solid color-mix(in srgb, var(--accent) 45%, transparent); outline-offset: 1px; }
.toggles { display: flex; gap: 4px; flex-wrap: wrap; }
.chip {
  border: 1px solid var(--line); background: var(--panel); color: var(--muted);
  border-radius: 999px; padding: 3px 9px; font-size: 12px; cursor: pointer;
  user-select: none; display: inline-flex; align-items: center; gap: 5px;
}
.chip[aria-pressed="true"] { color: var(--ink); border-color: color-mix(in srgb, var(--ink) 25%, var(--line)); }
.chip .dot { width: 8px; height: 8px; border-radius: 50%; background: currentColor; }
.chip.off { opacity: .45; }
#stage { position: absolute; inset: 0; }
canvas { display: block; width: 100%; height: 100%; cursor: grab; }
canvas.dragging { cursor: grabbing; }
#panel {
  position: fixed; top: 0; right: 0; bottom: 0; width: min(430px, 92vw);
  background: var(--panel); border-left: 1px solid var(--line); z-index: 4;
  transform: translateX(100%); transition: transform .16s ease-out;
  overflow-y: auto; padding: 16px 18px 40px; box-shadow: -12px 0 32px var(--shadow);
}
#panel.open { transform: none; }
#panel h2 { margin: 0 0 2px; font-size: 17px; letter-spacing: -.01em; }
#panel .kind { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .06em; }
#panel .desc { color: var(--muted); margin: 10px 0 0; }
#panel h3 {
  font-size: 11px; text-transform: uppercase; letter-spacing: .08em;
  color: var(--muted); margin: 20px 0 7px; font-weight: 600;
}
#panel a { color: var(--accent); }
.edge { padding: 6px 0; border-top: 1px solid var(--line); }
.edge:first-of-type { border-top: 0; }
.edge .peer { font-weight: 600; cursor: pointer; }
.edge .peer:hover { text-decoration: underline; }
.edge .ev { color: var(--faint); display: block; word-break: break-word; }
.tag {
  font-size: 10px; padding: 1px 6px; border-radius: 999px; margin-left: 6px;
  border: 1px solid var(--line); color: var(--muted); vertical-align: 1px;
}
.tag.inferred { border-style: dashed; }
.close {
  position: absolute; top: 10px; right: 12px; background: none; border: 0;
  color: var(--muted); font-size: 20px; cursor: pointer; line-height: 1;
}
footer {
  position: fixed; left: 0; right: 0; bottom: 0; z-index: 2;
  padding: 7px 16px; font-size: 11px; color: var(--faint);
  background: color-mix(in srgb, var(--bg) 88%, transparent);
  border-top: 1px solid var(--line); display: flex; gap: 14px; flex-wrap: wrap;
}
footer .key { display: inline-flex; align-items: center; gap: 5px; }
footer svg { display: block; }
.empty { color: var(--muted); }
</style>
</head>
<body>
<header>
HTMLHEAD2
    printf '  <h1>%s</h1>\n' "$(html_escape "$COMPANY")"
    cat <<'HTMLHEAD3'
  <span class="sub" id="counts"></span>
  <input type="search" id="q" placeholder="filter — repo, host, tool…" autocomplete="off" spellcheck="false">
  <span class="toggles" id="kinds"></span>
  <span class="chip" id="inferred" role="button" aria-pressed="true">inferred edges</span>
</header>
<div id="stage"><canvas id="c"></canvas></div>
<aside id="panel" aria-live="polite"><button class="close" id="x" title="close">&times;</button><div id="body"></div></aside>
<footer>
  <span class="key"><svg width="26" height="6"><line x1="1" y1="3" x2="25" y2="3" stroke="currentColor" stroke-width="1.4"/></svg> extracted — a line you can open</span>
  <span class="key"><svg width="26" height="6"><line x1="1" y1="3" x2="25" y2="3" stroke="currentColor" stroke-width="1.4" stroke-dasharray="3 3"/></svg> inferred — matched, not declared</span>
  <span class="key">drag to move · scroll to zoom · click a node for its evidence</span>
</footer>
<script id="data" type="application/json">
HTMLHEAD3

    printf '%s\n' "$payload"

    cat <<'HTMLTAIL'
</script>
<script>
"use strict";
const G = JSON.parse(document.getElementById("data").textContent);

const KINDS = ["repo", "host", "tool", "service", "vendor", "lang"];
const COLOR = {};
{
  const cs = getComputedStyle(document.documentElement);
  for (const k of KINDS) COLOR[k] = cs.getPropertyValue("--" + k).trim() || "#888";
}
const RADIUS = { repo: 8, host: 6, tool: 5.5, service: 6, vendor: 6, lang: 4.5 };

/* Layout is seeded from the node id, not Math.random, so the same map draws
   the same way for everyone who opens it — a screenshot in a pull request
   matches what the next person sees. */
function seeded(str) {
  let h = 2166136261 >>> 0;
  for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; }
  return () => { h ^= h << 13; h >>>= 0; h ^= h >> 17; h ^= h << 5; h >>>= 0; return h / 4294967296; };
}

const byId = new Map();
const nodes = G.nodes.map((n, i) => {
  const r = seeded(n.id);
  const a = r() * Math.PI * 2, d = 120 + r() * 320;
  const node = { ...n, x: Math.cos(a) * d, y: Math.sin(a) * d, vx: 0, vy: 0,
                 deg: 0, r: RADIUS[n.kind] || 5, i };
  byId.set(n.id, node);
  return node;
});
const edges = G.edges.filter(e => byId.has(e.from) && byId.has(e.to)).map(e => ({
  ...e, s: byId.get(e.from), t: byId.get(e.to),
}));
for (const e of edges) { e.s.deg++; e.t.deg++; }
for (const n of nodes) n.r += Math.min(6, Math.sqrt(n.deg) * 1.4);

const depthBy = new Map((G.depth?.repos || []).map(r => [r.name, r]));
const liveBy = new Map();
for (const d of (G.live?.deployments || [])) {
  if (!liveBy.has(d.repo)) liveBy.set(d.repo, []);
  liveBy.get(d.repo).push(d);
}

/* --- the simulation ------------------------------------------------------
   Plain repulsion, springs and a pull to the middle. A few hundred nodes do
   not need a quadtree, and the shape settles in well under a second. */
const K_REPEL = 11000, K_SPRING = 0.022, LEN = 120, GRAVITY = 0.02, DAMP = 0.84;
let alpha = 1;

function tick() {
  for (let i = 0; i < nodes.length; i++) {
    const a = nodes[i];
    for (let j = i + 1; j < nodes.length; j++) {
      const b = nodes[j];
      let dx = b.x - a.x, dy = b.y - a.y;
      let d2 = dx * dx + dy * dy;
      if (d2 < 1) { d2 = 1; dx = (a.i - b.i) || 1; dy = 1; }
      const f = K_REPEL / d2, d = Math.sqrt(d2);
      const fx = (dx / d) * f, fy = (dy / d) * f;
      a.vx -= fx; a.vy -= fy; b.vx += fx; b.vy += fy;
    }
  }
  for (const e of edges) {
    const dx = e.t.x - e.s.x, dy = e.t.y - e.s.y;
    const d = Math.max(1, Math.hypot(dx, dy));
    const f = (d - LEN) * K_SPRING;
    const fx = (dx / d) * f, fy = (dy / d) * f;
    e.s.vx += fx; e.s.vy += fy; e.t.vx -= fx; e.t.vy -= fy;
  }
  for (const n of nodes) {
    n.vx -= n.x * GRAVITY; n.vy -= n.y * GRAVITY;
    if (n === dragging) { n.vx = n.vy = 0; continue; }
    n.vx *= DAMP; n.vy *= DAMP;
    n.x += n.vx * alpha; n.y += n.vy * alpha;
  }
  alpha = Math.max(0.03, alpha * 0.994);
}

/* Whatever shape the simulation settles into, put all of it on the screen.
   Cheaper than tuning constants that hold for one organization and not the
   next, and it is what somebody opening the file expects to see. */
let userMoved = false;
function fit() {
  const vis = nodes.filter(nodeVisible);
  if (!vis.length) return;
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const n of vis) {
    x0 = Math.min(x0, n.x); x1 = Math.max(x1, n.x);
    y0 = Math.min(y0, n.y); y1 = Math.max(y1, n.y);
  }
  const pad = 70;
  view.k = Math.min(2.2, Math.max(0.25,
    Math.min((W - pad * 2) / Math.max(1, x1 - x0), (H - pad * 2 - 40) / Math.max(1, y1 - y0))));
  view.x = -(x0 + x1) / 2;
  view.y = -(y0 + y1) / 2;
}

/* --- drawing -------------------------------------------------------------- */
const cv = document.getElementById("c"), ctx = cv.getContext("2d");
let view = { x: 0, y: 0, k: 1 }, dpr = 1, W = 0, H = 0;
let hover = null, selected = null, dragging = null, panning = null;
let query = "", showInferred = true;
const kindOn = Object.fromEntries(KINDS.map(k => [k, true]));

function resize() {
  dpr = window.devicePixelRatio || 1;
  W = cv.clientWidth; H = cv.clientHeight;
  cv.width = W * dpr; cv.height = H * dpr;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
}
window.addEventListener("resize", () => { resize(); if (!userMoved) fit(); });

const toScreen = n => ({ x: (n.x + view.x) * view.k + W / 2, y: (n.y + view.y) * view.k + H / 2 });
const toWorld = (px, py) => ({ x: (px - W / 2) / view.k - view.x, y: (py - H / 2) / view.k - view.y });

const matches = n => !query || n.name.toLowerCase().includes(query) ||
  (n.description || "").toLowerCase().includes(query);
const nodeVisible = n => kindOn[n.kind] !== false;
const edgeVisible = e => nodeVisible(e.s) && nodeVisible(e.t) &&
  (showInferred || e.confidence !== "inferred");

let CSS_LINE = "#ccc", CSS_INK = "#222";
function readTheme() {
  const cs = getComputedStyle(document.documentElement);
  CSS_LINE = cs.getPropertyValue("--line").trim();
  CSS_INK = cs.getPropertyValue("--ink").trim();
  for (const k of KINDS) COLOR[k] = cs.getPropertyValue("--" + k).trim() || "#888";
}
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", readTheme);

function draw() {
  ctx.clearRect(0, 0, W, H);
  const neighbours = new Set();
  if (selected) {
    neighbours.add(selected.id);
    for (const e of edges) {
      if (!edgeVisible(e)) continue;
      if (e.from === selected.id) neighbours.add(e.to);
      if (e.to === selected.id) neighbours.add(e.from);
    }
  }

  for (const e of edges) {
    if (!edgeVisible(e)) continue;
    const lit = selected && (e.from === selected.id || e.to === selected.id);
    const dim = (selected && !lit) || (query && !matches(e.s) && !matches(e.t));
    const a = toScreen(e.s), b = toScreen(e.t);
    ctx.beginPath();
    ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y);
    ctx.strokeStyle = lit ? COLOR[e.s.kind] : CSS_LINE;
    ctx.globalAlpha = dim ? 0.16 : (lit ? 0.85 : 0.5);
    ctx.lineWidth = lit ? 1.6 : 1;
    ctx.setLineDash(e.confidence === "inferred" ? [3, 3] : []);
    ctx.stroke();
  }
  ctx.setLineDash([]);
  ctx.globalAlpha = 1;

  for (const n of nodes) {
    if (!nodeVisible(n)) continue;
    const p = toScreen(n);
    const dim = (query && !matches(n)) || (selected && !neighbours.has(n.id));
    const rr = n.r * Math.min(1.6, Math.max(0.7, view.k));
    ctx.globalAlpha = dim ? 0.2 : 1;
    ctx.beginPath();
    ctx.arc(p.x, p.y, rr, 0, Math.PI * 2);
    ctx.fillStyle = COLOR[n.kind] || "#888";
    ctx.fill();
    if (n === selected || n === hover) {
      ctx.lineWidth = 2;
      ctx.strokeStyle = COLOR[n.kind];
      ctx.globalAlpha = 0.45;
      ctx.beginPath(); ctx.arc(p.x, p.y, rr + 4, 0, Math.PI * 2); ctx.stroke();
      ctx.globalAlpha = dim ? 0.2 : 1;
    }
    ctx.globalAlpha = 1;
  }

  /* Labels last, and only where one fits. Two names drawn on top of each other
     are less readable than one name and a dot you can click, so a label that
     would collide with one already on the page is dropped — the important ones
     go first. */
  const taken = [];
  /* Node discs are obstacles too — a name written across a circle is the same
     unreadable as a name written across another name. */
  for (const n of nodes) {
    if (!nodeVisible(n)) continue;
    const p = toScreen(n), rr = n.r * Math.min(1.6, Math.max(0.7, view.k));
    taken.push({ x0: p.x - rr, x1: p.x + rr, y0: p.y - rr, y1: p.y + rr });
  }
  const wanted = nodes.filter(n => nodeVisible(n) &&
    !((query && !matches(n)) || (selected && !neighbours.has(n.id))) &&
    (n.kind === "repo" || view.k > 1.2 || (query && matches(n)) || n === hover || n === selected));
  /* Priority when there is not room for every name: whatever you asked for,
     then what you are pointing at, then the busiest nodes. */
  const rank = n => (n === selected || n === hover ? 3 : 0) + (query && matches(n) ? 2 : 0);
  wanted.sort((a, b) => rank(b) - rank(a) || b.deg - a.deg);
  ctx.textAlign = "center";
  for (const n of wanted) {
    const p = toScreen(n);
    if (p.x < -60 || p.x > W + 60 || p.y < -20 || p.y > H + 20) continue;
    const strong = n === selected || n === hover;
    ctx.font = (strong ? "600 " : "") + "11px ui-sans-serif, sans-serif";
    const w = ctx.measureText(n.name).width;
    const rr = n.r * Math.min(1.6, Math.max(0.7, view.k));
    /* Above, below, right, left — a name pushed to one side still reads. Only
       when all four are blocked is the label worth losing. */
    const spots = [
      { dx: 0, dy: -rr - 10, align: "center" },
      { dx: 0, dy: rr + 14, align: "center" },
      { dx: rr + 6, dy: 4, align: "left" },
      { dx: -rr - 6, dy: 4, align: "right" },
    ];
    let placed = null;
    for (const sp of spots) {
      const cx = p.x + sp.dx, cy = p.y + sp.dy;
      const x0 = sp.align === "center" ? cx - w / 2 : sp.align === "left" ? cx : cx - w;
      const box = { x0: x0 - 2, x1: x0 + w + 2, y0: cy - 9, y1: cy + 3 };
      if (!taken.some(t => box.x0 < t.x1 && box.x1 > t.x0 && box.y0 < t.y1 && box.y1 > t.y0)) {
        placed = { box, cx, cy, align: sp.align };
        break;
      }
    }
    if (!placed) { if (!strong) continue; placed = { box: null, cx: p.x, cy: p.y - rr - 10, align: "center" }; }
    if (placed.box) taken.push(placed.box);
    ctx.textAlign = placed.align;
    ctx.fillStyle = CSS_INK;
    ctx.globalAlpha = strong ? 1 : (n.kind === "repo" ? 0.9 : 0.65);
    ctx.fillText(n.name, placed.cx, placed.cy);
  }
  ctx.textAlign = "center";
  ctx.globalAlpha = 1;
}

function frame() { tick(); draw(); requestAnimationFrame(frame); }

/* --- the panel ------------------------------------------------------------ */
const panel = document.getElementById("panel"), body = document.getElementById("body");
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const bare = id => id.replace(/^[a-z-]+:/, "");

function show(node) {
  selected = node;
  if (!node) { panel.classList.remove("open"); return; }
  const mine = edges.filter(e => e.from === node.id || e.to === node.id);
  const groups = new Map();
  for (const e of mine) {
    if (!showInferred && e.confidence === "inferred") continue;
    const out = e.from === node.id;
    const key = (out ? "" : "← ") + e.kind;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push({ peer: bare(out ? e.to : e.from), id: out ? e.to : e.from,
                           ev: e.evidence, c: e.confidence });
  }

  const d = depthBy.get(node.name), live = liveBy.get(node.name);
  let h = `<h2>${esc(node.name)}</h2><div class="kind">${esc(node.kind)}${
    node.language ? " · " + esc(node.language) : ""}${node.private ? " · private" : ""}</div>`;
  if (node.description) h += `<p class="desc">${esc(node.description)}</p>`;
  if (node.url) h += `<p><a href="${esc(node.url)}" target="_blank" rel="noopener">open on GitHub →</a></p>`;
  if (d) h += `<h3>parsed</h3><div>${d.parsed} files · ${d.symbol_count} definitions · ` +
    `<strong>${d.exported_count} exported</strong> · ${d.external_modules} external packages</div>`;
  if (live && live.length) {
    h += `<h3>running now</h3>` + live.map(x =>
      `<div class="edge"><span class="peer">${esc(x.provider)} ${esc(x.name)}</span>` +
      `<span class="ev">${esc(x.state || "")} ${(x.urls || []).map(u => esc(u)).join(" ")}</span></div>`).join("");
  }

  if (!groups.size) h += `<h3>edges</h3><p class="empty">Nothing in committed configuration links this to anything else.</p>`;
  for (const [kind, list] of groups) {
    h += `<h3>${esc(kind)}</h3>`;
    for (const e of list) {
      h += `<div class="edge"><span class="peer" data-id="${esc(e.id)}">${esc(e.peer)}</span>` +
        `<span class="tag ${e.c}">${e.c}</span>` +
        (e.ev ? `<span class="ev mono">${esc(e.ev)}</span>` : "") + `</div>`;
    }
  }
  body.innerHTML = h;
  panel.classList.add("open");
  for (const el of body.querySelectorAll(".peer[data-id]")) {
    el.addEventListener("click", () => { const n = byId.get(el.dataset.id); if (n) { show(n); centre(n); } });
  }
}
document.getElementById("x").addEventListener("click", () => show(null));

function centre(n) {
  userMoved = true;
  view.x = -n.x; view.y = -n.y;
  view.k = Math.max(view.k, 1.1);
  alpha = Math.max(alpha, 0.3);
}

/* --- input ---------------------------------------------------------------- */
function pick(px, py) {
  let best = null, bestD = 18 * 18;
  for (const n of nodes) {
    if (!nodeVisible(n)) continue;
    const p = toScreen(n);
    const d = (p.x - px) ** 2 + (p.y - py) ** 2;
    if (d < bestD) { bestD = d; best = n; }
  }
  return best;
}

cv.addEventListener("pointermove", ev => {
  const r = cv.getBoundingClientRect(), px = ev.clientX - r.left, py = ev.clientY - r.top;
  if (dragging) {
    const w = toWorld(px, py);
    dragging.x = w.x; dragging.y = w.y; alpha = Math.max(alpha, 0.35);
    return;
  }
  if (panning) {
    userMoved = true;
    view.x += (px - panning.x) / view.k; view.y += (py - panning.y) / view.k;
    panning = { x: px, y: py };
    return;
  }
  const h = pick(px, py);
  if (h !== hover) { hover = h; cv.style.cursor = h ? "pointer" : "grab"; }
});
cv.addEventListener("pointerdown", ev => {
  const r = cv.getBoundingClientRect(), px = ev.clientX - r.left, py = ev.clientY - r.top;
  const n = pick(px, py);
  cv.setPointerCapture(ev.pointerId);
  if (n) { dragging = n; show(n); } else { panning = { x: px, y: py }; cv.classList.add("dragging"); }
});
const release = () => { dragging = null; panning = null; cv.classList.remove("dragging"); };
cv.addEventListener("pointerup", release);
cv.addEventListener("pointercancel", release);
cv.addEventListener("wheel", ev => {
  ev.preventDefault();
  userMoved = true;
  const r = cv.getBoundingClientRect();
  const before = toWorld(ev.clientX - r.left, ev.clientY - r.top);
  view.k = Math.min(4, Math.max(0.25, view.k * (ev.deltaY < 0 ? 1.1 : 1 / 1.1)));
  const after = toWorld(ev.clientX - r.left, ev.clientY - r.top);
  view.x += after.x - before.x; view.y += after.y - before.y;
}, { passive: false });

const q = document.getElementById("q");
q.addEventListener("input", () => { query = q.value.trim().toLowerCase(); });
document.addEventListener("keydown", ev => {
  if (ev.key === "Escape") { show(null); q.blur(); }
  else if (ev.key === "/" && document.activeElement !== q) { ev.preventDefault(); q.focus(); }
});

const kindsEl = document.getElementById("kinds");
for (const k of KINDS) {
  const count = nodes.filter(n => n.kind === k).length;
  if (!count) continue;
  const b = document.createElement("span");
  b.className = "chip"; b.setAttribute("role", "button"); b.setAttribute("aria-pressed", "true");
  b.style.color = COLOR[k];
  b.innerHTML = `<span class="dot"></span><span style="color:var(--ink)">${k} ${count}</span>`;
  b.addEventListener("click", () => {
    kindOn[k] = !kindOn[k];
    b.classList.toggle("off", !kindOn[k]);
    b.setAttribute("aria-pressed", String(kindOn[k]));
    if (selected && !nodeVisible(selected)) show(null);
    alpha = Math.max(alpha, 0.4);
    if (!userMoved) fit();
  });
  kindsEl.appendChild(b);
}

const infEl = document.getElementById("inferred");
const inferredCount = edges.filter(e => e.confidence === "inferred").length;
infEl.textContent = `inferred edges ${inferredCount}`;
infEl.addEventListener("click", () => {
  showInferred = !showInferred;
  infEl.classList.toggle("off", !showInferred);
  infEl.setAttribute("aria-pressed", String(showInferred));
  if (selected) show(selected);
});

document.getElementById("counts").textContent =
  `${G.org} · ${nodes.filter(n => n.kind === "repo").length} repos · ${edges.length} edges · ` +
  `${edges.length - inferredCount} extracted, ${inferredCount} inferred · mapped ${(G.generated || "").slice(0, 10)}`;

readTheme();
resize();
for (let i = 0; i < 420; i++) tick();   /* settle before the first paint */
fit();
requestAnimationFrame(frame);
</script>
</body>
</html>
HTMLTAIL
  } >"$out"
}

# A company name goes into the page as text. It comes from a config file the
# team wrote, not from the internet, but it still has no business being markup.
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}
