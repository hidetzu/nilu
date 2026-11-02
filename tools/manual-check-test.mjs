// Exercises the manual checker against small manuals written here: an example
// that agrees, one that does not, selection, listing without running, an empty
// manual, a block that must not run, and a refused row that is accepted.
//   node tools/manual-check-test.mjs --nilu <exe>
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runChecks } from './check-runner.mjs';
import { examples, refusedRows, shellWords } from './manual-check.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const niluArgument = args.indexOf('--nilu');
assert.ok(niluArgument !== -1 && args[niluArgument + 1], 'manual-check-test: --nilu <exe> is required');
const nilu = args[niluArgument + 1];
const forwarded = args.filter((_, index) => index !== niluArgument && index !== niluArgument + 1);

const withManual = (files, run) => {
  const root = mkdtempSync(join(tmpdir(), 'nilu-manual-check-test-'));
  try {
    for (const [name, text] of Object.entries(files)) {
      mkdirSync(dirname(join(root, name)), { recursive: true });
      writeFileSync(join(root, name), text);
    }
    const check = (...extra) => {
      const result = spawnSync(process.execPath, [join(here, 'manual-check.mjs'), '--nilu', nilu, '--root', root, ...extra], { encoding: 'utf8', timeout: 120000 });
      if (result.error) throw result.error;
      return { status: result.status, output: result.stdout + result.stderr };
    };
    return run(check);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
};

const agreeing = '# One\n\n```nilu\nprint(1 + 2)\n```\n```output\n3\n```\n\n```nilu\nerror("x")\n```\n```stderr\nnilu: <manual>:1: x\n```\n\n```nilu-cli\nnilu -e \'print("a", "b")\'\n```\n```output\na\tb\n```\n\n```nilu-source\nthis is not run\n```\n';

const cases = [
  {
    name: 'agreeing-examples-pass',
    run: () => withManual({ 'doc/en/01-one.md': agreeing }, check => {
      const result = check();
      assert.equal(result.status, 0, result.output);
      assert.match(result.output, /manual-check: running 3 example blocks \(en 3, ja 0\)/);
      assert.match(result.output, /3 of 3 example blocks agree/);
      return 'a nilu block, a stderr pair and a nilu-cli line agree, and nilu-source is not counted';
    }),
  },
  {
    name: 'a-mismatch-names-the-line',
    run: () => withManual({ 'doc/en/01-one.md': '# One\n\n```nilu\nprint(1 + 2)\n```\n```output\n4\n```\n' }, check => {
      const result = check();
      assert.notEqual(result.status, 0);
      assert.match(result.output, /FAIL en\/01-one\.md:3: stdout/);
      assert.match(result.output, /0 of 1 example blocks agree/);
      return 'an output that differs fails and names the chapter and line';
    }),
  },
  {
    name: 'selection-and-listing',
    run: () => withManual({ 'doc/en/01-one.md': agreeing }, check => {
      const listed = check('--list');
      assert.equal(listed.status, 0, listed.output);
      assert.match(listed.output, /3 example blocks .* none run/);
      const one = check('--only=en/01-one.md:10');
      assert.equal(one.status, 0, one.output);
      assert.match(one.output, /running 1 example blocks/);
      const none = check('--only=nothing');
      assert.notEqual(none.status, 0);
      assert.match(none.output, /nothing named "nothing"/);
      return 'listing runs nothing, --only runs one, and an unknown name is refused';
    }),
  },
  {
    name: 'an-empty-manual-confirms-nothing',
    run: () => withManual({ 'doc/en/01-one.md': '# Nothing here\n' }, check => {
      const result = check();
      assert.notEqual(result.status, 0);
      assert.match(result.output, /no example blocks found/);
      return 'a manual without examples cannot pass';
    }),
  },
  {
    name: 'refused-rows-must-be-syntax-errors',
    run: () => withManual({ 'doc/en/13-x.md': '# D\n\n## 13.2. What is not there yet\n\n### Language\n\n| What | Needs | What is refused |\n|---|---|---|\n| a | b | `return 1 @ 2` |\n| c | d | — |\n| e | f | `return 1 + 2` |\n' }, check => {
      const result = check();
      assert.notEqual(result.status, 0);
      assert.match(result.output, /2 refused rows; 1 rows cannot be settled/);
      assert.match(result.output, /"return 1 \+ 2" was not refused/);
      assert.match(result.output, /1 of 2 refused rows are syntax errors/);
      return 'an accepted source in the refused table fails and the unsettled row is only counted';
    }),
  },
  {
    name: 'parsers',
    run: () => {
      const found = examples('```nilu\nx\n```\n```stdin\nin\n```\n\n```output\nout\n```\n\nprose\n\n```output\nnot mine\n```\n', 'c');
      assert.equal(found.length, 1);
      assert.deepEqual([found[0].stdin, found[0].output, found[0].stderr], ['in', 'out', null]);
      assert.deepEqual(shellWords("nilu -e 'print(\"a b\")' -e\"x\" plain"), ['nilu', '-e', 'print("a b")', '-ex', 'plain']);
      const rows = refusedRows('## 13.2\n\n### L\n\n| a | b | c |\n|---|---|---|\n| x | y | `z` |\n| x | y | — |\n\n### M\n\n| q |\n|---|\n| `w` |\n', 'd');
      assert.deepEqual(rows.rows.map(row => row.source), ['z']);
      assert.equal(rows.unsettled, 1);
      return 'expectation blocks pair only when adjacent, quotes split as a shell would, and only the first table of 13.2 is read';
    },
  },
];

runChecks('manual-check-test', cases, forwarded);
