// Runs the manual's examples through the nilu the build made and holds them to
// what the manual shows (doc/en/README.md, "What this manual promises").
//
// An example is a `nilu`, `nilu-cli` or `nilu-c` block followed by its `stdin`,
// `output` and `stderr` blocks. A `nilu` block runs as a file named `<manual>`
// in an empty directory, so a failure names `<manual>:line`; a `nilu-cli` block
// is the command line as a person would type it; a `nilu-c` block is a host
// compiled against the header and library. `nilu-source`, `bash` and `text`
// blocks are not run. The refused-source table of 13.2 is run row by row and
// each row must be a syntax error; a row written as `—` cannot be settled by
// running and is only counted. The banner `nilu <version>` in an expected
// output stands for whatever version was built.
//
//   node tools/manual-check.mjs --nilu <exe> --zig <zig> --include <dir> --library <archive>
//     [--root <dir>] [--list] [--only=<chapter file or case id>]
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fenceTag } from './reference-content.mjs';

const args = process.argv.slice(2);
const options = { list: false, only: null, root: resolve(fileURLToPath(new URL('../', import.meta.url))) };
for (let i = 0; i < args.length; i++) {
  const argument = args[i];
  if (['--nilu', '--zig', '--include', '--library', '--root'].includes(argument)) {
    const value = args[++i];
    if (!value || value.startsWith('--')) throw new Error(`${argument} needs a value`);
    options[argument.slice(2)] = value;
  } else if (argument === '--list') options.list = true;
  else if (argument.startsWith('--only=') && argument.length > 7) options.only = argument.slice(7);
  else throw new Error('use --nilu <exe> [--zig <zig> --include <dir> --library <archive>] [--root <dir>] [--list] [--only=<chapter or id>]');
}
if (!options.nilu && !options.list) throw new Error('--nilu <exe> is required to run anything');
// Examples run in a temporary directory, so every path given is made absolute first.
for (const key of ['nilu', 'zig', 'include', 'library', 'root']) if (options[key]) options[key] = resolve(options[key]);

/* Every fenced block with the line of its opening fence. */
export function fencedBlocks(text) {
  const blocks = [];
  const lines = text.split('\n');
  let open = null;
  lines.forEach((line, index) => {
    if (open) {
      const close = /^\s{0,3}(`+|~+)\s*$/.exec(line)?.[1];
      if (close && close[0] === open.marker[0] && close.length >= open.marker.length) {
        blocks.push({ tag: open.tag, body: open.lines.join('\n'), line: open.line, end: index + 1 });
        open = null;
      } else open.lines.push(line);
      return;
    }
    const fence = /^\s{0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence) open = { marker: fence[1], tag: fenceTag(fence[2]), line: index + 1, lines: [] };
  });
  if (open) throw new Error('a fenced block is not closed');
  return blocks;
}

const runnable = new Set(['nilu', 'nilu-cli', 'nilu-c']);
const expectations = new Set(['stdin', 'output', 'stderr']);

/* The examples of one chapter: each runnable block with the expectation blocks
 * that follow it directly (one blank line between fences is allowed). */
export function examples(text, chapter) {
  const blocks = fencedBlocks(text);
  const cases = [];
  for (let i = 0; i < blocks.length; i++) {
    const block = blocks[i];
    if (!runnable.has(block.tag)) continue;
    const found = { id: `${chapter}:${block.line}`, chapter, line: block.line, kind: block.tag, source: block.body, stdin: null, output: null, stderr: null };
    let end = block.end;
    while (i + 1 < blocks.length && expectations.has(blocks[i + 1].tag) && blocks[i + 1].line <= end + 2) {
      i++;
      found[blocks[i].tag] = blocks[i].body;
      end = blocks[i].end;
    }
    cases.push(found);
  }
  return cases;
}

/* The third column of the refused-source table in 13.2: code to refuse, or `—`. */
export function refusedRows(text, chapter) {
  const lines = text.split('\n');
  const start = lines.findIndex(line => /^## 13\.2/.test(line));
  if (start === -1) return { rows: [], unsettled: 0 };
  const rows = [];
  let unsettled = 0;
  let inTable = false;
  for (let index = start + 1; index < lines.length; index++) {
    const line = lines[index];
    if (/^## /.test(line)) break;
    if (/^### /.test(line) && inTable) break;
    if (!/^\|/.test(line)) {
      if (inTable) break;
      continue;
    }
    const cells = line.split('|').slice(1, -1).map(cell => cell.trim());
    if (cells.length !== 3) continue;
    if (/^-+$/.test(cells[0]) || cells[2] === '' || /^What is refused|^断られること/.test(cells[2])) {
      inTable = true;
      continue;
    }
    inTable = true;
    if (cells[2] === '—') {
      unsettled++;
      continue;
    }
    const code = /^`(.*)`$/.exec(cells[2]);
    if (code) rows.push({ id: `${chapter}:${index + 1}`, chapter, line: index + 1, source: code[1] });
  }
  return { rows, unsettled };
}

/* A command line the way a person types it: words, with single or double quotes. */
export function shellWords(line) {
  const words = [];
  let word = null;
  let quote = null;
  for (const character of line) {
    if (quote) {
      if (character === quote) quote = null;
      else word += character;
    } else if (character === "'" || character === '"') {
      quote = character;
      if (word === null) word = '';
    } else if (/\s/.test(character)) {
      if (word !== null) words.push(word);
      word = null;
    } else word = (word ?? '') + character;
  }
  if (quote) throw new Error(`unclosed quote in: ${line}`);
  if (word !== null) words.push(word);
  return words;
}

const expectedText = body => (body === '' ? '' : body + '\n');

function run(command, commandArgs, cwd, input) {
  const result = spawnSync(command, commandArgs, { cwd, input, encoding: 'utf8', timeout: 60000, maxBuffer: 16 * 1024 * 1024 });
  if (result.error) throw result.error;
  return result;
}

let banner = null;
function substituteVersion(text) {
  return text.replace(/^nilu \d+\.\d+\.\d+(?:-dev\.\d+)?$/gm, banner.trim());
}

function runCase(found, directory) {
  const stdin = found.stdin === null ? '' : expectedText(found.stdin);
  let result;
  if (found.kind === 'nilu') {
    const path = join(directory, '<manual>');
    writeFileSync(path, found.source + '\n');
    result = run(options.nilu, ['<manual>'], directory, stdin);
    rmSync(path, { force: true });
  } else if (found.kind === 'nilu-cli') {
    const words = shellWords(found.source.trim());
    if (words[0] !== 'nilu') return `${found.id}: a nilu-cli block must start with nilu`;
    result = run(options.nilu, words.slice(1), directory, stdin);
  } else {
    if (!options.zig || !options.include || !options.library) return `${found.id}: a nilu-c block needs --zig, --include and --library`;
    const source = join(directory, 'example.c');
    const executable = join(directory, 'example');
    writeFileSync(source, found.source + '\n');
    const compile = run(options.zig, ['cc', '-std=c99', '-Wall', '-Wextra', '-I', options.include, source, options.library, '-lm', '-o', executable], directory, '');
    if (compile.status !== 0) return `${found.id}: the C example did not compile:\n${compile.stdout}${compile.stderr}`;
    result = run(executable, [], directory, stdin);
    rmSync(source, { force: true });
    rmSync(executable, { force: true });
  }
  const problems = [];
  const wantedOut = substituteVersion(expectedText(found.output ?? ''));
  if (result.stdout !== wantedOut) problems.push(`stdout\n--- expected\n${wantedOut}--- actual\n${result.stdout}---`);
  const wantedErr = substituteVersion(expectedText(found.stderr ?? ''));
  if (result.stderr !== wantedErr) problems.push(`stderr\n--- expected\n${wantedErr}--- actual\n${result.stderr}---`);
  return problems.length ? `${found.id}: ${problems.join('\n')}` : null;
}

function runRefused(row, directory) {
  const path = join(directory, '<manual>');
  writeFileSync(path, row.source + '\n');
  const result = run(options.nilu, ['<manual>'], directory, '');
  rmSync(path, { force: true });
  if (result.status === 0 || !/^nilu: <manual>:\d+:\d+: /.test(result.stderr)) {
    return `${row.id}: ${JSON.stringify(row.source)} was not refused as a syntax error:\n${result.stdout}${result.stderr}`;
  }
  return null;
}

function main() {
  const chapters = [];
  for (const language of ['en', 'ja']) {
    const directory = join(options.root, 'doc', language);
    if (!existsSync(directory)) continue;
    for (const name of readdirSync(directory).filter(file => file.endsWith('.md')).sort()) {
      chapters.push({ chapter: `${language}/${name}`, text: readFileSync(join(directory, name), 'utf8') });
    }
  }
  let cases = [];
  let rows = [];
  let unsettled = 0;
  for (const { chapter, text } of chapters) {
    cases.push(...examples(text, chapter));
    if (basename(chapter).startsWith('13-')) {
      const refused = refusedRows(text, chapter);
      rows.push(...refused.rows);
      unsettled += refused.unsettled;
    }
  }
  if (!cases.length && !rows.length) throw new Error('manual-check: no example blocks found; nothing can be confirmed');
  if (options.only) {
    const matches = entry => entry.id === options.only || entry.chapter === options.only || entry.chapter.endsWith(`/${options.only}`);
    cases = cases.filter(matches);
    rows = rows.filter(matches);
    if (!cases.length && !rows.length) throw new Error(`manual-check: nothing named ${JSON.stringify(options.only)}`);
  }
  const counts = language => cases.filter(found => found.chapter.startsWith(`${language}/`)).length;
  if (options.list) {
    console.log(`manual-check: ${cases.length} example blocks (en ${counts('en')}, ja ${counts('ja')}) and ${rows.length} refused rows, none run; ${unsettled} rows cannot be settled by running`);
    for (const found of cases) console.log(`  ${found.id} ${found.kind}`);
    for (const row of rows) console.log(`  ${row.id} refused ${JSON.stringify(row.source)}`);
    return 0;
  }
  const version = run(options.nilu, ['-v'], options.root, '');
  if (version.status !== 0 || !/^nilu \S+\n$/.test(version.stdout)) throw new Error(`manual-check: ${options.nilu} -v did not answer a version`);
  banner = version.stdout;
  console.log(`manual-check: running ${cases.length} example blocks (en ${counts('en')}, ja ${counts('ja')}) and ${rows.length} refused rows; ${unsettled} rows cannot be settled by running`);
  const directory = mkdtempSync(join(tmpdir(), 'nilu-manual-'));
  const failures = [];
  try {
    for (const found of cases) {
      const problem = runCase(found, directory);
      if (problem) failures.push(problem);
    }
    for (const row of rows) {
      const problem = runRefused(row, directory);
      if (problem) failures.push(problem);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
  for (const failure of failures) console.error(`  FAIL ${failure}`);
  console.log(`manual-check: ${cases.length - failures.filter(f => !/was not refused/.test(f)).length} of ${cases.length} example blocks agree; ${rows.length - failures.filter(f => /was not refused/.test(f)).length} of ${rows.length} refused rows are syntax errors`);
  return failures.length ? 1 : 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exit(main());
  } catch (error) {
    console.error(error.message.startsWith('manual-check') ? error.message : `manual-check: ${error.message}`);
    process.exit(1);
  }
}
