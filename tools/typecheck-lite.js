#!/usr/bin/env node
/**
 * Two checks that normally only a compiler performs, done statically.
 *
 * 1. Switch exhaustiveness over enums this project declares. A missing case in
 *    a switch with no `default` is a compile error, and it is easy to
 *    introduce by adding an enum case and forgetting a call site.
 * 2. Initializer argument labels for this project's own types. Wrong or
 *    out-of-order labels are a compile error — exactly the class of bug that
 *    slipped through in `UNNotificationAction(title:identifier:)`.
 *
 *   node tools/typecheck-lite.js
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

// ------------------------------------------------------------------ helpers

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
        if (c === '"') { state = 'string'; i += 1; out += '""'; continue; }
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
        if (c === '\\') {
          // Interpolation can contain arbitrary code including braces.
          if (c2 === '(') {
            let d = 0;
            let j = i + 1;
            for (; j < source.length; j++) {
              if (source[j] === '(') d++;
              else if (source[j] === ')') { d--; if (!d) break; }
            }
            i = j + 1;
            continue;
          }
          i += 2;
          continue;
        }
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

/** Body of the brace block beginning at or after `from`. */
function blockAt(source, from) {
  const open = source.indexOf('{', from);
  if (open === -1) return null;
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') depth++;
    else if (source[i] === '}') {
      depth--;
      if (depth === 0) return { body: source.slice(open + 1, i), start: open + 1, end: i };
    }
  }
  return null;
}

/** Splits an argument list on top-level commas. */
function splitArguments(text) {
  const parts = [];
  let depth = 0;
  let current = '';
  for (const ch of text) {
    if (ch === '(' || ch === '[' || ch === '{') depth++;
    else if (ch === ')' || ch === ']' || ch === '}') depth--;
    if (ch === ',' && depth === 0) { parts.push(current); current = ''; continue; }
    current += ch;
  }
  if (current.trim() !== '') parts.push(current);
  return parts;
}

/** Argument labels of a call, using "_" for unlabelled positions. */
function callLabels(argumentText) {
  return splitArguments(argumentText).map((part) => {
    const match = part.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:(?!:)/);
    return match ? match[1] : '_';
  });
}

const files = walk(ROOT);
const sources = new Map();
for (const file of files) sources.set(file, stripNoise(fs.readFileSync(file, 'utf8')));

let failures = 0;
const fail = (message) => { failures++; console.log(`  FAIL  ${message}`); };
const rel = (file) => path.relative(ROOT, file).replace(/\\/g, '/');
const lineOf = (source, index) => source.slice(0, index).split('\n').length;

// ------------------------------------------------- 1. collect enum cases

// Kept as a list rather than a map keyed on the simple name: nested enums in
// different types legitimately share a name (WakeRecord.Outcome and
// BiometricMission.Outcome, RootView.Tab and SoundPickerView.Tab), and merging
// their cases would make every switch over them look non-exhaustive.
const enumDecls = [];   // { name, cases: Set }

for (const [, code] of sources) {
  const pattern = /\benum\s+([A-Za-z_][A-Za-z0-9_]*)/g;
  let match;
  while ((match = pattern.exec(code)) !== null) {
    const name = match[1];
    const block = blockAt(code, match.index);
    if (!block) continue;

    const cases = new Set();
    enumDecls.push({ name, cases });

    for (const caseMatch of block.body.matchAll(/\bcase\s+([^\n{}]+)/g)) {
      let depth = 0;
      let current = '';
      const parts = [];
      for (const ch of caseMatch[1]) {
        if (ch === '(') depth++;
        else if (ch === ')') depth--;
        if (ch === ',' && depth === 0) { parts.push(current); current = ''; continue; }
        current += ch;
      }
      parts.push(current);

      for (const part of parts) {
        const trimmed = part.trim();
        const caseName = trimmed.split(/[\s(=:]/)[0];
        if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(caseName)) continue;
        cases.add(caseName);
      }
    }
  }
}

// --------------------------------------------- 2. switch exhaustiveness

console.log('Switch exhaustiveness over project enums');

for (const [file, code] of sources) {
  const pattern = /\bswitch\s+([^\n{]+)\{/g;
  let match;
  while ((match = pattern.exec(code)) !== null) {
    const block = blockAt(code, match.index + match[0].length - 1);
    if (!block) continue;

    // Only consider the top level of this switch, not nested ones.
    let depth = 0;
    const labels = new Set();
    let hasDefault = false;
    let hasUnknownDefault = false;

    const body = block.body;
    for (let i = 0; i < body.length; i++) {
      const ch = body[i];
      if (ch === '{') { depth++; continue; }
      if (ch === '}') { depth--; continue; }
      if (depth !== 0) continue;

      if (body.startsWith('default', i) && /\W/.test(body[i - 1] || ' ')) {
        hasDefault = true;
        continue;
      }
      if (body.startsWith('@unknown', i)) { hasUnknownDefault = true; continue; }

      if (body.startsWith('case', i) && /\W/.test(body[i - 1] || ' ') && /\s/.test(body[i + 4] || '')) {
        // Read to the terminating colon at this nesting level.
        let j = i + 4;
        let inner = 0;
        let text = '';
        for (; j < body.length; j++) {
          const c = body[j];
          if (c === '(' || c === '[') inner++;
          else if (c === ')' || c === ']') inner--;
          else if (c === ':' && inner === 0) break;
          else if (c === '\n' && inner === 0) break;
          text += c;
        }
        for (const dotted of text.matchAll(/\.([A-Za-z_][A-Za-z0-9_]*)/g)) {
          labels.add(dotted[1]);
        }
        // `case let x where …` and similar bind rather than match a case.
        if (/\blet\b|\bvar\b|\bwhere\b/.test(text) && labels.size === 0) {
          hasDefault = true;
        }
      }
    }

    if (hasDefault || hasUnknownDefault || labels.size === 0) continue;

    // Identify the enum: the declaration whose case set contains every label
    // used, and which is uniquely determined by them.
    const candidates = enumDecls.filter((decl) =>
      [...labels].every((label) => decl.cases.has(label))
    );
    if (candidates.length !== 1) continue;

    const { name: enumName, cases } = candidates[0];
    const missing = [...cases].filter((c) => !labels.has(c));
    if (missing.length > 0) {
      fail(
        `${rel(file)}:${lineOf(code, match.index)}  switch over ${enumName} ` +
        `is missing: ${missing.join(', ')}`
      );
    }
  }
}
console.log(`  ok    ${enumDecls.length} enum declarations indexed`);

// --------------------------------------- 3. initializer argument labels

console.log('\nInitializer argument labels');

const initializers = new Map();   // type -> [{labels, required}]
const memberwise = new Map();     // type -> [{name, hasDefault}]
const isStruct = new Set();

for (const [, code] of sources) {
  // Extensions are included: a type's initialisers are frequently declared in
  // a constrained extension rather than the main body.
  const pattern = /\b(struct|final class|class|actor|extension)\s+([A-Za-z_][A-Za-z0-9_]*)/g;
  let match;
  while ((match = pattern.exec(code)) !== null) {
    const kind = match[1];
    const name = match[2];
    const block = blockAt(code, match.index);
    if (!block) continue;
    if (kind === 'struct') isStruct.add(name);

    if (!initializers.has(name)) initializers.set(name, []);
    if (!memberwise.has(name)) memberwise.set(name, []);

    // Explicit initialisers at this type's top level.
    let depth = 0;
    const body = block.body;
    for (let i = 0; i < body.length; i++) {
      const ch = body[i];
      if (ch === '{') { depth++; continue; }
      if (ch === '}') { depth--; continue; }
      if (depth !== 0) continue;

      if (body.startsWith('init', i) && /\W/.test(body[i - 1] || ' ')) {
        const after = body.slice(i + 4);
        const open = after.search(/[({?!]/);
        if (open === -1 || after[open] !== '(') continue;
        const args = blockAtParen(after, open);
        if (args === null) continue;
        const params = splitArguments(args).map((raw) => {
          // Drop leading attributes such as @ViewBuilder or @escaping.
          const part = raw.replace(/^\s*(@\w+(\([^)]*\))?\s+)*/, '');
          const m = part.match(/^\s*([A-Za-z_][A-Za-z0-9_]*|_)\s+[A-Za-z_][A-Za-z0-9_]*\s*:/)
            || part.match(/^\s*([A-Za-z_][A-Za-z0-9_]*|_)\s*:/);
          const typeAndDefault = part.split(':').slice(1).join(':');
          return {
            label: m ? m[1] : '_',
            hasDefault: /=/.test(typeAndDefault),
          };
        });
        initializers.get(name).push(params);
      }

      // Stored properties, for the synthesised memberwise initialiser.
      const propertyMatch = /^(?:public\s+|private\s+|internal\s+|fileprivate\s+)*(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(:[^\n=]+)?(=)?/.exec(
        body.slice(i, i + 200)
      );
      if (
        propertyMatch &&
        (body.startsWith('var', i) || body.startsWith('let', i) ||
         body.startsWith('public var', i) || body.startsWith('public let', i)) &&
        /\W/.test(body[i - 1] || ' ')
      ) {
        const rest = body.slice(i, body.indexOf('\n', i) === -1 ? undefined : body.indexOf('\n', i));
        // Computed properties are not stored.
        if (!/\{\s*$/.test(rest)) {
          memberwise.get(name).push({
            name: propertyMatch[1],
            hasDefault: /=/.test(rest.split(':').slice(1).join(':')),
          });
        }
      }
    }
  }
}

/**
 * True when a call's argument labels can satisfy a parameter list. Parameters
 * with default values may be skipped, but the surviving labels must still
 * appear in declaration order — which is exactly Swift's rule.
 */
function matchesInit(params, used) {
  let p = 0;
  let u = 0;
  while (p < params.length) {
    if (u < used.length && used[u] === params[p].label) { p++; u++; continue; }
    if (params[p].hasDefault) { p++; continue; }
    return false;
  }
  return u === used.length;
}

function blockAtParen(text, openIndex) {
  const span = parenSpan(text, openIndex);
  return span ? text.slice(openIndex + 1, span.close) : null;
}

function parenSpan(text, openIndex) {
  let depth = 0;
  for (let i = openIndex; i < text.length; i++) {
    if (text[i] === '(') depth++;
    else if (text[i] === ')') {
      depth--;
      if (depth === 0) return { open: openIndex, close: i };
    }
  }
  return null;
}

// Check call sites for types that declare explicit initialisers only.
const CHECKABLE = [...initializers.entries()]
  .filter(([name, inits]) => inits.length > 0 && isStruct.has(name))
  .map(([name]) => name);

for (const [file, code] of sources) {
  for (const typeName of CHECKABLE) {
    const pattern = new RegExp(`(?:^|[^A-Za-z0-9_.])${typeName}\\s*\\(`, 'g');
    let match;
    while ((match = pattern.exec(code)) !== null) {
      const openIndex = code.indexOf('(', match.index + match[0].length - 1);
      const span = parenSpan(code, openIndex);
      if (!span) continue;
      const args = code.slice(openIndex + 1, span.close);
      if (args.trim() === '') continue;

      // `SACard(padding: 8) { ... }` supplies the final parameter as a
      // trailing closure, so it never appears inside the parentheses.
      const after = code.slice(span.close + 1);
      const hasTrailingClosure = /^\s*\{/.test(after);

      const used = callLabels(args);
      const accepted = initializers.get(typeName);
      const matches = accepted.some((params) => {
        if (matchesInit(params, used)) return true;
        if (hasTrailingClosure && params.length > 0) {
          return matchesInit(params.slice(0, -1), used);
        }
        return false;
      });
      if (!matches) {
        fail(
          `${rel(file)}:${lineOf(code, match.index)}  ${typeName}(${used.join(':')}:) ` +
          `does not match any declared initialiser ` +
          `[${accepted.map((p) => p.map((x) => x.label + (x.hasDefault ? '?' : '')).join(':') + ':').join('  |  ')}]`
        );
      }
    }
  }
}
console.log(`  ok    ${CHECKABLE.length} struct types with explicit initialisers checked`);

// -------------------------- 4. locals shadowing a name used earlier

console.log('\nLocals used before their declaration');

/** The innermost brace block containing `index`. */
function enclosingBlock(code, index) {
  let depth = 0;
  let open = -1;
  for (let i = index; i >= 0; i--) {
    if (code[i] === '}') depth++;
    else if (code[i] === '{') {
      if (depth === 0) { open = i; break; }
      depth--;
    }
  }
  if (open === -1) return null;

  depth = 0;
  for (let i = open; i < code.length; i++) {
    if (code[i] === '{') depth++;
    else if (code[i] === '}') {
      depth--;
      if (depth === 0) return { start: open + 1, end: i };
    }
  }
  return null;
}

for (const [file, code] of sources) {
  // Statement-level `let x = …` / `var x = …` only. `if let` and `guard let`
  // scope to their own body, so they cannot shadow earlier uses.
  const pattern = /(^|\n)([ \t]*)(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^\n=]+)?=/g;
  let match;
  while ((match = pattern.exec(code)) !== null) {
    const name = match[3];
    const declIndex = match.index + match[1].length;

    const block = enclosingBlock(code, declIndex);
    if (!block) continue;

    const before = code.slice(block.start, declIndex);
    // A bare use of the name: not a member access, not part of a longer
    // identifier, and not an argument label or dictionary key (`name:`),
    // which are not references to the variable at all.
    const bareUse = new RegExp(`(?<![.\\w$])${name}(?![\\w$])(?!\\s*:)`);
    if (!bareUse.test(before)) continue;

    // Skip when the earlier occurrence is itself a declaration of the same
    // name in a nested scope (a loop variable, say).
    const earlierDecl = new RegExp(`(?:let|var|func|for)\\s+${name}\\b`);
    if (earlierDecl.test(before)) continue;

    fail(
      `${rel(file)}:${lineOf(code, declIndex)}  local '${name}' is declared here ` +
      `but the same name is already used earlier in this scope — Swift rejects this ` +
      `as "use of local variable before its declaration"`
    );
  }
}
console.log('  ok    scope shadowing checked');

console.log(`\n${failures} failure(s).`);
process.exit(failures ? 1 : 0);
