import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cCode } from './reference-content.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
if (args.some(argument => !['--count', '--list'].includes(argument))) {
  console.error('list-tests: use --count or --list');
  process.exit(1);
}
const files = (directory, suffix) => !existsSync(directory) ? []
  : readdirSync(directory, { withFileTypes: true }).flatMap(entry => entry.isDirectory()
    ? files(resolve(directory, entry.name), suffix)
    : entry.isFile() && entry.name.endsWith(suffix) ? [resolve(directory, entry.name)] : []).sort();
const declarations = [];
for (const file of files(resolve(root, 'src'), '.zig')) {
  const text = readFileSync(file, 'utf8');
  // A character literal such as '"' must not open a string, or every test after it is hidden.
  const pattern = /\/\/[^\n]*|'(?:\\.|[^'\\])+'|"(?:\\.|[^"\\])*"|\\\\[^\n]*|\btest\s+(?:"((?:\\.|[^"\\])*)"\s*)?\{/g;
  for (const match of text.matchAll(pattern)) {
    if (!match[0].startsWith('test')) continue;
    declarations.push({ file: relative(root, file), name: match[1] ?? '(anonymous)', kind: 'Zig' });
  }
}
for (const file of files(resolve(root, 'test/c'), '.c')) {
  const text = cCode(readFileSync(file, 'utf8'));
  for (const match of text.matchAll(/\{\s*"((?:\\.|[^"\\])*)"\s*,\s*case_\w+\s*\}/g)) {
    declarations.push({ file: relative(root, file), name: match[1], kind: 'C' });
  }
}
const zig = declarations.filter(entry => entry.kind === 'Zig').length;
console.log(`list-tests: ${zig} Zig and ${declarations.length - zig} C case declarations, none run`);
if (!args.includes('--count')) for (const entry of declarations) console.log(`  ${entry.file}: ${entry.name}`);
console.log('Declaration counts do not establish reachability or executed test counts.');
