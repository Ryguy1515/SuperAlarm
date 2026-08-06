#!/usr/bin/env node
/**
 * Resolves `MyType.member` references against the members this project
 * actually declares.
 *
 * Without a Swift compiler on this machine, a typo in a static member name
 * would otherwise survive all the way to CI. Only types declared in this
 * repository are checked — anything from the SDK is left alone, since its
 * members are not visible here.
 *
 *   node tools/symbol-check.js
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

// Members the compiler synthesises or inherits from a protocol, which never
// appear as explicit declarations.
const SYNTHESISED = new Set([
  'allCases', 'init', 'self', 'Type', 'rawValue', 'RawValue', 'hashValue',
  'CodingKeys', 'AllCases', 'ID', 'Body', 'body', 'shared',
]);

function walk(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'node_modules' || entry.name === '.git') continue;
      walk(full, out);
    } else if (entry.name.endsWith('.swift')) {
      out.push(full);
    }
  }
  return out;
}

/** Single-pass comment and string stripper (URLs contain `//`). */
function stripNoise(source) {
  let out = '';
  let i = 0;
  let state = 'code';
  let depth = 0;
  while (i < source.length) {
    const c = source[i];
    const c2 = source[i + 1];
    switch (state) {
      case 'code':
        if (c === '/' && c2 === '/') { state = 'line'; i += 2; continue; }
        if (c === '/' && c2 === '*') { state = 'block'; depth = 1; i += 2; continue; }
        if (c === '#' && c2 === '"') { state = 'raw'; i += 2; continue; }
        if (source.startsWith('"""', i)) { state = 'triple'; i += 3; continue; }
        if (c === '"') { state = 'string'; i += 1; continue; }
        out += c; i += 1; continue;
      case 'line':
        if (c === '\n') { state = 'code'; out += c; }
        i += 1; continue;
      case 'block':
        if (c === '/' && c2 === '*') { depth += 1; i += 2; continue; }
        if (c === '*' && c2 === '/') { depth -= 1; i += 2; if (!depth) state = 'code'; continue; }
        if (c === '\n') out += c;
        i += 1; continue;
      case 'string':
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

/** Returns the body text of the brace block that starts at or after `from`. */
function bodyAfter(source, from) {
  const open = source.indexOf('{', from);
  if (open === -1) return null;
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') depth++;
    else if (source[i] === '}') {
      depth--;
      if (depth === 0) return source.slice(open + 1, i);
    }
  }
  return null;
}

const files = walk(ROOT);

// name -> Set(members)
const types = new Map();
// Types this project declares, so SDK types can be skipped.
const declared = new Set();

const DECL = /\b(?:struct|enum|final class|class|actor|protocol|extension)\s+([A-Za-z_][A-Za-z0-9_]*)/g;
const MEMBER = /\b(?:static\s+(?:public\s+|private\s+)?)?(?:public\s+|private\s+|internal\s+|fileprivate\s+)?(?:static\s+)?(?:func|var|let|case|typealias|struct|enum|class)\s+([A-Za-z_][A-Za-z0-9_]*)/g;

for (const file of files) {
  const code = stripNoise(fs.readFileSync(file, 'utf8'));
  let match;
  DECL.lastIndex = 0;
  while ((match = DECL.exec(code)) !== null) {
    const name = match[1];
    const isExtension = code.slice(Math.max(0, match.index - 12), match.index + 10).includes('extension');
    if (!isExtension) declared.add(name);

    const body = bodyAfter(code, match.index);
    if (!body) continue;

    if (!types.has(name)) types.set(name, new Set());
    const members = types.get(name);

    MEMBER.lastIndex = 0;
    let member;
    while ((member = MEMBER.exec(body)) !== null) {
      members.add(member[1]);
    }
    // Enum cases can be comma-separated and carry raw values or payloads:
    //   case sunday = 1, monday, tuesday
    //   case reps(goal: Int, kind: MissionType)
    for (const caseLine of body.matchAll(/\bcase\s+([^\n{}]+)/g)) {
      // Split on commas that are not inside an associated-value list.
      let depth = 0;
      let current = '';
      const parts = [];
      for (const ch of caseLine[1]) {
        if (ch === '(') depth++;
        else if (ch === ')') depth--;
        if (ch === ',' && depth === 0) { parts.push(current); current = ''; continue; }
        current += ch;
      }
      parts.push(current);

      for (const part of parts) {
        const name = part.trim().split(/[\s(=:]/)[0];
        if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) members.add(name);
      }
    }
  }
}

let failures = 0;
const seen = new Set();

const USE = /\b([A-Z][A-Za-z0-9_]*)\.([a-zA-Z_][A-Za-z0-9_]*)/g;

for (const file of files) {
  const code = stripNoise(fs.readFileSync(file, 'utf8'));
  const lines = code.split('\n');

  lines.forEach((line, index) => {
    USE.lastIndex = 0;
    let match;
    while ((match = USE.exec(line)) !== null) {
      const [, typeName, member] = match;
      if (!declared.has(typeName)) continue;      // SDK type — not our business
      if (SYNTHESISED.has(member)) continue;

      const members = types.get(typeName);
      if (!members || members.has(member)) continue;

      const key = `${typeName}.${member}`;
      if (seen.has(key)) continue;
      seen.add(key);

      failures++;
      console.log(
        `  FAIL  ${path.relative(ROOT, file).replace(/\\/g, '/')}:${index + 1}  ` +
        `${typeName}.${member} — no such member declared`
      );
    }
  });
}

console.log(
  `\n${declared.size} project types, ` +
  `${[...types.values()].reduce((n, s) => n + s.size, 0)} members indexed. ` +
  `${failures} unresolved reference(s).`
);
process.exit(failures ? 1 : 0);
