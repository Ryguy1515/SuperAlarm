#!/usr/bin/env node
/**
 * Validates every generated WAV: header sanity, duration under the 30 s
 * UNNotificationSound ceiling, seam continuity at the loop point, and that the
 * file is not silent or clipped into distortion.
 */
'use strict';

const fs = require('fs');
const path = require('path');

const DIR = path.join(__dirname, '..', 'SuperAlarm', 'Resources', 'Sounds');
const files = fs.readdirSync(DIR).filter((f) => f.endsWith('.wav')).sort();

let failures = 0;
const fail = (f, msg) => {
  failures++;
  console.log(`  FAIL  ${f}: ${msg}`);
};

for (const f of files) {
  const buf = fs.readFileSync(path.join(DIR, f));

  if (buf.toString('ascii', 0, 4) !== 'RIFF') { fail(f, 'missing RIFF'); continue; }
  if (buf.toString('ascii', 8, 12) !== 'WAVE') { fail(f, 'missing WAVE'); continue; }
  if (buf.toString('ascii', 12, 16) !== 'fmt ') { fail(f, 'missing fmt chunk'); continue; }

  const audioFormat = buf.readUInt16LE(20);
  const channels = buf.readUInt16LE(22);
  const sampleRate = buf.readUInt32LE(24);
  const bits = buf.readUInt16LE(34);
  const dataSize = buf.readUInt32LE(40);

  if (audioFormat !== 1) fail(f, `format ${audioFormat} is not linear PCM`);
  if (channels !== 1) fail(f, `${channels} channels, expected mono`);
  if (bits !== 16) fail(f, `${bits}-bit, expected 16`);
  if (buf.toString('ascii', 36, 40) !== 'data') fail(f, 'missing data chunk');
  if (44 + dataSize !== buf.length) fail(f, `data size ${dataSize} != file length ${buf.length - 44}`);

  const nSamples = dataSize / 2;
  const duration = nSamples / sampleRate;

  // UNNotificationSound refuses anything 30 s or longer.
  if (duration >= 30) fail(f, `duration ${duration.toFixed(3)}s exceeds the 30s notification limit`);

  // Measure level and detect hard clipping.
  let peak = 0;
  let sumSq = 0;
  let clipped = 0;
  for (let i = 0; i < nSamples; i++) {
    const v = buf.readInt16LE(44 + i * 2) / 32768;
    const a = Math.abs(v);
    if (a > peak) peak = a;
    if (a >= 0.9999) clipped++;
    sumSq += v * v;
  }
  const rms = Math.sqrt(sumSq / nSamples);

  // Ambient bedtime loops are deliberately mixed quieter than alarm tones.
  const SLEEP = ['ocean_wave.wav', 'campfire.wav', 'rainy_thunder.wav', 'forest_crickets.wav', 'light_rain.wav'];
  const isSleep = SLEEP.includes(f);

  if (f !== 'keepalive.wav') {
    if (rms < 0.005) fail(f, `RMS ${rms.toFixed(5)} — effectively silent`);
    if (!isSleep && peak < 0.5) fail(f, `peak ${peak.toFixed(3)} — too quiet for an alarm`);
    if (isSleep && peak < 0.3) fail(f, `peak ${peak.toFixed(3)} — too quiet even for ambience`);
    if (clipped / nSamples > 0.02) fail(f, `${((clipped / nSamples) * 100).toFixed(1)}% of samples clipped`);

    // Loop seam: the last sample and the first should be close to each other,
    // otherwise a repeating AVAudioPlayer produces an audible click.
    const first = buf.readInt16LE(44) / 32768;
    const last = buf.readInt16LE(44 + (nSamples - 1) * 2) / 32768;
    if (Math.abs(first - last) > 0.05) fail(f, `loop seam discontinuity ${Math.abs(first - last).toFixed(3)}`);
  }

  const dbfs = rms > 0 ? (20 * Math.log10(rms)).toFixed(1) : '-inf';
  console.log(
    `  ok    ${f.padEnd(26)} ${duration.toFixed(2)}s  ${sampleRate}Hz  peak ${peak.toFixed(2)}  RMS ${dbfs} dBFS`
  );
}

console.log(`\n${files.length} files checked, ${failures} failure(s).`);
process.exit(failures ? 1 : 0);
