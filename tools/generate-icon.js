#!/usr/bin/env node
/**
 * Renders the app icon: an original twin-bell alarm clock mark in the app's
 * black-and-safety-yellow palette. Written directly as a PNG so there is no
 * image dependency and the icon is reproducible from source.
 *
 *   node tools/generate-icon.js
 */

'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const SIZE = 1024;
const SS = 4; // supersampling factor per axis

const OUT_DIR = path.join(__dirname, '..', 'SuperAlarm', 'Assets.xcassets', 'AppIcon.appiconset');

// ------------------------------------------------------------------ colours

const YELLOW = [0xff, 0xd4, 0x00];
const INK = [0x0a, 0x0a, 0x0a];

// ---------------------------------------------------------------- geometry
// All coordinates are in 0..1 units so the design scales to any output size.

const circle = (x, y, cx, cy, r) => Math.hypot(x - cx, y - cy) <= r;

/** Distance from point to a line segment, for drawing the clock hands. */
function segmentDistance(x, y, x1, y1, x2, y2) {
  const dx = x2 - x1;
  const dy = y2 - y1;
  const lengthSq = dx * dx + dy * dy;
  if (lengthSq === 0) return Math.hypot(x - x1, y - y1);
  let t = ((x - x1) * dx + (y - y1) * dy) / lengthSq;
  t = Math.max(0, Math.min(1, t));
  return Math.hypot(x - (x1 + t * dx), y - (y1 + t * dy));
}

const roundedSegment = (x, y, x1, y1, x2, y2, halfWidth) =>
  segmentDistance(x, y, x1, y1, x2, y2) <= halfWidth;

/**
 * Returns true when the sample point falls on the black mark.
 *
 * The mark is built up in layers: bells and body in ink, the clock face
 * punched back out in yellow, then the hands drawn in ink on top.
 */
function isInk(x, y) {
  const bodyX = 0.5;
  const bodyY = 0.545;
  const bodyR = 0.305;

  // Twin bells, tucked behind the body.
  if (circle(x, y, 0.268, 0.243, 0.112)) return true;
  if (circle(x, y, 0.732, 0.243, 0.112)) return true;

  // Feet.
  if (roundedSegment(x, y, 0.318, 0.845, 0.268, 0.905, 0.036)) return true;
  if (roundedSegment(x, y, 0.682, 0.845, 0.732, 0.905, 0.036)) return true;

  // Hammer between the bells.
  if (roundedSegment(x, y, 0.5, 0.2, 0.5, 0.26, 0.032)) return true;

  if (circle(x, y, bodyX, bodyY, bodyR)) {
    // Punch out the face so the body reads as a thick ring.
    const faceR = 0.243;
    if (circle(x, y, bodyX, bodyY, faceR)) {
      // Hands: roughly seven o'clock, the hour this app exists for.
      const hourEnd = [bodyX - 0.088, bodyY - 0.088];
      const minuteEnd = [bodyX + 0.005, bodyY - 0.163];
      if (roundedSegment(x, y, bodyX, bodyY, hourEnd[0], hourEnd[1], 0.026)) return true;
      if (roundedSegment(x, y, bodyX, bodyY, minuteEnd[0], minuteEnd[1], 0.021)) return true;
      if (circle(x, y, bodyX, bodyY, 0.036)) return true;

      // Four tick marks at the quarters.
      const ticks = [
        [bodyX, bodyY - 0.196],
        [bodyX, bodyY + 0.196],
        [bodyX - 0.196, bodyY],
        [bodyX + 0.196, bodyY],
      ];
      for (const [tx, ty] of ticks) {
        if (circle(x, y, tx, ty, 0.019)) return true;
      }
      return false;
    }
    return true;
  }

  return false;
}

// ------------------------------------------------------------------ raster

function render(size) {
  const pixels = Buffer.alloc(size * size * 3);
  const step = 1 / (size * SS);

  for (let py = 0; py < size; py++) {
    for (let px = 0; px < size; px++) {
      let hits = 0;
      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          const x = (px * SS + sx + 0.5) * step;
          const y = (py * SS + sy + 0.5) * step;
          if (isInk(x, y)) hits++;
        }
      }
      const coverage = hits / (SS * SS);
      const offset = (py * size + px) * 3;
      for (let c = 0; c < 3; c++) {
        pixels[offset + c] = Math.round(YELLOW[c] * (1 - coverage) + INK[c] * coverage);
      }
    }
  }

  return pixels;
}

// -------------------------------------------------------------- PNG writing

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([length, typeBuf, data, crc]);
}

function encodePNG(size, rgb) {
  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 2;  // colour type: truecolour RGB (no alpha — iOS icons must be opaque)
  ihdr[10] = 0; // compression
  ihdr[11] = 0; // filter
  ihdr[12] = 0; // interlace

  // One filter byte (0 = None) per scanline.
  const raw = Buffer.alloc(size * (size * 3 + 1));
  for (let y = 0; y < size; y++) {
    const rowStart = y * (size * 3 + 1);
    raw[rowStart] = 0;
    rgb.copy(raw, rowStart + 1, y * size * 3, (y + 1) * size * 3);
  }

  return Buffer.concat([
    signature,
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// --------------------------------------------------------------------- main

fs.mkdirSync(OUT_DIR, { recursive: true });

const png = encodePNG(SIZE, render(SIZE));
fs.writeFileSync(path.join(OUT_DIR, 'AppIcon.png'), png);

// Xcode 14+ accepts a single 1024pt universal icon and derives every other
// size from it.
const contents = {
  images: [
    { filename: 'AppIcon.png', idiom: 'universal', platform: 'ios', size: '1024x1024' },
  ],
  info: { author: 'xcode', version: 1 },
};
fs.writeFileSync(path.join(OUT_DIR, 'Contents.json'), JSON.stringify(contents, null, 2));

console.log(`Icon written: ${path.join(OUT_DIR, 'AppIcon.png')} (${(png.length / 1024).toFixed(1)} KB)`);
