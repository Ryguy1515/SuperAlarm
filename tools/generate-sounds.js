#!/usr/bin/env node
/**
 * SuperAlarm — alarm tone generator.
 *
 * Synthesises the entire built-in tone library from scratch so that every sound
 * shipped in the app is original and royalty free. Output is 16-bit mono PCM
 * WAV, 28.000 s long, which keeps every file under the 30 s ceiling that
 * UNNotificationSound imposes while still dividing evenly into the pattern
 * cycles below so each tone loops seamlessly under AVAudioPlayer.
 *
 *   node tools/generate-sounds.js
 *
 * Also emits SoundCatalog.generated.swift so the Swift side can never drift
 * out of sync with what is actually on disk.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const SR = 32000;              // sample rate
const DUR = 28.0;              // seconds — divisible by 0.5/1/2/3.5/4/7
const N = Math.round(SR * DUR);
const TAU = Math.PI * 2;

const OUT_SOUNDS = path.join(__dirname, '..', 'SuperAlarm', 'Resources', 'Sounds');
const OUT_SWIFT = path.join(__dirname, '..', 'SuperAlarm', 'Audio', 'SoundCatalog.generated.swift');

// ---------------------------------------------------------------- primitives

const sine = (f, t) => Math.sin(TAU * f * t);
const saw = (f, t) => 2 * ((f * t) % 1) - 1;
const tri = (f, t) => 2 * Math.abs(2 * ((f * t) % 1) - 1) - 1;
const square = (f, t, duty = 0.5) => (((f * t) % 1) < duty ? 1 : -1);

/** Deterministic PRNG so repeated runs produce byte-identical files. */
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let x = a;
    x = Math.imul(x ^ (x >>> 15), 1 | x);
    x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x;
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
}

/** Percussive envelope: fast attack, exponential decay. */
const hit = (u, attack, decay) => {
  if (u < 0) return 0;
  if (u < attack) return u / attack;
  return Math.exp(-(u - attack) / decay);
};

/** Smooth 0..1..0 window over [0,len]. */
const bump = (u, len) => (u < 0 || u > len ? 0 : 0.5 - 0.5 * Math.cos(TAU * (u / len)));

/** Gate with short raised-cosine edges to avoid clicks. */
const gate = (u, len, edge = 0.004) => {
  if (u < 0 || u > len) return 0;
  if (u < edge) return 0.5 - 0.5 * Math.cos(Math.PI * (u / edge));
  if (u > len - edge) return 0.5 - 0.5 * Math.cos(Math.PI * ((len - u) / edge));
  return 1;
};

/** Two-operator FM voice — the workhorse for bells and metallic tones. */
const fm = (t, carrier, ratio, index, u, attack, decay) => {
  const e = hit(u, attack, decay);
  return e * Math.sin(TAU * carrier * t + index * e * Math.sin(TAU * carrier * ratio * t));
};

/** Stateful one-pole low-pass. */
function lowpass(cut) {
  const a = Math.exp((-TAU * cut) / SR);
  let z = 0;
  return (x) => (z = x * (1 - a) + z * a);
}

/** Stateful one-pole high-pass. */
function highpass(cut) {
  const a = Math.exp((-TAU * cut) / SR);
  let z = 0;
  let prev = 0;
  return (x) => {
    z = x * (1 - a) + z * a;
    prev = x - z;
    return prev;
  };
}

/** Resonant band emphasis built from two cascaded state-variable stages. */
function bandpass(freq, q) {
  let lp = 0;
  let bp = 0;
  const f = 2 * Math.sin((Math.PI * Math.min(freq, SR / 2.2)) / SR);
  const damp = 1 / q;
  return (x) => {
    const hp = x - lp - damp * bp;
    bp += f * hp;
    lp += f * bp;
    return bp;
  };
}

// ------------------------------------------------------------------- library
//
// Each entry renders one cycle-locked tone. `cycle` must divide DUR exactly so
// the file loops without a seam. `render(t, c, rnd, s)` receives absolute time,
// time within the current cycle, the tone's PRNG and a scratch state object.

const TONES = [
  // ============================================================ EXTRA LOUD ==
  {
    id: 'air_raid',
    name: 'Air Raid',
    category: 'noisy',
    cycle: 7,
    drive: 2.4,
    render: (t, c) => {
      // Classic mechanical siren: pitch sweeps up over 3.5 s, down over 3.5 s.
      const half = 3.5;
      const up = c < half ? c / half : 1 - (c - half) / half;
      const f = 240 + 480 * Math.pow(up, 1.3);
      // Rotor chopping gives the siren its raw, ragged edge.
      const chop = 0.72 + 0.28 * Math.sin(TAU * 11 * t);
      const body = saw(f, t) * 0.55 + square(f * 0.5, t, 0.42) * 0.3 + sine(f * 2, t) * 0.15;
      return body * chop * (0.55 + 0.45 * up);
    },
  },
  {
    id: 'police_siren',
    name: 'Police Siren',
    category: 'noisy',
    cycle: 1,
    drive: 2.6,
    render: (t, c) => {
      // Fast two-tone yelp, 1 s per full sweep.
      const u = c < 0.5 ? c / 0.5 : 1 - (c - 0.5) / 0.5;
      const f = 700 + 700 * u;
      return square(f, t, 0.5) * 0.5 + saw(f * 1.5, t) * 0.3 + sine(f, t) * 0.2;
    },
  },
  {
    id: 'fire_alarm',
    name: 'Fire Alarm',
    category: 'noisy',
    cycle: 4,
    drive: 3.0,
    render: (t, c) => {
      // ISO 8201 "T3" temporal pattern: 3 × (0.5 s on / 0.5 s off), 1.5 s pause.
      let g = 0;
      for (let k = 0; k < 3; k++) g += gate(c - k, 0.5, 0.006);
      const f = 3100;
      return g * (square(f, t, 0.5) * 0.6 + sine(f * 0.5, t) * 0.25 + square(f * 1.5, t) * 0.15);
    },
  },
  {
    id: 'klaxon',
    name: 'Klaxon',
    category: 'noisy',
    cycle: 2,
    drive: 2.8,
    render: (t, c) => {
      // Harsh diaphragm horn — two blasts per cycle.
      const g = gate(c, 0.62, 0.01) + gate(c - 1, 0.62, 0.01);
      const f = 392;
      const buzz = saw(f, t) * 0.5 + saw(f * 1.005, t) * 0.3 + square(f * 2, t, 0.35) * 0.2;
      return g * buzz * (0.85 + 0.15 * Math.sin(TAU * 34 * t));
    },
  },
  {
    id: 'emergency_broadcast',
    name: 'Emergency Broadcast',
    category: 'noisy',
    cycle: 4,
    drive: 2.0,
    render: (t, c) => {
      // Attention-signal style dual tone, 853 Hz + 960 Hz, gated.
      const g = gate(c, 2.4, 0.01);
      return g * (sine(853, t) * 0.5 + sine(960, t) * 0.5);
    },
  },
  {
    id: 'nuclear_alert',
    name: 'Nuclear Alert',
    category: 'noisy',
    cycle: 14,
    drive: 2.6,
    render: (t, c) => {
      // Very slow, dread-inducing rise and fall.
      const half = 7;
      const up = c < half ? c / half : 1 - (c - half) / half;
      const f = 140 + 320 * Math.pow(up, 1.6);
      const chop = 0.7 + 0.3 * Math.sin(TAU * 7 * t);
      return (saw(f, t) * 0.5 + saw(f * 0.5, t) * 0.35 + sine(f * 3, t) * 0.15) * chop;
    },
  },
  {
    id: 'red_alert',
    name: 'Red Alert',
    category: 'noisy',
    cycle: 2,
    drive: 2.2,
    render: (t, c) => {
      // Sweeping alarm klaxon that falls fast then repeats.
      const u = Math.min(c / 1.2, 1);
      const f = 1200 * Math.pow(0.35, u);
      const g = gate(c, 1.2, 0.008);
      return g * (square(f, t, 0.45) * 0.5 + saw(f * 2, t) * 0.25 + sine(f, t) * 0.25);
    },
  },
  {
    id: 'foghorn',
    name: 'Foghorn',
    category: 'noisy',
    cycle: 7,
    drive: 2.2,
    render: (t, c, rnd, s) => {
      // Brutally low blast — carries through walls and pillows alike.
      if (!s.lp) s.lp = lowpass(900);
      const g = gate(c, 2.6, 0.05) + gate(c - 3.5, 1.4, 0.05);
      const f = 82;
      const body =
        saw(f, t) * 0.45 + saw(f * 1.003, t) * 0.25 + square(f * 2, t, 0.4) * 0.2 + sine(f * 0.5, t) * 0.1;
      return s.lp(g * body);
    },
  },
  {
    id: 'battle_stations',
    name: 'Battle Stations',
    category: 'noisy',
    cycle: 1,
    drive: 3.2,
    render: (t, c) => {
      // Rapid-fire metallic alarm bell — maximum urgency per second.
      const g = gate(c, 0.16, 0.004) + gate(c - 0.25, 0.16, 0.004) + gate(c - 0.5, 0.16, 0.004);
      const f = 1760;
      return g * (square(f, t, 0.3) * 0.45 + square(f * 1.51, t, 0.3) * 0.3 + saw(f * 0.5, t) * 0.25);
    },
  },

  // =============================================================== CLASSIC ==
  {
    id: 'radar',
    name: 'Radar',
    category: 'bright',
    cycle: 2,
    drive: 1.5,
    render: (t, c) => {
      // Four-pulse ascending sweep, familiar and insistent.
      let v = 0;
      for (let k = 0; k < 4; k++) {
        const u = c - k * 0.22;
        if (u >= 0 && u < 0.2) {
          const f = 660 * Math.pow(2, k / 12);
          v += hit(u, 0.006, 0.05) * (sine(f, t) * 0.6 + sine(f * 2, t) * 0.25 + sine(f * 3, t) * 0.15);
        }
      }
      return v;
    },
  },
  {
    id: 'beacon',
    name: 'Beacon',
    category: 'bright',
    cycle: 2,
    drive: 1.6,
    render: (t, c) => {
      // Rising three-note arpeggio with a bell tail.
      const notes = [523.25, 659.25, 783.99];
      let v = 0;
      notes.forEach((f, k) => {
        v += fm(t, f, 1.41, 2.2, c - k * 0.18, 0.004, 0.22) * 0.6;
      });
      v += fm(t, 1046.5, 2.01, 1.4, c - 0.54, 0.004, 0.6) * 0.5;
      return v;
    },
  },
  {
    id: 'chimes',
    name: 'Chimes',
    category: 'bright',
    cycle: 3.5,
    drive: 1.4,
    render: (t, c) => {
      // Westminster-flavoured bell sequence (original phrase).
      const seq = [
        [0.0, 659.25],
        [0.42, 587.33],
        [0.84, 523.25],
        [1.26, 392.0],
        [2.0, 523.25],
      ];
      let v = 0;
      for (const [at, f] of seq) v += fm(t, f, 2.76, 3.0, c - at, 0.003, 0.7) * 0.55;
      return v;
    },
  },
  {
    id: 'bulletin',
    name: 'Bulletin',
    category: 'energetic',
    cycle: 2,
    drive: 1.8,
    render: (t, c) => {
      // Urgent newsroom-style marimba pattern.
      const seq = [0.0, 0.14, 0.28, 0.56, 0.7, 0.84];
      const fs = [880, 1108.7, 1318.5, 880, 1108.7, 1318.5];
      let v = 0;
      seq.forEach((at, k) => {
        v += fm(t, fs[k], 3.0, 1.6, c - at, 0.003, 0.09) * 0.7;
      });
      return v;
    },
  },
  {
    id: 'waves',
    name: 'Waves',
    category: 'bright',
    cycle: 3.5,
    drive: 1.5,
    render: (t, c) => {
      // Swelling harmonic pad that rises to a peak then recedes.
      const e = bump(c, 3.5);
      const f = 261.63;
      return (
        e *
        (sine(f, t) * 0.35 + sine(f * 1.5, t) * 0.25 + sine(f * 2, t) * 0.2 + sine(f * 3, t) * 0.12 + sine(f * 4, t) * 0.08)
      );
    },
  },
  {
    id: 'ascending',
    name: 'Ascent',
    category: 'energetic',
    cycle: 3.5,
    drive: 1.7,
    render: (t, c) => {
      // Ladder of tones climbing an octave and a half — hard to sleep through.
      const step = 0.2;
      const k = Math.floor(c / step);
      const u = c - k * step;
      if (k > 15) return 0;
      const f = 392 * Math.pow(2, k / 12);
      return hit(u, 0.005, 0.06) * (sine(f, t) * 0.55 + square(f, t, 0.3) * 0.2 + sine(f * 2, t) * 0.25);
    },
  },

  // =============================================================== DIGITAL ==
  {
    id: 'digital_beep',
    name: '3000',
    category: 'energetic',
    cycle: 2,
    drive: 2.4,
    render: (t, c) => {
      // The archetypal bedside clock: four sharp beeps, pause, repeat.
      let g = 0;
      for (let k = 0; k < 4; k++) g += gate(c - k * 0.16, 0.09, 0.003);
      return g * (square(2093, t, 0.5) * 0.6 + sine(4186, t) * 0.2 + square(1046.5, t, 0.5) * 0.2);
    },
  },
  {
    id: 'retro_arcade',
    name: 'Retro Arcade',
    category: 'energetic',
    cycle: 2,
    drive: 2.0,
    render: (t, c) => {
      // 8-bit arpeggio with a pitch-bent tail.
      const step = 0.1;
      const k = Math.floor(c / step);
      const u = c - k * step;
      const pattern = [0, 4, 7, 12, 7, 4, 0, 7, 12, 16, 12, 7, 0, 12, 7, 4, 0, 4, 7, 12];
      if (k >= pattern.length) return 0;
      const f = 329.63 * Math.pow(2, pattern[k] / 12);
      return gate(u, 0.085, 0.003) * (square(f, t, 0.25) * 0.6 + square(f * 2, t, 0.5) * 0.25 + tri(f, t) * 0.15);
    },
  },
  {
    id: 'pulse',
    name: 'Momentum',
    category: 'energetic',
    cycle: 1,
    drive: 2.2,
    render: (t, c) => {
      // Machine-like double thump with a bright edge.
      const g = gate(c, 0.12, 0.004) + gate(c - 0.2, 0.12, 0.004);
      const f = 523.25;
      return g * (saw(f, t) * 0.45 + square(f * 3, t, 0.2) * 0.3 + sine(f * 0.5, t) * 0.25);
    },
  },
  {
    id: 'blip_ladder',
    name: 'City Rush',
    category: 'energetic',
    cycle: 1,
    drive: 2.0,
    render: (t, c) => {
      // Six blips climbing quickly — reads as "something needs you now".
      const step = 0.09;
      const k = Math.floor(c / step);
      if (k > 5) return 0;
      const u = c - k * step;
      const f = 880 * Math.pow(2, k / 7);
      return hit(u, 0.002, 0.022) * (square(f, t, 0.4) * 0.55 + sine(f * 2, t) * 0.45);
    },
  },
  {
    id: 'data_alert',
    name: 'Motion',
    category: 'energetic',
    cycle: 2,
    drive: 2.0,
    render: (t, c, rnd, s) => {
      // Warbling data-link tone: two interleaved frequencies plus noise grit.
      if (!s.bp) s.bp = bandpass(2200, 3);
      const g = gate(c, 1.1, 0.01);
      const warble = Math.floor(c * 24) % 2 === 0 ? 1600 : 2400;
      const grit = s.bp((rnd() * 2 - 1)) * 0.18;
      return g * (square(warble, t, 0.5) * 0.55 + sine(warble * 2, t) * 0.2 + grit);
    },
  },

  // ================================================================ GENTLE ==
  {
    id: 'sunrise',
    name: 'Sunrise',
    category: 'calm',
    cycle: 14,
    drive: 1.2,
    render: (t, c) => {
      // Slow warm pad that blooms — pairs with the gradual-volume setting.
      const e = bump(c, 14);
      const f = 220;
      const detune = 1 + 0.002 * Math.sin(TAU * 0.15 * t);
      return (
        e *
        (sine(f, t) * 0.3 +
          sine(f * detune * 1.5, t) * 0.24 +
          sine(f * 2, t) * 0.2 +
          sine(f * 2.5, t) * 0.14 +
          sine(f * 4, t) * 0.12)
      );
    },
  },
  {
    id: 'music_box',
    name: 'Music Box',
    category: 'calm',
    cycle: 7,
    drive: 1.3,
    render: (t, c) => {
      // Delicate celesta melody, one phrase per cycle.
      const seq = [
        [0.0, 1046.5], [0.4, 1318.5], [0.8, 1567.98], [1.2, 1318.5],
        [1.6, 1046.5], [2.0, 1174.66], [2.4, 1318.5], [3.2, 1046.5],
        [3.9, 783.99], [4.3, 1046.5], [4.7, 1318.5], [5.4, 1046.5],
      ];
      let v = 0;
      for (const [at, f] of seq) v += fm(t, f, 3.5, 1.1, c - at, 0.002, 0.32) * 0.5;
      return v;
    },
  },
  {
    id: 'soft_bells',
    name: 'Soft Bells',
    category: 'calm',
    cycle: 3.5,
    drive: 1.2,
    render: (t, c) => {
      // Muted struck bells with long, soft tails.
      let v = 0;
      v += fm(t, 587.33, 1.98, 1.2, c, 0.01, 1.1) * 0.5;
      v += fm(t, 880, 1.98, 0.9, c - 0.7, 0.01, 1.0) * 0.4;
      v += fm(t, 440, 1.98, 0.8, c - 1.75, 0.012, 1.4) * 0.42;
      return v;
    },
  },
  {
    id: 'harp',
    name: 'Harp',
    category: 'calm',
    cycle: 3.5,
    drive: 1.3,
    render: (t, c) => {
      // Rolled major-ninth chord, ascending then answering.
      const notes = [261.63, 329.63, 392.0, 493.88, 587.33, 659.25, 783.99];
      let v = 0;
      notes.forEach((f, k) => {
        v += fm(t, f, 1.0, 0.6, c - k * 0.085, 0.004, 0.75) * 0.34;
        v += fm(t, f * 2, 1.0, 0.5, c - 1.9 - k * 0.07, 0.004, 0.5) * 0.2;
      });
      return v;
    },
  },
  {
    id: 'morning_dew',
    name: 'Morning Dew',
    category: 'calm',
    cycle: 3.5,
    drive: 1.2,
    render: (t, c) => {
      // Sparse droplets over a quiet sustained fifth.
      const drops = [0.0, 0.55, 1.1, 1.5, 2.2, 2.85];
      const fs = [1567.98, 1318.5, 1975.53, 1046.5, 1318.5, 1567.98];
      let v = 0;
      drops.forEach((at, k) => {
        v += fm(t, fs[k], 4.1, 0.8, c - at, 0.002, 0.2) * 0.42;
      });
      v += (sine(261.63, t) * 0.1 + sine(392.0, t) * 0.08) * bump(c, 3.5);
      return v;
    },
  },

  // ================================================================ NATURE ==
  {
    id: 'rooster',
    name: 'Rooster',
    category: 'bright',
    cycle: 3.5,
    drive: 1.9,
    render: (t, c, rnd, s) => {
      // Stylised cock-a-doodle-doo built from a formant-swept buzz.
      if (!s.bp1) {
        s.bp1 = bandpass(900, 4);
        s.bp2 = bandpass(2100, 5);
      }
      // Four syllables with distinct pitch contours.
      const syl = [
        { at: 0.0, len: 0.28, f0: 620, f1: 760 },
        { at: 0.32, len: 0.22, f0: 780, f1: 700 },
        { at: 0.58, len: 0.5, f0: 900, f1: 1150 },
        { at: 1.14, len: 0.62, f0: 820, f1: 520 },
      ];
      let src = 0;
      let env = 0;
      for (const sy of syl) {
        const u = c - sy.at;
        if (u < 0 || u > sy.len) continue;
        const p = u / sy.len;
        const f = sy.f0 + (sy.f1 - sy.f0) * p;
        const e = gate(u, sy.len, 0.03);
        env += e;
        // Rough glottal buzz: saw plus jitter.
        src += e * (saw(f, t) * 0.7 + saw(f * 2.01, t) * 0.2 + (rnd() * 2 - 1) * 0.1);
      }
      if (env <= 0) return 0;
      return s.bp1(src) * 0.6 + s.bp2(src) * 0.45;
    },
  },
  {
    id: 'birds',
    name: 'Birdsong',
    category: 'bright',
    cycle: 7,
    drive: 1.5,
    render: (t, c, rnd, s) => {
      // Cluster of chirps: fast FM sweeps in the 2–5 kHz range.
      if (!s.hp) s.hp = highpass(1200);
      const chirps = [
        [0.0, 0.09, 3200, 4400], [0.13, 0.07, 4200, 3000], [0.3, 0.11, 2600, 3900],
        [1.2, 0.08, 3800, 4800], [1.32, 0.06, 4600, 3400], [1.5, 0.1, 3000, 4200],
        [2.6, 0.12, 2400, 3600], [2.78, 0.07, 3600, 4600], [3.0, 0.09, 4000, 2800],
        [4.2, 0.08, 3400, 4500], [4.35, 0.1, 4400, 3200], [4.6, 0.07, 2800, 3800],
        [5.6, 0.11, 3100, 4300], [5.8, 0.08, 4500, 3300],
      ];
      let v = 0;
      for (const [at, len, fa, fb] of chirps) {
        const u = c - at;
        if (u < 0 || u > len) continue;
        const p = u / len;
        const f = fa + (fb - fa) * p;
        const e = Math.sin(Math.PI * p);
        v += e * (sine(f, t) * 0.7 + sine(f * 2, t) * 0.15 + (rnd() * 2 - 1) * 0.05);
      }
      return s.hp(v);
    },
  },
  {
    id: 'ocean',
    name: 'Tide',
    category: 'calm',
    cycle: 7,
    drive: 1.3,
    render: (t, c, rnd, s) => {
      // Filtered noise swells, two waves per cycle.
      if (!s.lp) {
        s.lp = lowpass(1400);
        s.lp2 = lowpass(700);
        s.hp = highpass(120);
      }
      const e = Math.pow(bump(c, 3.5), 1.7) + Math.pow(bump(c - 3.5, 3.5), 1.7);
      const n = rnd() * 2 - 1;
      const body = s.lp(n) * 0.7 + s.lp2(n) * 0.5;
      return s.hp(body) * e * 1.6;
    },
  },

  // ================================================== ADDITIONAL BRIGHT ==
  {
    id: 'sunbeam',
    name: 'Sunbeam',
    category: 'bright',
    cycle: 2,
    drive: 1.6,
    render: (t, c) => {
      // Bright struck bells over a major triad, cheerful but insistent.
      const notes = [1046.5, 1318.5, 1567.98, 2093];
      let v = 0;
      notes.forEach((f, k) => {
        v += fm(t, f, 2.0, 1.5, c - k * 0.12, 0.003, 0.28) * 0.5;
      });
      v += fm(t, 783.99, 2.0, 1.2, c - 1.0, 0.003, 0.45) * 0.45;
      return v;
    },
  },
  {
    id: 'skyline',
    name: 'Skyline',
    category: 'bright',
    cycle: 3.5,
    drive: 1.7,
    render: (t, c) => {
      // Wide ascending arpeggio that keeps climbing — feels like sunrise.
      const step = 0.11;
      const k = Math.floor(c / step);
      const pattern = [0, 4, 7, 11, 12, 16, 19, 16, 12, 11, 7, 4, 0, 7, 12, 19];
      if (k >= pattern.length) return 0;
      const u = c - k * step;
      const f = 523.25 * Math.pow(2, pattern[k] / 12);
      return hit(u, 0.004, 0.13) * (sine(f, t) * 0.5 + tri(f, t) * 0.3 + sine(f * 2, t) * 0.2);
    },
  },

  // =============================================== ADDITIONAL ENERGETIC ==
  {
    id: 'overdrive',
    name: 'Overdrive',
    category: 'energetic',
    cycle: 2,
    drive: 2.6,
    render: (t, c, rnd, s) => {
      // Driving four-on-the-floor bass pulse with a bright stab on the offbeat.
      if (!s.lp) s.lp = lowpass(2600);
      const beat = 0.25;
      const k = Math.floor(c / beat);
      const u = c - k * beat;
      const bass = hit(u, 0.002, 0.09) * (saw(65.41, t) * 0.6 + sine(65.41 * 2, t) * 0.4);
      const stab = k % 2 === 1 ? hit(u, 0.002, 0.05) * square(659.25, t, 0.3) * 0.5 : 0;
      return s.lp(bass + stab);
    },
  },
  {
    id: 'marathon',
    name: 'Marathon',
    category: 'energetic',
    cycle: 2,
    drive: 2.2,
    render: (t, c) => {
      // Relentless sixteenth-note arpeggio — impossible to drift off through.
      const step = 0.0625;
      const k = Math.floor(c / step);
      const pattern = [0, 7, 12, 7, 3, 10, 15, 10, 5, 12, 17, 12, 0, 7, 12, 19];
      const u = c - k * step;
      const f = 440 * Math.pow(2, pattern[k % pattern.length] / 12);
      return hit(u, 0.002, 0.035) * (square(f, t, 0.35) * 0.5 + sine(f, t) * 0.3 + saw(f * 0.5, t) * 0.2);
    },
  },
];

// ------------------------------------------------------------ sleep sounds
//
// Ambient loops for the bedtime screen. Same cycle-locked construction so they
// loop indefinitely without a seam, but mixed far quieter than the alarm tones.

const SLEEP_SOUNDS = [
  {
    id: 'ocean_wave',
    name: 'Ocean wave',
    symbol: 'water.waves',
    drive: 1.0,
    peak: 0.55,
    cycle: 14,
    render: (t, c, rnd, s) => {
      if (!s.lp) {
        s.lp = lowpass(1100);
        s.lp2 = lowpass(480);
        s.hp = highpass(90);
      }
      // Two long swells per cycle, with the second smaller than the first.
      const e = Math.pow(bump(c, 8), 1.8) + 0.6 * Math.pow(bump(c - 8, 6), 1.8);
      const n = rnd() * 2 - 1;
      return s.hp(s.lp(n) * 0.65 + s.lp2(n) * 0.55) * e * 1.7;
    },
  },
  {
    id: 'campfire',
    name: 'Campfire',
    symbol: 'flame',
    drive: 1.0,
    peak: 0.5,
    cycle: 14,
    render: (t, c, rnd, s) => {
      if (!s.lp) {
        s.lp = lowpass(320);
        s.bp = bandpass(2400, 2.5);
        s.crackles = [];
        // Pre-schedule crackles deterministically across the whole cycle.
        let at = 0;
        // Stop short of the cycle end so no crackle is cut off at the wrap.
        while (at < 13.9) {
          at += 0.03 + rnd() * 0.42;
          if (at < 13.9) s.crackles.push({ at, amp: 0.25 + rnd() * 0.75, dec: 0.004 + rnd() * 0.02 });
        }
      }
      // Low roar of the fire bed.
      const roar = s.lp(rnd() * 2 - 1) * 1.9;
      // Sharp pops layered on top.
      let pop = 0;
      for (const cr of s.crackles) {
        const u = c - cr.at;
        if (u >= 0 && u < 0.09) pop += cr.amp * Math.exp(-u / cr.dec);
      }
      return roar + s.bp((rnd() * 2 - 1) * pop) * 2.2;
    },
  },
  {
    id: 'rainy_thunder',
    name: 'Rainy thunder',
    symbol: 'cloud.bolt.rain',
    drive: 1.0,
    peak: 0.6,
    cycle: 28,
    render: (t, c, rnd, s) => {
      if (!s.hp) {
        s.hp = highpass(700);
        s.lp = lowpass(5200);
        s.rumbleLP = lowpass(110);
      }
      const n = rnd() * 2 - 1;
      const rain = s.hp(s.lp(n)) * 0.75;
      // Three distant thunder rolls per cycle.
      let thunder = 0;
      for (const [at, len, amp] of [[3.5, 4.5, 1.0], [13.0, 5.5, 0.75], [22.0, 4.0, 0.9]]) {
        const u = c - at;
        if (u >= 0 && u < len) {
          const env = Math.pow(Math.sin(Math.PI * (u / len)), 1.6);
          thunder += env * amp;
        }
      }
      return rain + s.rumbleLP(rnd() * 2 - 1) * thunder * 6.0;
    },
  },
  {
    id: 'forest_crickets',
    name: 'Forest crickets',
    symbol: 'leaf',
    drive: 1.0,
    peak: 0.5,
    cycle: 7,
    render: (t, c, rnd, s) => {
      if (!s.bp) {
        s.bp = bandpass(4600, 9);
        s.lp = lowpass(400);
        // A handful of crickets, each with its own phase and pitch.
        s.bugs = [];
        for (let i = 0; i < 5; i++) {
          // Chirp period must divide the 7 s cycle exactly, otherwise the
          // rhythm stutters every time the loop wraps.
          const divisions = 17 + Math.floor(rnd() * 6);
          s.bugs.push({
            phase: rnd() * 7,
            period: 7 / divisions,
            f: 4200 + rnd() * 900,
            amp: 0.4 + rnd() * 0.6,
          });
        }
      }
      let chirp = 0;
      for (const b of s.bugs) {
        // Each chirp is a short burst pulsed at ~28 Hz.
        const u = (c + b.phase) % b.period;
        if (u < 0.11) {
          const env = Math.sin(Math.PI * (u / 0.11));
          const pulse = 0.5 + 0.5 * square(28, t, 0.45);
          chirp += env * pulse * sine(b.f, t) * b.amp;
        }
      }
      const night = s.lp(rnd() * 2 - 1) * 0.55;
      return s.bp(chirp) * 1.4 + night;
    },
  },
  {
    id: 'light_rain',
    name: 'Light rain',
    symbol: 'cloud.rain',
    drive: 1.0,
    peak: 0.55,
    cycle: 14,
    render: (t, c, rnd, s) => {
      if (!s.hp) {
        s.hp = highpass(1100);
        s.lp = lowpass(6500);
        s.drops = [];
        let at = 0;
        while (at < 13.95) {
          at += 0.01 + rnd() * 0.09;
          if (at < 13.95) s.drops.push({ at, f: 1800 + rnd() * 2600, amp: 0.15 + rnd() * 0.35 });
        }
      }
      const hiss = s.hp(s.lp(rnd() * 2 - 1)) * 0.85;
      // Gentle intensity drift so it never sounds like flat static.
      const drift = 0.82 + 0.18 * Math.sin(TAU * (c / 14));
      let drops = 0;
      for (const d of s.drops) {
        const u = c - d.at;
        if (u >= 0 && u < 0.03) drops += d.amp * Math.exp(-u / 0.006) * sine(d.f, t);
      }
      return hiss * drift + drops * 0.5;
    },
  },
];

// -------------------------------------------------------------- WAV writing

function writeWav(filePath, samples) {
  const dataBytes = samples.length * 2;
  const buf = Buffer.alloc(44 + dataBytes);
  buf.write('RIFF', 0, 'ascii');
  buf.writeUInt32LE(36 + dataBytes, 4);
  buf.write('WAVE', 8, 'ascii');
  buf.write('fmt ', 12, 'ascii');
  buf.writeUInt32LE(16, 16);          // PCM chunk size
  buf.writeUInt16LE(1, 20);           // format = PCM
  buf.writeUInt16LE(1, 22);           // channels = mono
  buf.writeUInt32LE(SR, 24);
  buf.writeUInt32LE(SR * 2, 28);      // byte rate
  buf.writeUInt16LE(2, 32);           // block align
  buf.writeUInt16LE(16, 34);          // bits per sample
  buf.write('data', 36, 'ascii');
  buf.writeUInt32LE(dataBytes, 40);
  for (let i = 0; i < samples.length; i++) {
    let v = Math.max(-1, Math.min(1, samples[i]));
    buf.writeInt16LE(Math.round(v * 32767), 44 + i * 2);
  }
  fs.writeFileSync(filePath, buf);
  return buf.length;
}

// ------------------------------------------------------------------- render

function renderTone(tone) {
  const rnd = mulberry32(
    // Stable per-tone seed derived from the id.
    [...tone.id].reduce((h, ch) => (Math.imul(h, 31) + ch.charCodeAt(0)) | 0, 7) >>> 0
  );
  const state = {};
  const buf = new Float64Array(N);

  for (let i = 0; i < N; i++) {
    const t = i / SR;
    const c = t % tone.cycle;
    buf[i] = tone.render(t, c, rnd, state);
  }

  // Drive into a soft saturator. Louder categories get pushed harder, which
  // raises perceived loudness far more than peak normalisation alone.
  const d = tone.drive || 1;
  for (let i = 0; i < N; i++) buf[i] = Math.tanh(buf[i] * d);

  // Peak-normalise. Alarm tones sit just under full scale; ambient sleep
  // sounds get a lower target so they stay restful at the same device volume.
  const target = tone.peak || 0.97;
  let peak = 0;
  for (let i = 0; i < N; i++) peak = Math.max(peak, Math.abs(buf[i]));
  const norm = peak > 1e-9 ? target / peak : 0;
  for (let i = 0; i < N; i++) buf[i] *= norm;

  // A 3 ms fade at the very edges removes any DC step at the loop point
  // without being audible.
  const edge = Math.round(SR * 0.003);
  for (let i = 0; i < edge; i++) {
    const g = i / edge;
    buf[i] *= g;
    buf[N - 1 - i] *= g;
  }

  let sumSq = 0;
  for (let i = 0; i < N; i++) sumSq += buf[i] * buf[i];
  const rms = Math.sqrt(sumSq / N);
  return { buf, rms };
}

// --------------------------------------------------------------------- main

fs.mkdirSync(OUT_SOUNDS, { recursive: true });
fs.mkdirSync(path.dirname(OUT_SWIFT), { recursive: true });

let totalBytes = 0;
const rows = [];

for (const tone of TONES) {
  const { buf, rms } = renderTone(tone);
  const file = path.join(OUT_SOUNDS, `${tone.id}.wav`);
  const bytes = writeWav(file, buf);
  totalBytes += bytes;
  const dbfs = (20 * Math.log10(rms)).toFixed(1);
  rows.push({ ...tone, bytes });
  console.log(
    `  ${tone.id.padEnd(22)} ${tone.category.padEnd(8)} ${(bytes / 1048576).toFixed(2)} MB   RMS ${dbfs} dBFS`
  );
}

console.log('');
for (const sleep of SLEEP_SOUNDS) {
  const { buf, rms } = renderTone(sleep);
  const file = path.join(OUT_SOUNDS, `${sleep.id}.wav`);
  const bytes = writeWav(file, buf);
  totalBytes += bytes;
  const dbfs = (20 * Math.log10(rms)).toFixed(1);
  console.log(
    `  ${sleep.id.padEnd(22)} ${'sleep'.padEnd(8)} ${(bytes / 1048576).toFixed(2)} MB   RMS ${dbfs} dBFS`
  );
}
console.log('');

// Near-silent keep-alive loop used to hold the audio session open in the
// background on iOS versions without AlarmKit. A true digital-silence file can
// let the session be torn down, so this carries a tiny amount of signal.
{
  const keep = new Float64Array(SR * 4);
  const rnd = mulberry32(1337);
  for (let i = 0; i < keep.length; i++) keep[i] = (rnd() * 2 - 1) * 0.00035;
  const bytes = writeWav(path.join(OUT_SOUNDS, 'keepalive.wav'), keep);
  totalBytes += bytes;
  console.log(`  ${'keepalive'.padEnd(22)} ${'system'.padEnd(8)} ${(bytes / 1048576).toFixed(2)} MB`);
}

// ------------------------------------------------------- Swift catalog emit

// Category names, icons and order mirror the shipping sound picker:
// ♪ Bright · Noisy · Energetic · Calm
const CATEGORY_META = {
  bright: { display: 'Bright', symbol: 'music.note', order: 0 },
  noisy: { display: 'Noisy', symbol: 'light.beacon.max.fill', order: 1 },
  energetic: { display: 'Energetic', symbol: 'flame.fill', order: 2 },
  calm: { display: 'Calm', symbol: 'cup.and.saucer.fill', order: 3 },
};

const usedCats = [...new Set(TONES.map((t) => t.category))].sort(
  (a, b) => CATEGORY_META[a].order - CATEGORY_META[b].order
);

const swift = `// Generated by tools/generate-sounds.js — do not edit by hand.
// Run \`node tools/generate-sounds.js\` to regenerate.

import Foundation

public enum SoundCategory: String, CaseIterable, Codable, Sendable, Identifiable {
${usedCats.map((c) => `    case ${c} = "${c}"`).join('\n')}

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
${usedCats.map((c) => `        case .${c}: return "${CATEGORY_META[c].display}"`).join('\n')}
        }
    }

    public var symbolName: String {
        switch self {
${usedCats.map((c) => `        case .${c}: return "${CATEGORY_META[c].symbol}"`).join('\n')}
        }
    }
}

public struct AlarmTone: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let category: SoundCategory
    /// File name including extension. Bundled tones resolve out of the app
    /// bundle; imported ones resolve out of the custom sounds directory.
    public let fileName: String
    /// True for audio the user imported themselves.
    public let isCustom: Bool

    public init(
        id: String,
        name: String,
        category: SoundCategory,
        fileName: String? = nil,
        isCustom: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.fileName = fileName ?? "\\(id).wav"
        self.isCustom = isCustom
    }
}

public enum SoundCatalog {
    /// Duration of every bundled tone, in seconds. Kept under the 30 s limit
    /// that \`UNNotificationSound\` enforces.
    public static let toneDuration: TimeInterval = ${DUR}

    /// Near-silent loop used to hold the audio session alive in the background.
    public static let keepAliveFileName = "keepalive.wav"

    public static let all: [AlarmTone] = [
${TONES.map((t) => `        AlarmTone(id: "${t.id}", name: "${t.name}", category: .${t.category}),`).join('\n')}
    ]

    public static let defaultToneID = "air_raid"

    public static func tone(id: String) -> AlarmTone {
        all.first { $0.id == id } ?? all.first { $0.id == defaultToneID } ?? all[0]
    }

    public static func tones(in category: SoundCategory) -> [AlarmTone] {
        all.filter { $0.category == category }
    }

    /// Backing store for the "Random" entry at the top of each category, which
    /// picks a different tone every time the alarm fires so you never
    /// habituate to one sound.
    public static func randomTone(in category: SoundCategory, excluding excluded: String? = nil) -> AlarmTone {
        let pool = tones(in: category)
        let filtered = pool.filter { $0.id != excluded }
        return (filtered.isEmpty ? pool : filtered).randomElement() ?? all[0]
    }
}

// MARK: - Sleep sounds

public struct SleepSound: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let symbolName: String

    public var fileName: String { "\\(id).wav" }
}

public enum SleepSoundCatalog {
    public static let all: [SleepSound] = [
${SLEEP_SOUNDS.map((s) => `        SleepSound(id: "${s.id}", name: "${s.name}", symbolName: "${s.symbol}"),`).join('\n')}
    ]

    /// Minutes the bedtime player runs before fading out. 0 means "until the
    /// alarm rings".
    public static let durationOptions: [Int] = [5, 10, 15, 30, 45, 60, 90, 0]

    public static func sound(id: String?) -> SleepSound? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}
`;

fs.writeFileSync(OUT_SWIFT, swift, 'utf8');

console.log(`\n${TONES.length} tones + keep-alive written to ${OUT_SOUNDS}`);
console.log(`Total ${(totalBytes / 1048576).toFixed(1)} MB`);
console.log(`Swift catalog written to ${OUT_SWIFT}`);
