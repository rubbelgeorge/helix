// Helix's mark: two mirrored sine strands (left/right) twisted into a
// helix under a swelling envelope. Depth changes at the crests; at every
// crossing one strand is clearly in front and the one behind gets a small
// gap. Front parts are wider and opaque, back parts narrower and translucent.
// The same geometry is in client/LosslessMark.swift (`MarkGeometry`);
// tools/make-icon.mjs renders the app icon from this file.

const TAU = Math.PI * 2;
export const W = 100, H = 60;
let uidCounter = 0;

const fmt = n => n.toFixed(2);
const polyline = pts => pts.map((p, i) => (i ? 'L' : 'M') + fmt(p[0]) + ' ' + fmt(p[1])).join('');

/** The mark's SVG content in a W×H box, filled with currentColor. `phase` turns the helix. */
export function markContent(phase = 0, small = false) {
  const cycles = small ? 1.5 : 2.5, sw = small ? 8 : 5.2, gap = small ? 2.2 : 1.7, N = small ? 120 : 360;
  const back = 0.34, thin = 0.62, amp = H / 2 - sw / 2, x0 = sw / 2, span = W - sw;
  const env = t => Math.pow(Math.max(0, Math.sin(Math.PI * t)), 1.6);
  const angle = t => TAU * cycles * (t - 0.5) + phase;
  const pos = (s, t) => [x0 + t * span, H / 2 - s * amp * env(t) * Math.cos(angle(t))];
  const depth = (s, t) => s * Math.sin(angle(t)); // −1 back … +1 front
  const uid = 'hx' + (++uidCounter);

  // One filled outline per strand (no overlapping caps); width follows depth, ends taper to a point.
  function outline(s) {
    const up = [], lo = [];
    for (let i = 0; i <= N; i++) {
      const t = i / N, [x, y] = pos(s, t);
      const [ax, ay] = pos(s, Math.max(0, t - 1e-3)), [bx, by] = pos(s, Math.min(1, t + 1e-3));
      const n = Math.hypot(bx - ax, by - ay), nx = -(by - ay) / n, ny = (bx - ax) / n;
      const d = (depth(s, t) + 1) / 2, taper = Math.pow(Math.sin(Math.PI * t), 0.45);
      const half = sw * (thin + (1 - thin) * d) * taper / 2;
      up.push([x + nx * half, y + ny * half]); lo.push([x - nx * half, y - ny * half]);
    }
    return polyline(up.concat(lo.reverse())) + 'Z';
  }
  // Opacity by depth depends on x only, so a horizontal gradient mask carries it.
  function gradient(s) {
    let stops = '';
    for (let i = 0; i <= 64; i++) {
      const t = i / 64, d = (depth(s, t) + 1) / 2, a = back + (1 - back) * Math.pow(d, 1.3);
      stops += `<stop offset="${fmt(t * 100)}%" stop-color="#fff" stop-opacity="${a.toFixed(3)}"/>`;
    }
    return `<linearGradient id="${uid}g${s}" gradientUnits="userSpaceOnUse" x1="${x0}" x2="${x0 + span}" y1="0" y2="0">${stops}</linearGradient>`;
  }
  // Where the other strand is in front at a crossing, cut a gap out of this one.
  function knockout(s) {
    const o = -s, win = 0.16 / cycles;
    let cuts = '';
    for (let k = -20; k <= 20; k++) {
      const c = 0.5 + ((k + 0.5) * Math.PI - phase) / (TAU * cycles); // cos(angle) = 0
      if (c < 0.06 || c > 0.94 || depth(o, c) < 0) continue;
      const pts = [];
      for (let i = 0; i <= 24; i++) pts.push(pos(o, Math.min(1, Math.max(0, c - win + 2 * win * i / 24))));
      cuts += `<path d="${polyline(pts)}" fill="none" stroke="#000" stroke-width="${sw + 2 * gap}" stroke-linecap="round"/>`;
    }
    return cuts;
  }
  let defs = '', body = '';
  for (const s of [1, -1]) {
    defs += gradient(s) + `<mask id="${uid}m${s}" maskUnits="userSpaceOnUse" x="-10" y="-10" width="${W + 20}" height="${H + 20}">`
      + `<rect x="-10" y="-10" width="${W + 20}" height="${H + 20}" fill="url(#${uid}g${s})"/>${knockout(s)}</mask>`;
    body += `<path d="${outline(s)}" fill="currentColor" mask="url(#${uid}m${s})"/>`;
  }
  return `<defs>${defs}</defs>${body}`;
}

/** A standalone mark, `width`×`height` CSS pixels. Small sizes get fewer, bolder turns. */
export function markSVG(width, height, phase = 0) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="-2 -2 ${W + 4} ${H + 4}" overflow="visible" aria-hidden="true">${markContent(phase, width < 26)}</svg>`;
}

/** The app icon on the macOS grid (824/1024 body), rose gradient squircle with the white mark. */
export function iconSVG(size, phase = 0) {
  const id = 'hxicon' + (++uidCounter), small = size <= 32, r = 22.37 * 0.804;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 100 100">
  <defs>
    <linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ff6b85"/><stop offset="1" stop-color="#d9154a"/></linearGradient>
    <radialGradient id="${id}h" cx=".5" cy="0" r=".9"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
    <filter id="${id}s" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="1.2" stdDeviation="1.6" flood-color="#000" flood-opacity=".25"/></filter>
  </defs>
  <g filter="url(#${id}s)"><rect x="9.8" y="9.8" width="80.4" height="80.4" rx="${r}" fill="url(#${id})"/></g>
  <rect x="9.8" y="9.8" width="80.4" height="80.4" rx="${r}" fill="url(#${id}h)"/>
  <g color="#fff" transform="translate(19 31.4) scale(0.62)">${markContent(phase, small)}</g>
</svg>`;
}
