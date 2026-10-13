// Renders Runtime/AppIcon.icns from the mark in Remote/src/helix.js
// (rsvg-convert rasterizes each size, iconutil packs them).
// Usage: node tools/make-icon.mjs [output.icns]
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { iconSVG } from '../Remote/src/helix.js';

const output = resolve(process.argv[2] || 'Runtime/AppIcon.icns');
const dir = mkdtempSync(join(tmpdir(), 'AppIcon-')), iconset = join(dir, 'AppIcon.iconset');
execFileSync('mkdir', [iconset]);
for (const points of [16, 32, 128, 256, 512]) {
  for (const [scale, suffix] of [[1, ''], [2, '@2x']]) {
    const pixels = points * scale, svg = join(dir, `${pixels}.svg`);
    writeFileSync(svg, iconSVG(pixels));
    execFileSync('rsvg-convert', ['-w', pixels, '-h', pixels, '-o', join(iconset, `icon_${points}x${points}${suffix}.png`), svg].map(String));
  }
}
execFileSync('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', output]);
rmSync(dir, { recursive: true, force: true });
console.log(output);
