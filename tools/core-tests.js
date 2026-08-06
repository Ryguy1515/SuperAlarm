#!/usr/bin/env node
/**
 * Compiles and runs the platform-independent core of the app with the Swift
 * toolchain for Windows.
 *
 * SwiftUI, UIKit, AVFoundation and AlarmKit only exist on Apple platforms, so
 * a full build has to happen on macOS. But the scheduling maths, the mission
 * generators, the statistics and the persistence layer are pure Foundation —
 * and those are precisely the parts where a silent bug means a missed alarm.
 * This assembles them into a throwaway SwiftPM package, copies the real test
 * files across (minus the cases that touch Apple-only types), and runs them.
 *
 *   node tools/core-tests.js
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const PKG = process.env.SUPERALARM_CORE_DIR
  || path.join(process.env.TEMP || process.env.TMP || ROOT, 'superalarm-core');

/** Files that compile against Foundation alone, and form a closed set. */
const PORTABLE_SOURCES = [
  'SuperAlarm/Models/Alarm.swift',
  'SuperAlarm/Models/Mission.swift',
  'SuperAlarm/Models/AppSettings.swift',
  'SuperAlarm/Models/WakeRecord.swift',
  'SuperAlarm/Missions/CognitiveMissions.swift',
  'SuperAlarm/Audio/SoundCatalog.generated.swift',
];

/**
 * Test cases that reach for something Apple-only. Everything else runs.
 *   MissionSession    -> Combine
 *   ToneResolver      -> CustomToneStore -> AVFoundation
 *   WidgetSnapshot    -> SharedStorage -> os.log
 *   AlarmStore        -> Combine
 */
const EXCLUDED_TESTS = new Set([
  'testSessionCompletesAfterEveryRound',
  'testSessionTracksFailures',
  'testForceCompleteSatisfiesTheWholeSession',
  'testRoundLabelOnlyAppearsForMultiRoundMissions',
  'testRandomToneIdentifiersRoundTrip',
  'testBundledToneFallbackAlwaysResolvesToARealFile',
  'testWidgetSnapshotRoundTrip',
  'testStoreSortsEnabledAlarmsByNextFireTime',
  'testTogglingAnAlarmClearsAPendingSkip',
  'testFiringAOneShotAlarmSwitchesItOff',
  'testFiringARepeatingAlarmLeavesItOn',
  'testScheduleInvalidationFiresOnEveryMutation',
  'testNextAlarmIgnoresDisabledOnes',
]);

const TEST_SOURCES = [
  'SuperAlarmTests/AlarmSchedulingTests.swift',
  'SuperAlarmTests/MissionLogicTests.swift',
  'SuperAlarmTests/StatisticsAndPersistenceTests.swift',
];

// ------------------------------------------------------------------ helpers

/**
 * Removes a whole `func name(...) { ... }` declaration, along with any
 * attribute lines immediately above it, by brace matching from the body's
 * opening brace.
 */
function removeFunction(source, name) {
  const signature = new RegExp(`\\n([ \\t]*)(?:@[A-Za-z]+[^\\n]*\\n[ \\t]*)*func\\s+${name}\\s*\\(`);
  const match = signature.exec(source);
  if (!match) return source;

  const start = match.index;
  // Walk forward to the opening brace of the body.
  let i = source.indexOf('{', match.index + match[0].length - 1);
  if (i === -1) return source;

  let depth = 0;
  let inString = false;
  let inLineComment = false;
  for (; i < source.length; i++) {
    const c = source[i];
    const c2 = source[i + 1];

    if (inLineComment) {
      if (c === '\n') inLineComment = false;
      continue;
    }
    if (inString) {
      if (c === '\\') { i++; continue; }
      if (c === '"') inString = false;
      continue;
    }
    if (c === '/' && c2 === '/') { inLineComment = true; i++; continue; }
    if (c === '"') { inString = true; continue; }
    if (c === '{') depth++;
    else if (c === '}') {
      depth--;
      if (depth === 0) {
        return source.slice(0, start) + '\n' + source.slice(i + 1);
      }
    }
  }
  return source;
}

function rmrf(target) {
  if (fs.existsSync(target)) fs.rmSync(target, { recursive: true, force: true });
}

function which(command) {
  const result = spawnSync(process.platform === 'win32' ? 'where' : 'which', [command], {
    encoding: 'utf8',
    shell: false,
  });
  return result.status === 0 ? result.stdout.split(/\r?\n/)[0].trim() : null;
}

// --------------------------------------------------------------------- main

const swift = which('swift');
if (!swift) {
  console.error('Swift toolchain not found on PATH.');
  console.error('Install it with:  winget install --id Swift.Toolchain -e');
  process.exit(2);
}
console.log(`Using ${swift}`);

rmrf(PKG);
fs.mkdirSync(path.join(PKG, 'Sources', 'SuperAlarmCore'), { recursive: true });
fs.mkdirSync(path.join(PKG, 'Tests', 'SuperAlarmCoreTests'), { recursive: true });

fs.writeFileSync(
  path.join(PKG, 'Package.swift'),
  `// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SuperAlarmCore",
    targets: [
        .target(name: "SuperAlarmCore", path: "Sources/SuperAlarmCore"),
        .testTarget(
            name: "SuperAlarmCoreTests",
            dependencies: ["SuperAlarmCore"],
            path: "Tests/SuperAlarmCoreTests"
        ),
    ]
)
`,
  'utf8'
);

console.log('\nSources');
for (const relative of PORTABLE_SOURCES) {
  const from = path.join(ROOT, relative);
  if (!fs.existsSync(from)) {
    console.error(`  missing ${relative}`);
    process.exit(1);
  }
  const to = path.join(PKG, 'Sources', 'SuperAlarmCore', path.basename(relative));
  fs.copyFileSync(from, to);
  console.log(`  ${relative}`);
}

console.log('\nTests');
let removedCount = 0;
for (const relative of TEST_SOURCES) {
  const from = path.join(ROOT, relative);
  let source = fs.readFileSync(from, 'utf8');

  source = source.replace(/@testable import SuperAlarm\b/g, '@testable import SuperAlarmCore');

  const removedHere = [];
  for (const name of EXCLUDED_TESTS) {
    const before = source;
    source = removeFunction(source, name);
    if (source !== before) {
      removedHere.push(name);
      removedCount++;
    }
  }

  fs.writeFileSync(
    path.join(PKG, 'Tests', 'SuperAlarmCoreTests', path.basename(relative)),
    source,
    'utf8'
  );
  console.log(`  ${relative}${removedHere.length ? `  (skipped ${removedHere.length})` : ''}`);
}

const remaining = TEST_SOURCES.reduce((total, relative) => {
  const source = fs.readFileSync(
    path.join(PKG, 'Tests', 'SuperAlarmCoreTests', path.basename(relative)),
    'utf8'
  );
  return total + (source.match(/func test/g) || []).length;
}, 0);

console.log(`\n${remaining} test cases retained, ${removedCount} skipped (Apple-only dependencies).`);
console.log(`Package at ${PKG}\n`);

const result = spawnSync(swift, ['test', '--package-path', PKG], {
  stdio: 'inherit',
  encoding: 'utf8',
});

process.exit(result.status === null ? 1 : result.status);
