import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { ESLint } from 'eslint';
import nextVitals from 'eslint-config-next/core-web-vitals';
import nextTs from 'eslint-config-next/typescript';

// Resolve exactly the production Next lint chain, not a direct test dependency.
const require = createRequire(import.meta.url);
const configRequire = createRequire(require.resolve('eslint-config-next'));
const nextRequire = createRequire(configRequire.resolve('@next/eslint-plugin-next'));
const globRequire = createRequire(nextRequire.resolve('fast-glob'));
const microRequire = createRequire(globRequire.resolve('micromatch'));
const braces = microRequire('braces');
const fastGlob = nextRequire('fast-glob');
const nested = (depth) => '{'.repeat(depth) + 'x' + '}'.repeat(depth);


test('actual Next fast-glob edge resolves exact reviewed MIT fork', () => {
  const path = microRequire.resolve('braces');
  const pkg = JSON.parse(readFileSync(join(dirname(path), 'package.json'), 'utf8'));
  assert.equal(pkg.name, '@dieub/braces-depth-guard');
  assert.equal(pkg.version, '3.0.3-pn.3');
  assert.equal(pkg.license, 'MIT');
  assert.match(readFileSync(join(dirname(path), 'LICENSE'), 'utf8'), /MIT License/);
});

test('valid ranges, escaping, alternatives and nesting retain semantics', () => {
  assert.deepEqual(braces.expand('item{1..3}'), ['item1', 'item2', 'item3']);
  assert.deepEqual(braces.expand('{a,{b,c}}'), ['a', 'b', 'c']);
  assert.deepEqual(braces.expand('literal\\{a,b\\}'), ['literal{a,b}']);
  assert.match('file2', new RegExp('^' + braces.compile('file{1..3}') + '$'));
  assert.equal(braces.stringify(braces.parse('{a,{b,c}}')), '{a,{b,c}}');
});

test('100 accepted, 101 and very deep rejected across public paths and option bypasses', () => {
  for (const fn of [braces.parse, braces.compile, braces.expand]) {
    assert.doesNotThrow(() => fn(nested(100)));
    for (const depth of [101, 4000]) {
      for (const options of [{}, { maxDepth: Infinity }, { maxDepth: NaN }, { maxDepth: 100000 }]) {
        assert.throws(() => fn(nested(depth), options), /exceeds max depth/);
      }
    }
  }
  assert.doesNotThrow(() => braces.stringify(braces.parse(nested(100))));
  // Caller-supplied ASTs bypass parse: every recursive walker must still guard.
  const ast = (depth) => {
    let node = { type: 'text', value: 'x' };
    for (let i = 0; i < depth; i++) node = { type: 'root', nodes: [node] };
    return { type: 'root', nodes: [node] };
  };
  for (const fn of [braces.compile, braces.expand, braces.stringify]) {
    assert.doesNotThrow(() => fn(ast(100)));
    assert.throws(() => fn(ast(101)), /exceeds max depth/);
  }
  for (const fn of [braces.parse, braces.compile, braces.expand]) {
    let reads = 0;
    const options = { get maxDepth() { return reads++ === 0 ? 100 : NaN; } };
    assert.throws(() => fn(nested(101), options), /exceeds max depth/);
    assert.equal(reads, 1);
  }
  const cyclic = { type: 'text', nodes: [] };
  cyclic.parent = cyclic;
  assert.throws(() => braces.expand({ type: 'root', nodes: [cyclic] }), /cycle/);
  assert.throws(() => braces.parse('a', { maxDepth: -1 }), /non-negative/);
  assert.throws(() => braces.parse('a', { maxLength: NaN }), /non-negative/);
  assert.throws(() => braces.parse('a', { maxLength: -1 }), /non-negative/);
});

test('real fast-glob chain matches nested/range patterns and rejects deep input', () => {
  const cwd = mkdtempSync(join(tmpdir(), 'site-glob-'));
  try {
    mkdirSync(join(cwd, 'pages'));
    for (const file of ['one.tsx', 'two.tsx', 'item1.tsx', 'item2.tsx', 'skip.js']) writeFileSync(join(cwd, 'pages', file), '');
    assert.deepEqual(fastGlob.sync('pages/{one,{two,item{1..2}}}.tsx', { cwd }).sort(),
      ['pages/item1.tsx', 'pages/item2.tsx', 'pages/one.tsx', 'pages/two.tsx']);
    assert.throws(() => fastGlob.sync(nested(101), { cwd }), /exceeds max depth/);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test('effective Next/TypeScript rules unchanged; invalid Next fixture still fails', async () => {
  const actual = new ESLint();
  const upstream = new ESLint({ overrideConfigFile: true, overrideConfig: [...nextVitals, ...nextTs] });
  const filePath = 'src/app/braces-regression/page.tsx';
  const effective = await actual.calculateConfigForFile(filePath);
  const expected = await upstream.calculateConfigForFile(filePath);
  assert.deepEqual(effective.rules, expected.rules);
  const results = await actual.lintText('export default function Page() { return <script src="/bad.js" />; }', { filePath });
  assert.ok(results[0].errorCount > 0);
  assert.ok(results[0].messages.some((message) => message.ruleId === '@next/next/no-sync-scripts' && message.severity === 2));
});
