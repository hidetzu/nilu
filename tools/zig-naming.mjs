import { readFileSync, readdirSync } from 'node:fs';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { runChecks } from './check-runner.mjs';

// Preserve offsets/newlines while removing text that cannot declare a symbol.
function codeOnly(source, zig = false) {
  if (zig) source = source.split('\n').map(line => /^\s*\\\\/.test(line) ? ' '.repeat(line.length) : line).join('\n');
  let result = '', i = 0;
  while (i < source.length) {
    if (source.startsWith('//', i)) {
      while (i < source.length && source[i] !== '\n') { result += ' '; i++; }
    } else if (source.startsWith('/*', i)) {
      result += '  '; i += 2;
      let depth = 1;
      while (i < source.length && depth) {
        if (source.startsWith('/*', i)) { depth++; result += '  '; i += 2; }
        else if (source.startsWith('*/', i)) { depth--; result += '  '; i += 2; }
        else { result += source[i] === '\n' ? '\n' : ' '; i++; }
      }
      if (depth) throw new Error('unterminated comment');
    } else if (source[i] === '"' || source[i] === "'") {
      const quote = source[i++]; result += ' ';
      let closed = false;
      while (i < source.length) {
        const ch = source[i++]; result += ch === '\n' ? '\n' : ' ';
        if (ch === '\\' && i < source.length) { result += source[i++] === '\n' ? '\n' : ' '; }
        else if (ch === quote) { closed = true; break; }
      }
      if (!closed) throw new Error('unterminated literal');
    } else result += source[i++];
  }
  return result;
}

// Mechanical half of AGENTS.md "Zig naming". It reads declarations, not types: whether a
// `const` holds a type is not visible without the compiler, so a const may be TitleCase or
// snake_case but never camelCase. The parts that need semantics stay a review topic.
const title = /^[A-Z][A-Za-z0-9]*$/;
const snake = /^[a-z][a-z0-9_]*$/;
const camel = /^[a-z][A-Za-z0-9]*$/;
// An uppercase run not followed by lowercase is an acronym spelled in capitals (`AST`,
// `VMState`); `CClosure` passes because its second capital starts the word `Closure`.
const acronym = /[A-Z]{2,}(?![a-z])/;
// The C ABI keeps its own spelling (`nilu_*`, `NILU_*`).
const cName = /^(nilu_|NILU_)/;
const keywords = new Set(['const', 'var', 'fn', 'pub', 'test', 'comptime', 'usingnamespace', 'extern', 'export',
  'inline', 'noinline', 'threadlocal', 'struct', 'enum', 'union', 'opaque', 'error', 'return', 'if', 'else',
  'while', 'for', 'switch', 'try', 'catch', 'orelse', 'and', 'or', 'defer', 'errdefer', 'break', 'continue']);

function tokens(code) {
  return [...code.matchAll(/[A-Za-z_][A-Za-z0-9_]*|\S/g)].map(match => ({ text: match[0], at: match.index }));
}

function matching(list, index) {
  const open = list[index].text, close = { '(': ')', '{': '}', '[': ']' }[open];
  let depth = 0;
  for (let i = index; i < list.length; i++) {
    if (list[i].text === open) depth++;
    else if (list[i].text === close && --depth === 0) return i;
  }
  throw new Error(`unbalanced ${open}`);
}

// `pub const isSpace = numeral.isSpace;` keeps the source's name, and a function's name is
// camelCase; the checker cannot see that the source is a function, only that the name is kept.
function reexport(list, index, name) {
  if (list[index]?.text !== '=') return false;
  let j = index + 1;
  while (/^[A-Za-z_]/.test(list[j]?.text ?? '') && list[j + 1]?.text === '.') j += 2;
  return j > index + 1 && list[j]?.text === name && list[j + 1]?.text === ';';
}

const lineOf = (source, at) => source.slice(0, at).split('\n').length;

// Returns the problems in one file and whether its top-level container has instance fields.
export function inspect(source) {
  const code = codeOnly(source, true);
  const list = tokens(code);
  const problems = [];
  const report = (token, message) => problems.push(`line ${lineOf(source, token.at)}: ${message}`);
  const named = (token, what, allowed) => {
    const name = token.text;
    if (name === '_' || cName.test(name)) return;
    if (!allowed.some(pattern => pattern.test(name))) report(token, `${what} ${name} is not ${allowed.map(pattern => pattern === title ? 'TitleCase' : pattern === snake ? 'snake_case' : 'camelCase').join(' or ')}`);
    else if (acronym.test(name)) report(token, `${what} ${name} spells an acronym in capitals; treat it as a word`);
  };
  let topLevelFields = false;
  // frames: 'container' (file, struct, union, opaque), 'enum', 'other'
  const frames = ['container'];
  let start = true, pending, abi = false;
  for (let i = 0; i < list.length; i++) {
    const token = list[i], next = list[i + 1]?.text, frame = frames.at(-1);
    if (token.text === '{') {
      frames.push(pending ?? (list[i - 1]?.text === 'error' ? 'error' : 'other'));
      pending = undefined; start = true; continue;
    }
    if (token.text === '}') { frames.pop(); start = true; continue; }
    if (token.text === ';' || token.text === ',') { start = true; abi = false; continue; }
    if (['struct', 'union', 'opaque'].includes(token.text)) pending = 'container';
    else if (token.text === 'enum') pending ??= 'enum';
    else if (token.text === '(' && pending) { i = matching(list, i); continue; }
    if (token.text === 'extern' || token.text === 'export') abi = true;
    if (start && (frame === 'container' || frame === 'enum') && /^[A-Za-z_]/.test(token.text) && !keywords.has(token.text)) {
      const field = frame === 'container' ? next === ':' : [',', '=', '}'].includes(next);
      if (field) {
        named(token, frame === 'enum' ? 'enum field' : 'field', [snake]);
        if (frames.length === 1) topLevelFields = true;
      }
    }
    if (token.text !== 'pub' && token.text !== 'comptime') start = false;
    if ((token.text === 'const' || token.text === 'var') && /^[A-Za-z_]/.test(next ?? '')) {
      const name = list[i + 1];
      if (abi) continue;
      const init = list.slice(i + 2, i + 8).map(entry => entry.text).join(' ');
      if (/^= @ This \( \) ;/.test(init)) named(name, '@This() alias', [title]);
      // codeOnly blanks the path, so the tokens read `( )`; the path is read from the source.
      else if (/^= @ import \( \) ;/.test(init)) {
        const path = /^\(\s*"([^"]*)"/.exec(source.slice(list[i + 5].at))?.[1] ?? '';
        if (path.endsWith('.zig')) {
          const file = basename(path, '.zig');
          named(name, `import alias of ${path}`, [title.test(file) ? title : snake]);
        } else named(name, `import alias of ${path}`, [snake]);
      } else if (reexport(list, i + 2, name.text)) named(name, 're-export', [snake, title, camel]);
      else named(name, 'constant or variable', [snake, title]);
    }
    if (token.text === 'fn' && /^[A-Za-z_]/.test(next ?? '') && list[i + 2]?.text === '(') {
      const name = list[i + 1];
      const close = matching(list, i + 2);
      let j = close + 1;
      const result = [];
      while (j < list.length && list[j].text !== '{' && list[j].text !== ';') {
        if (list[j].text === 'error' && list[j + 1]?.text === '{') j = matching(list, j + 1);
        else if (list[j].text === '(' || list[j].text === '[') j = matching(list, j);
        else result.push(list[j].text);
        j++;
      }
      if (!abi) named(name, result.join(' ') === 'type' ? 'type function' : 'function', [result.join(' ') === 'type' ? title : camel]);
      for (let k = i + 3; k < close; k++) {
        if (list[k].text === '(' || list[k].text === '[' || list[k].text === '{') { k = matching(list, k); continue; }
        if (list[k + 1]?.text === ':' && /^[A-Za-z_]/.test(list[k].text) && !keywords.has(list[k].text)
          && ['(', ','].includes(list[k - 1].text === 'comptime' || list[k - 1].text === 'noalias' ? list[k - 2].text : list[k - 1].text)) {
          if (list[k].text !== '_') named(list[k], 'parameter', [snake, title]);
        }
      }
      i = close;
    }
  }
  return { problems, topLevelFields };
}

export function checkFile(path, source) {
  const name = basename(path);
  const { problems, topLevelFields } = inspect(source);
  const stem = basename(name, '.zig');
  if (topLevelFields && !title.test(stem)) problems.unshift(`${name} has top-level instance fields, so it is a type and its name is TitleCase.zig`);
  else if (!topLevelFields && !snake.test(stem)) problems.unshift(`${name} has no top-level instance fields, so it is a namespace and its name is snake_case.zig`);
  else if (acronym.test(stem)) problems.unshift(`${name} spells an acronym in capitals; treat it as a word`);
  return problems.map(problem => `${path}: ${problem}`);
}

export function checkDirectory(path) {
  const name = basename(path);
  return snake.test(name) ? [] : [`${path}: directory ${name} is not snake_case`];
}

const skipped = new Set(['.git', '.zig-cache', 'zig-out', 'node_modules', 'tmp']);
// .claude/worktrees holds other checkouts of this repository made by agents;
// their files are those checkouts', not this tree's.
const foreign = (directory, name) => name === 'worktrees' && basename(directory) === '.claude';
function zigFiles(directory) {
  return readdirSync(directory, { withFileTypes: true })
    .filter(entry => !skipped.has(entry.name) && !foreign(directory, entry.name))
    .flatMap(entry => {
      const path = join(directory, entry.name);
      return entry.isDirectory() ? zigFiles(path) : entry.isFile() && entry.name.endsWith('.zig') ? [path] : [];
    }).sort();
}

export function checkTree(root) {
  const files = zigFiles(root);
  if (!files.length) throw new Error('no Zig files found');
  const directories = [...new Set(files.flatMap(file => {
    const parts = relative(root, dirname(file)).split('/').filter(Boolean);
    return parts.map((_, index) => parts.slice(0, index + 1).join('/'));
  }))].sort();
  const problems = [
    ...directories.flatMap(directory => checkDirectory(directory)),
    ...files.flatMap(file => checkFile(relative(root, file), readFileSync(file, 'utf8'))),
  ];
  if (problems.length) throw new Error(`${problems.length} naming problems:\n    ${problems.join('\n    ')}`);
  return { files: files.length, directories: directories.length };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  runChecks('zig-naming', [{ name: 'files-and-declarations', run: () => {
    const { files, directories } = checkTree(root);
    return `${files} Zig files and ${directories} directories follow the mechanical naming rules`;
  } }]);
}
