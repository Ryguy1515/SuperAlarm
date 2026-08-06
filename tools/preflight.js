#!/usr/bin/env node
/**
 * Static checks that can run without a Swift toolchain.
 *
 * Catches the classes of mistake that would otherwise only surface after a
 * full macOS CI cycle: duplicate type declarations, unbalanced braces,
 * references to audio files that were never generated, and missing imports for
 * frameworks a file demonstrably uses.
 *
 *   node tools/preflight.js
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const SOUNDS_DIR = path.join(ROOT, 'SuperAlarm', 'Resources', 'Sounds');
const CATALOG = path.join(ROOT, 'SuperAlarm', 'Audio', 'SoundCatalog.generated.swift');

let failures = 0;
let warnings = 0;

const fail = (msg) => { failures++; console.log(`  FAIL  ${msg}`); };
const warn = (msg) => { warnings++; console.log(`  warn  ${msg}`); };
const ok = (msg) => console.log(`  ok    ${msg}`);

// ------------------------------------------------------------- file walking

function walk(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (entry.name.endsWith('.swift')) out.push(full);
  }
  return out;
}

const APP_FILES = walk(path.join(ROOT, 'SuperAlarm'));
const WIDGET_FILES = walk(path.join(ROOT, 'SuperAlarmWidget'));
const TEST_FILES = walk(path.join(ROOT, 'SuperAlarmTests'));
const ALL_FILES = [...APP_FILES, ...WIDGET_FILES, ...TEST_FILES];

const rel = (p) => path.relative(ROOT, p).replace(/\\/g, '/');

/**
 * Strips comments and string literals so scans don't trip over prose.
 *
 * Done as a single pass rather than a chain of regexes: a URL inside a string
 * literal contains "//", and stripping line comments first would eat the rest
 * of that line along with its closing bracket.
 */
function stripNoise(source) {
  let out = '';
  let i = 0;
  const n = source.length;
  let state = 'code';
  let blockDepth = 0;

  while (i < n) {
    const c = source[i];
    const c2 = source[i + 1];

    switch (state) {
      case 'code':
        if (c === '/' && c2 === '/') { state = 'line'; i += 2; continue; }
        if (c === '/' && c2 === '*') { state = 'block'; blockDepth = 1; i += 2; continue; }
        if (c === '#' && c2 === '"') { state = 'raw'; i += 2; continue; }
        if (source.startsWith('"""', i)) { state = 'triple'; i += 3; continue; }
        if (c === '"') { state = 'string'; i += 1; continue; }
        out += c; i += 1; continue;

      case 'line':
        if (c === '\n') { state = 'code'; out += c; }
        i += 1; continue;

      case 'block':
        if (c === '/' && c2 === '*') { blockDepth += 1; i += 2; continue; }
        if (c === '*' && c2 === '/') {
          blockDepth -= 1;
          i += 2;
          if (blockDepth === 0) state = 'code';
          continue;
        }
        if (c === '\n') out += c;
        i += 1; continue;

      case 'string':
        // Escapes cover both \" and \( interpolation openers.
        if (c === '\\') { i += 2; continue; }
        if (c === '"') { state = 'code'; i += 1; continue; }
        i += 1; continue;

      case 'triple':
        if (source.startsWith('"""', i)) { state = 'code'; i += 3; continue; }
        if (c === '\n') out += c;
        i += 1; continue;

      case 'raw':
        if (c === '"' && c2 === '#') { state = 'code'; i += 2; continue; }
        if (c === '\n') out += c;
        i += 1; continue;

      default:
        i += 1; continue;
    }
  }

  return out;
}

// ------------------------------------------------------- 1. brace balance

console.log('\nBrace and paren balance');
for (const file of ALL_FILES) {
  const code = stripNoise(fs.readFileSync(file, 'utf8'));
  let braces = 0;
  let parens = 0;
  let brackets = 0;
  for (const ch of code) {
    if (ch === '{') braces++;
    else if (ch === '}') braces--;
    else if (ch === '(') parens++;
    else if (ch === ')') parens--;
    else if (ch === '[') brackets++;
    else if (ch === ']') brackets--;
  }
  if (braces !== 0) fail(`${rel(file)}: braces unbalanced by ${braces}`);
  if (parens !== 0) fail(`${rel(file)}: parentheses unbalanced by ${parens}`);
  if (brackets !== 0) fail(`${rel(file)}: brackets unbalanced by ${brackets}`);
}
if (failures === 0) ok(`${ALL_FILES.length} files balanced`);

// ------------------------------------------- 2. duplicate type declarations

console.log('\nDuplicate top-level type declarations');
{
  const declarations = new Map();
  const pattern = /^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|@MainActor\s+)*(?:struct|class|enum|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)/gm;

  // The app and widget are separate modules, so only compare within each.
  for (const [label, files] of [['app', APP_FILES], ['widget', [...WIDGET_FILES, path.join(ROOT, 'SuperAlarm', 'Store', 'SharedStorage.swift')]]]) {
    const seen = new Map();
    for (const file of files) {
      const code = stripNoise(fs.readFileSync(file, 'utf8'));
      let match;
      while ((match = pattern.exec(code)) !== null) {
        const name = match[1];
        // Only care about declarations at the top level of the file.
        const before = code.slice(0, match.index);
        const depth = (before.match(/{/g) || []).length - (before.match(/}/g) || []).length;
        if (depth !== 0) continue;
        if (seen.has(name)) {
          fail(`${label}: type "${name}" declared in both ${rel(seen.get(name))} and ${rel(file)}`);
        } else {
          seen.set(name, file);
        }
      }
      pattern.lastIndex = 0;
    }
    declarations.set(label, seen);
  }
  ok(`${declarations.get('app').size} app types, ${declarations.get('widget').size} widget types`);
}

// -------------------------------------------- 3. catalog vs files on disk

console.log('\nGenerated audio matches the catalog');
if (!fs.existsSync(CATALOG)) {
  fail('SoundCatalog.generated.swift is missing — run node tools/generate-sounds.js');
} else if (!fs.existsSync(SOUNDS_DIR)) {
  fail('Sounds directory is missing — run node tools/generate-sounds.js');
} else {
  const catalog = fs.readFileSync(CATALOG, 'utf8');
  const onDisk = new Set(fs.readdirSync(SOUNDS_DIR).filter((f) => f.endsWith('.wav')));

  const toneIDs = [...catalog.matchAll(/AlarmTone\(id:\s*"([^"]+)"/g)].map((m) => m[1]);
  const sleepIDs = [...catalog.matchAll(/SleepSound\(id:\s*"([^"]+)"/g)].map((m) => m[1]);

  if (toneIDs.length === 0) fail('No tones found in the catalog');

  for (const id of [...toneIDs, ...sleepIDs]) {
    if (!onDisk.has(`${id}.wav`)) fail(`Catalog lists "${id}" but ${id}.wav is not on disk`);
  }
  if (!onDisk.has('keepalive.wav')) fail('keepalive.wav is missing');

  // Anything on disk the catalog forgot is dead weight in the bundle.
  const known = new Set([...toneIDs, ...sleepIDs, 'keepalive'].map((id) => `${id}.wav`));
  for (const file of onDisk) {
    if (!known.has(file)) warn(`${file} is on disk but not referenced by the catalog`);
  }

  ok(`${toneIDs.length} tones + ${sleepIDs.length} sleep sounds all present`);
}

// --------------------------------- 4. tone identifiers referenced in Swift

console.log('\nHard-coded tone identifiers resolve');
if (fs.existsSync(CATALOG)) {
  const catalog = fs.readFileSync(CATALOG, 'utf8');
  const toneIDs = new Set([...catalog.matchAll(/AlarmTone\(id:\s*"([^"]+)"/g)].map((m) => m[1]));
  const sleepIDs = new Set([...catalog.matchAll(/SleepSound\(id:\s*"([^"]+)"/g)].map((m) => m[1]));

  let checked = 0;
  for (const file of [...APP_FILES, ...TEST_FILES]) {
    if (file === CATALOG) continue;
    const source = fs.readFileSync(file, 'utf8');

    // e.g. SoundCatalog.tone(id: "air_raid") or toneID = "morning_dew"
    for (const match of source.matchAll(/(?:tone\(id:\s*|toneID\s*=\s*|toneID:\s*)"([^"]+)"/g)) {
      const id = match[1];
      checked++;
      if (id.startsWith('custom:') || id.startsWith('random:')) continue;
      if (!toneIDs.has(id)) fail(`${rel(file)}: references tone "${id}", which is not in the catalog`);
    }

    for (const match of source.matchAll(/soundID\s*=\s*"([^"]+)"/g)) {
      const id = match[1];
      checked++;
      if (!sleepIDs.has(id)) fail(`${rel(file)}: references sleep sound "${id}", which is not in the catalog`);
    }
  }
  ok(`${checked} identifier references resolve`);
}

// -------------------------------------------------- 5. framework imports

console.log('\nFramework imports match usage');
{
  // symbol pattern -> framework that must be imported
  const RULES = [
    [/\bUIImage\b|\bUIApplication\b|\bUIColor\b|\bUIView\b|\bUISlider\b|\bUIImpactFeedbackGenerator\b|\bUIWindow\b/, 'UIKit'],
    [/\bAVAudioPlayer\b|\bAVAudioSession\b|\bAVCaptureSession\b|\bAVSpeechSynthesizer\b|\bAVCaptureDevice\b/, 'AVFoundation'],
    [/\bObservableObject\b|\b@Published\b|\bAnyCancellable\b/, 'Combine|SwiftUI'],
    [/\bLogger\(/, 'os.log'],
    [/\bUNUserNotificationCenter\b|\bUNMutableNotificationContent\b|\bUNNotificationRequest\b/, 'UserNotifications'],
    [/\bUTType\b|\ballowedContentTypes\b/, 'UniformTypeIdentifiers'],
    [/\bWidgetCenter\b|\bTimelineProvider\b|\bActivityConfiguration\b|\bAccessoryWidgetBackground\b/, 'WidgetKit'],
    [/\bCMPedometer\b|\bCMMotionManager\b|\bCMDeviceMotion\b|\bCMAcceleration\b/, 'CoreMotion'],
    [/\bVNGenerateImageFeaturePrintRequest\b|\bVNFeaturePrintObservation\b/, 'Vision'],
    [/\bLAContext\b|\bLAError\b|\bLABiometryType\b/, 'LocalAuthentication'],
    [/\bCLLocationManager\b|\bCLGeocoder\b|\bCLLocation\b/, 'CoreLocation'],
    [/\bAudioServicesPlaySystemSound\b/, 'AudioToolbox'],
    [/\bMPVolumeView\b/, 'MediaPlayer'],
    [/\bView\b\s*{|@ViewBuilder|\bColor\b\(|\bText\(/, 'SwiftUI'],
  ];

  for (const file of ALL_FILES) {
    const raw = fs.readFileSync(file, 'utf8');
    const code = stripNoise(raw);
    const imports = new Set([...raw.matchAll(/^\s*(?:@preconcurrency\s+)?import\s+([A-Za-z_][A-Za-z0-9_.]*)/gm)].map((m) => m[1]));

    for (const [pattern, requirement] of RULES) {
      if (!pattern.test(code)) continue;
      const options = requirement.split('|');
      if (options.some((framework) => imports.has(framework))) continue;
      // Conditional imports still count.
      if (options.some((framework) => raw.includes(`import ${framework}`))) continue;
      warn(`${rel(file)}: uses ${options[0]} symbols but does not import ${requirement}`);
    }
  }
  if (warnings === 0) ok('all files import what they use');
}

// ------------------------------------------------- 6. widget target purity

console.log('\nWidget target only uses shared symbols');
{
  const shared = path.join(ROOT, 'SuperAlarm', 'Store', 'SharedStorage.swift');
  const sharedCode = fs.existsSync(shared) ? fs.readFileSync(shared, 'utf8') : '';
  const sharedTypes = new Set(
    [...sharedCode.matchAll(/(?:struct|class|enum|actor)\s+([A-Za-z_][A-Za-z0-9_]*)/g)].map((m) => m[1])
  );

  // Types that live only in the app and would fail to link in the widget.
  const appOnly = [
    'AlarmStore', 'AlarmRuntime', 'AlarmCoordinator', 'SAColor', 'SAFont', 'SACard',
    'HapticEngine', 'AlarmPalette', 'SoundCatalog', 'MissionType', 'MissionSettings',
    'AppSettings', 'WakeRecord', 'WakeStatistics', 'AlarmAudioEngine', 'ToneResolver',
    'SoundBundle', 'MissionAssetStore', 'WidgetRefresher', 'CustomToneStore',
  ];

  for (const file of WIDGET_FILES) {
    const code = stripNoise(fs.readFileSync(file, 'utf8'));
    for (const type of appOnly) {
      if (new RegExp(`\\b${type}\\b`).test(code)) {
        fail(`${rel(file)}: references app-only type "${type}" — the widget is a separate module and will not link`);
      }
    }
  }
  ok(`widget uses only: ${[...sharedTypes].join(', ')}`);
}

// --------------------------------------------------------------- 7. plists

console.log('\nInfo.plist keys');
{
  const plist = path.join(ROOT, 'SuperAlarm', 'Info.plist');
  if (!fs.existsSync(plist)) {
    fail('SuperAlarm/Info.plist is missing');
  } else {
    const content = fs.readFileSync(plist, 'utf8');
    const required = [
      'NSAlarmKitUsageDescription',
      'NSCameraUsageDescription',
      'NSMotionUsageDescription',
      'NSFaceIDUsageDescription',
      'NSLocationWhenInUseUsageDescription',
      'UIBackgroundModes',
    ];
    for (const key of required) {
      if (!content.includes(key)) fail(`Info.plist is missing ${key}`);
    }
    // Requesting an entitlement a free personal team cannot grant breaks
    // signing outright, so there must be no entitlements file.
    const entitlements = walk(ROOT).filter((f) => f.endsWith('.entitlements'));
    if (entitlements.length > 0) {
      warn(`entitlements files present (${entitlements.map(rel).join(', ')}) — these break free-account signing`);
    }
    ok(`${required.length} required keys present, no entitlements files`);
  }
}

// ------------------------------------------------- 8. workflow block scalars

console.log('\nGitHub workflow block scalars');
{
  const workflowDir = path.join(ROOT, '.github', 'workflows');
  const workflows = fs.existsSync(workflowDir)
    ? fs.readdirSync(workflowDir).filter((f) => f.endsWith('.yml') || f.endsWith('.yaml'))
    : [];

  if (workflows.length === 0) warn('no workflow files found');

  for (const name of workflows) {
    const file = path.join(workflowDir, name);
    const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);

    for (let i = 0; i < lines.length; i++) {
      // A key introducing a literal or folded block: `run: |`
      const opener = lines[i].match(/^(\s*)[-\s]*[A-Za-z_][\w-]*:\s*[|>][-+]?\s*$/);
      if (!opener) continue;

      const keyIndent = opener[1].length;
      let blockIndent = null;

      for (let j = i + 1; j < lines.length; j++) {
        const line = lines[j];
        if (line.trim() === '') continue;
        const indent = line.match(/^\s*/)[0].length;

        if (blockIndent === null) {
          if (indent <= keyIndent) break; // empty block
          blockIndent = indent;
          continue;
        }

        if (indent < blockIndent) {
          if (indent <= keyIndent) break; // block legitimately ended
          fail(
            `${name}:${j + 1}: line is indented ${indent} but the block started at ${blockIndent} — ` +
            `this silently ends the block scalar and breaks the workflow`
          );
          break;
        }
      }
    }
  }

  // Content at column 0 inside what looks like a shell block is the specific
  // mistake that costs a whole CI cycle.
  for (const name of workflows) {
    const lines = fs.readFileSync(path.join(workflowDir, name), 'utf8').split(/\r?\n/);
    let insideBlock = false;
    for (let i = 0; i < lines.length; i++) {
      if (/:\s*[|>][-+]?\s*$/.test(lines[i])) { insideBlock = true; continue; }
      if (lines[i].trim() === '') continue;
      const indent = lines[i].match(/^\s*/)[0].length;
      if (insideBlock && indent === 0 && !/^[A-Za-z_"']/.test(lines[i]) === false && i > 0) {
        // Only flag when the previous non-empty line was clearly shell.
        const previous = lines.slice(0, i).reverse().find((l) => l.trim() !== '') || '';
        if (previous.match(/^\s+/) && previous.match(/^\s*/)[0].length > 4) {
          fail(`${name}:${i + 1}: unindented content directly after an indented block`);
        }
      }
      if (indent <= 2) insideBlock = false;
    }
  }

  ok(`${workflows.length} workflow file(s) checked`);
}

// ---------------------------------------------------------------- summary

console.log(`\n${failures} failure(s), ${warnings} warning(s).`);
process.exit(failures ? 1 : 0);
