// The app icons, drawn as SVG on a 1024 grid. render.html draws one; render.sh
// renders every size and packs them into the .icns files build.sh bundles.
//
// Each icon has two arts: "large" for 128 pt and up, and "small", hand-tuned
// for 16 and 32 pt, where the large art's detail turns to mush.
//
// Two shapes:
// - "fullbleed": an opaque square, for the bundled icon. macOS 26 clips an
//   opaque icon to its squircle, but shrinks one with any transparency onto a
//   grey plate.
// - "squircle": the squircle on a transparent canvas, for icons set at runtime
//   with NSWorkspace.setIcon, which macOS shows as drawn.

const W = "#fff";
const circle = (cx, cy, r, attrs) => `<circle cx="${cx}" cy="${cy}" r="${r}" ${attrs}/>`;
const band = (r, y, w, c, extra = "") =>
  `<path d="M${512 - r} ${y} A${r} ${r} 0 0 1 ${512 + r} ${y}" fill="none" stroke="${c}" stroke-width="${w}" stroke-linecap="round" ${extra}/>`;

// Deterministic, so a star field is identical on every render.
function rng(seed) {
  return () => {
    seed |= 0; seed = (seed + 0x6D2B79F5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const sparkle = (x, y, s, op = 1) =>
  `<path d="M${x} ${y - s} Q${x} ${y} ${x + s} ${y} Q${x} ${y} ${x} ${y + s} Q${x} ${y} ${x - s} ${y} Q${x} ${y} ${x} ${y - s} Z" fill="${W}" opacity="${op}"/>`;

// Stars kept clear of the muffs and the band, so none sits on an edge.
function stars(seed, n, maxR) {
  const r = rng(seed);
  let s = "";
  for (let i = 0; i < n; i++) {
    const x = 130 + r() * 764, y = 130 + r() * 764, rad = 2.5 + r() * (maxR - 2.5), op = 0.35 + r() * 0.65;
    const nearMuff = Math.hypot(x - 300, y - 670) < 175 || Math.hypot(x - 724, y - 670) < 175;
    const onBand = y > 380 && y < 620 && Math.abs(Math.hypot(x - 512, y - 610) - 212) < 40;
    if (!nearMuff && !onBand) s += circle(x, y, rad, `fill="${W}" opacity="${op}"`);
  }
  return s;
}

// A fluffy cup: a disc ringed by lobes, lit from the top left, with a soft
// shadow under it so it sits on the tile.
function muff(cx, cy, fill, { core = 100, lobes = 10, lobeR = 44, spread = 98, shadow = true } = {}) {
  const shape = paint => circle(cx, cy, core, `fill="${paint}"`) + Array.from({ length: lobes }, (_, i) => {
    const a = (i / lobes) * Math.PI * 2 - Math.PI / 2;
    return circle(cx + spread * Math.cos(a), cy + spread * Math.sin(a), lobeR, `fill="${paint}"`);
  }).join("");
  return (shadow ? `<g transform="translate(0 18)" opacity=".28" filter="url(#soft)">${shape("#000")}</g>` : "") + shape(fill);
}
const muffGradient = (id, cx, cy, light, dark) =>
  `<radialGradient id="${id}" gradientUnits="userSpaceOnUse" cx="${cx - 60}" cy="${cy - 70}" r="230"><stop offset="0" stop-color="${light}"/><stop offset=".7" stop-color="${light}"/><stop offset="1" stop-color="${dark}"/></radialGradient>`;
const SMALL_MUFF = { core: 120, lobes: 7, lobeR: 68, spread: 110, shadow: false };
const zee = (x, y, s, c) =>
  `<path d="M${x} ${y} H${x + s} L${x} ${y + s} H${x + s}" fill="none" stroke="${c}" stroke-width="${Math.max(10, s / 3.6)}" stroke-linecap="round" stroke-linejoin="round"/>`;

// One character per cell; the palette maps characters to colours, and any
// character missing from it (".") is left empty.
function pixels(rows, palette, size) {
  const cols = Math.max(...rows.map(r => r.length));
  const cell = size / Math.max(cols, rows.length);
  const ox = 512 - (cols * cell) / 2, oy = 512 - (rows.length * cell) / 2;
  let s = "";
  rows.forEach((row, y) => [...row].forEach((ch, x) => {
    if (palette[ch]) s += `<rect x="${ox + x * cell}" y="${oy + y * cell}" width="${cell + 0.5}" height="${cell + 0.5}" fill="${palette[ch]}"/>`;
  }));
  return s;
}
const GHOST = [
  "....hhhhpppp....",
  "..pp..wwww..pp..",
  ".p..wwwwwwww..p.",
  "p..wwwwwwwwww..p",
  "p.wwwwwwwwwwws.p",
  "ppwwwkkwwkkwwspp",
  "ppwwwkkwwkkwwspp",
  "ppwwwwwwwwwwwspp",
  "qqwwwwwkkwwwwsqq",
  "qqwwwwwwwwwwwsqq",
  ".qwwwwwwwwwwwsq.",
  "..wwwwwwwwwwss..",
  "..ww.ww..ww.ss..",
];
const GHOST_SMALL = [
  "...hhhppp...",
  ".pp.wwww.pp.",
  "p.wwwwwwww.p",
  "pwwwwwwwwwsp",
  "ppwkkwwkkspp",
  "ppwkkwwkkspp",
  "ppwwwwwwwspp",
  "qqwwwwwwwsqq",
  ".qwwwwwwwsq.",
  "..wwwwwwss..",
  "..w.ww.ws.s.",
];
const GHOST_PALETTE = { h: "#ffa3cf", p: "#ff5fa2", q: "#d93d84", w: "#ffffff", s: "#d6ccff", k: "#2a1a52" };
const PIXEL_STARS = [[200, 210], [820, 240], [170, 800], [850, 830], [760, 170]]
  .map(([x, y], i) => `<rect x="${x}" y="${y}" width="${i % 2 ? 22 : 30}" height="${i % 2 ? 22 : 30}" fill="#b9a8ff" opacity=".55"/>`).join("");

const ICONS = {
  Starfield: {
    title: "Starfield",
    background: ["#262b74", "#090a24"],
    defs: muffGradient("g1L", 300, 670, W, "#c9cdf5") + muffGradient("g1R", 724, 670, W, "#c9cdf5") +
      muffGradient("g1Ls", 290, 680, W, "#c9cdf5") + muffGradient("g1Rs", 734, 680, W, "#c9cdf5") +
      `<radialGradient id="g1glow" cx=".5" cy=".55" r=".5"><stop offset="0" stop-color="#8f9bff" stop-opacity=".45"/><stop offset="1" stop-color="#8f9bff" stop-opacity="0"/></radialGradient>
       <linearGradient id="g1band" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#d9deff"/><stop offset="1" stop-color="#8f9bff"/></linearGradient>`,
    large: () => stars(7, 70, 7) + `<ellipse cx="512" cy="560" rx="360" ry="300" fill="url(#g1glow)"/>` +
      sparkle(330, 290, 34) + sparkle(712, 240, 24) + sparkle(826, 450, 16, .8) + sparkle(200, 470, 14, .7) +
      band(212, 610, 38, "url(#g1band)") + muff(300, 670, "url(#g1L)") + muff(724, 670, "url(#g1R)"),
    small: () => sparkle(330, 300, 70) + sparkle(724, 260, 46) + band(220, 600, 70, "#c4caff") +
      muff(290, 680, "url(#g1Ls)", SMALL_MUFF) + muff(734, 680, "url(#g1Rs)", SMALL_MUFF),
  },
  Sleepy: {
    title: "Sleepy",
    background: ["#d6ecff", "#7fb6ff"],
    defs: muffGradient("ycL", 300, 670, W, "#cfe0fb") + muffGradient("ycR", 724, 670, W, "#cfe0fb") +
      muffGradient("ycLs", 290, 680, W, "#cfe0fb") + muffGradient("ycRs", 734, 680, W, "#cfe0fb"),
    large: () => `<ellipse cx="260" cy="260" rx="220" ry="140" fill="${W}" opacity=".35" filter="url(#soft)"/>` +
      zee(560, 250, 76, "#4a5bd1") + zee(672, 178, 50, "#6273e0") + zee(748, 136, 32, "#7d8cec") +
      band(212, 610, 38, "#4a5bd1") + muff(300, 670, "url(#ycL)") + muff(724, 670, "url(#ycR)"),
    small: () => zee(600, 170, 150, "#4a5bd1") + band(220, 600, 70, "#4a5bd1") +
      muff(290, 680, "url(#ycLs)", SMALL_MUFF) + muff(734, 680, "url(#ycRs)", SMALL_MUFF),
  },
  Ghost: {
    title: "Ghost",
    background: ["#46298a", "#1a0f36"],
    // Pixel art: a glass sheen would smear the pixels.
    flat: true,
    large: () => PIXEL_STARS + pixels(GHOST, GHOST_PALETTE, 640),
    small: () => pixels(GHOST_SMALL, GHOST_PALETTE, 700),
  },
};

/// The whole icon as one standalone SVG document.
function iconSVG(id, art, shape) {
  // The arguments come from render.html's URL: only known names may pick
  // which art function runs.
  if (!Object.hasOwn(ICONS, id)) throw new Error(`unknown icon id: ${id}`);
  if (art !== "large" && art !== "small") throw new Error(`unknown art: ${art}`);
  if (shape !== "fullbleed" && shape !== "squircle") throw new Error(`unknown shape: ${shape}`);
  const icon = ICONS[id];
  // The squircle body spans 100...924. Full bleed scales it up to fill the
  // canvas, so macOS's own squircle clip lands where ours would have.
  const body = shape === "fullbleed"
    ? { x: 0, y: 0, size: 1024, rx: 0, scale: `translate(512 512) scale(${1024 / 824}) translate(-512 -512)` }
    : { x: 100, y: 100, size: 824, rx: 185, scale: "" };
  const tile = `x="${body.x}" y="${body.y}" width="${body.size}" height="${body.size}" rx="${body.rx}"`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="100%" height="100%">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${icon.background[0]}"/><stop offset="1" stop-color="${icon.background[1]}"/></linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".28"/><stop offset=".4" stop-color="#fff" stop-opacity=".04"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".55"/><stop offset=".5" stop-color="#fff" stop-opacity=".05"/><stop offset="1" stop-color="#fff" stop-opacity=".25"/></linearGradient>
    <clipPath id="tile"><rect ${tile}/></clipPath>
    <filter id="soft" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="18"/></filter>
    ${icon.defs ?? ""}
  </defs>
  <rect ${tile} fill="url(#bg)"/>
  <g clip-path="url(#tile)"><g transform="${body.scale}">${icon[art]()}</g></g>
  ${icon.flat ? "" : `<rect ${tile} fill="url(#sheen)"/>`}
  ${shape === "squircle" ? `<rect x="103" y="103" width="818" height="818" rx="182" fill="none" stroke="url(#rim)" stroke-width="6"/>` : ""}
</svg>`;
}
