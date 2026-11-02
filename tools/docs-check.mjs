import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, isAbsolute, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runChecks } from './check-runner.mjs';
import { cCode, markdownShape, sha256 } from './reference-content.mjs';

const argumentsGiven = process.argv.slice(2);
const roots = argumentsGiven.filter(argument => argument.startsWith('--root='));
if (roots.length > 1 || roots.some(argument => argument === '--root=')) {
  console.error('docs-check: provide at most one nonempty --root=<directory>');
  process.exit(1);
}
const root = roots.length
  ? resolve(roots[0].slice('--root='.length))
  : resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = name => readFileSync(resolve(root, name), 'utf8');
const manifest = () => JSON.parse(read('tools/references.json'));
const inside = target => {
  const name = relative(root, target);
  return name !== '..' && !name.startsWith('../') && !isAbsolute(name);
};
// .claude/worktrees holds other checkouts of this repository made by agents;
// their files are those checkouts', not this tree's.
const markdownFiles = (directory = root) => readdirSync(directory, { withFileTypes: true })
  .filter(entry => !['.git', '.zig-cache', 'zig-out', 'node_modules', 'tmp', 'worktrees'].includes(entry.name))
  .flatMap(entry => entry.isDirectory()
    ? markdownFiles(resolve(directory, entry.name))
    : entry.isFile() && entry.name.endsWith('.md') ? [resolve(directory, entry.name)] : [])
  .sort();
const textFiles = (directory = root) => readdirSync(directory, { withFileTypes: true })
  .filter(entry => !['.git', '.zig-cache', 'zig-out', 'node_modules', 'tmp', 'worktrees'].includes(entry.name))
  .flatMap(entry => entry.isDirectory()
    ? textFiles(resolve(directory, entry.name))
    : entry.isFile() && /\.(?:md|zig|c|h|mjs|lua|nilu|json|yml)$/.test(entry.name) ? [relative(root, resolve(directory, entry.name))] : [])
  .sort();
const prose = text => {
  let fence;
  return text.replace(/<!--[\s\S]*?-->/g, '').split('\n').map(line => {
    const marker = /^\s{0,3}(`{3,}|~{3,})/.exec(line)?.[1];
    if (fence) {
      if (marker?.[0] === fence[0] && marker.length >= fence.length && new RegExp(`^\\s{0,3}${marker}\\s*$`).test(line)) fence = undefined;
      return '';
    }
    if (marker) {
      fence = marker;
      return '';
    }
    return line;
  }).join('\n');
};
const anchor = text => decodeURIComponent(text).replace(/[^\p{L}\p{N}]/gu, '').toLowerCase();

const cases = [
  {
    name: 'manual-version',
    run() {
      const definitions = [...cCode(read('include/nilu.h')).matchAll(/^\s*#define\s+NILU_VERSION\s+"([^"\n]+)"\s*$/gm)];
      if (definitions.length !== 1) throw new Error('include/nilu.h: expected one NILU_VERSION string');
      const version = definitions[0][1];
      let banners = 0;
      for (const language of ['en', 'ja']) {
        const front = `doc/${language}/README.md`;
        const sentence = language === 'en'
          ? /This manual describes \*\*Nilu ([^*\n]+)\*\*/g
          : /このマニュアルは \*\*Nilu ([^*\n]+)\*\*/g;
        const named = [...prose(read(front)).matchAll(sentence)];
        if (named.length !== 1 || named[0][1] !== version)
          throw new Error(`${front}: manual version must equal NILU_VERSION ${version}`);
        for (const chapter of readdirSync(resolve(root, `doc/${language}`)).filter(name => name.endsWith('.md'))) {
          const file = `doc/${language}/${chapter}`;
          for (const block of markdownShape(read(file)).blocks.filter(block => block.tag === 'output')) {
            for (const match of block.body.matchAll(/^nilu (\S+)[ \t]*$/gm)) {
              banners++;
              if (match[1] !== version) throw new Error(`${file}: banner ${match[1]} must equal NILU_VERSION ${version}`);
            }
          }
        }
      }
      return `both manuals and ${banners} output banners name NILU_VERSION ${version}`;
    },
  },
  {
    name: 'manual-contracts',
    run() {
      const expected = manifest().manuals;
      const chapters = readdirSync(resolve(root, 'doc/ja')).filter(name => name.endsWith('.md')).sort();
      const english = readdirSync(resolve(root, 'doc/en')).filter(name => name.endsWith('.md')).sort();
      if (!chapters.length || JSON.stringify(chapters) !== JSON.stringify(english)) throw new Error('the two manuals have different chapter sets');
      const names = chapters.flatMap(name => [`doc/ja/${name}`, `doc/en/${name}`]).sort();
      if (JSON.stringify(names) !== JSON.stringify(Object.keys(expected).sort())) throw new Error('manual files differ from the carried inventory');
      let checked = 0;
      for (const name of chapters) {
        const japanese = markdownShape(read(`doc/ja/${name}`));
        const translated = markdownShape(read(`doc/en/${name}`));
        if (JSON.stringify(japanese) !== JSON.stringify(translated)) throw new Error(`${name}: the manuals differ in blocks or heading levels`);
        for (const language of ['ja', 'en']) {
          const file = `doc/${language}/${name}`;
          const shape = language === 'ja' ? japanese : translated;
          if (sha256(JSON.stringify(shape.blocks)) !== expected[file].blocks) throw new Error(`${file}: examples differ from the carried manual`);
          if (sha256(JSON.stringify(shape.headings)) !== expected[file].headings) throw new Error(`${file}: heading structure differs from the carried manual`);
          if (/\bADR\b|\.\.\/adr\//.test(read(file))) throw new Error(`${file}: the manual cites an ADR; it must stand on its own`);
        }
        checked += japanese.blocks.length;
      }
      return `${chapters.length} chapter pairs share ${checked} unchanged fenced blocks and their heading structure`;
    },
  },
  {
    name: 'c-test-contracts',
    run() {
      const expected = manifest().cTests;
      const names = readdirSync(resolve(root, 'test/c')).filter(name => name.endsWith('.c')).map(name => `test/c/${name}`).sort();
      if (!names.length || JSON.stringify(names) !== JSON.stringify(Object.keys(expected).sort())) throw new Error('C cases differ from the carried inventory');
      for (const name of names) {
        const text = read(name);
        if (sha256(cCode(text)) !== expected[name]) throw new Error(`${name}: C content outside comments differs from the carried cases`);
        if (/\bADR\b|\.claude\//.test(text)) throw new Error(`${name}: a carried C case cites this repository's records`);
      }
      return `${names.length} C test files retain every byte outside comments`;
    },
  },
  {
    name: 'links',
    run() {
      const problems = [];
      let checked = 0;
      for (const file of markdownFiles()) {
        const text = prose(readFileSync(file, 'utf8'));
        const targets = [
          ...[...text.matchAll(/\]\(([^)\s]+)\)/g)].map(match => match[1]),
          ...[...text.matchAll(/^\s*\[[^\]]+\]:\s*(\S+)/gm)].map(match => match[1]),
        ];
        for (const target of targets) {
          if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(target)) continue;
          checked++;
          const [pathname, fragment] = target.split('#');
          const resolved = pathname ? resolve(dirname(file), decodeURIComponent(pathname)) : file;
          const origin = `${relative(root, file)} -> ${target}`;
          if (!inside(resolved)) {
            problems.push(`${origin}: outside the repository`);
          } else if (!existsSync(resolved)) {
            problems.push(`${origin}: target does not exist`);
          } else if (fragment && resolved.endsWith('.md')) {
            const headings = [...prose(readFileSync(resolved, 'utf8')).matchAll(/^#{1,6}\s+(.+)$/gm)]
              .map(match => anchor(match[1]));
            if (!headings.includes(anchor(fragment))) problems.push(`${origin}: section does not exist`);
          }
        }
      }
      if (problems.length) throw new Error(problems.join('\n    '));
      return `${checked} links checked, every target present`;
    },
  },
  {
    name: 'design-records',
    run() {
      const records = readdirSync(resolve(root, 'design/adr')).filter(name => name.endsWith('.md'));
      const decisions = new Set(records.map(name => /^(\d{4})-/.exec(name)?.[1]).filter(Boolean));
      const design = ['design/README.md', ...records.map(name => `design/adr/${name}`)];
      const problems = [];
      for (const file of design) {
        if (/⚠|\bv0\.0\.\d|\b(?:since|until|before|after)\s+v?\d+\.\d+\.\d+-dev\.\d+/i.test(read(file))) {
          problems.push(`${file}: historical version mark`);
        }
      }
      // Every file that can cite an ADR, not the design alone: a comment in the
      // source naming a number that does not exist is the same mistake. The
      // captured fixtures keep their bytes and are not read.
      const citing = textFiles().filter(name => !name.startsWith('test/fixtures/'));
      let citations = 0;
      for (const file of citing) {
        for (const match of read(file).matchAll(/\bADR[\s-]+(\d{4})\b|adr\/(\d{4})-/g)) {
          citations++;
          const number = match[1] ?? match[2];
          if (!decisions.has(number)) problems.push(`${file}: unknown ADR ${number}`);
        }
      }
      if (problems.length) throw new Error(problems.join('\n    '));
      return `${citations} ADR citations in ${citing.length} files name one of the ${decisions.size} records`;
    },
  },
  {
    name: 'carried-references',
    run() {
      const references = manifest().verbatim;
      if (!Object.keys(references).length) throw new Error('reference manifest is empty');
      for (const [name, expected] of Object.entries(references)) {
        if (!inside(resolve(root, name))) throw new Error(`${name}: outside the repository`);
        const actual = createHash('sha256').update(readFileSync(resolve(root, name))).digest('hex');
        if (actual !== expected) throw new Error(`${name}: differs from the carried reference`);
      }
      return `${Object.keys(references).length} reference files match their captured SHA-256 digests`;
    },
  },
];

runChecks('docs-check', cases, argumentsGiven.filter(argument => !argument.startsWith('--root=')));
