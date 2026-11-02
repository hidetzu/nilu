// Runs the nilu command's reader (ADR 0003, manual 11.6) against files it
// writes into a fresh directory: where `require` looks, what `dofile` and
// `loadfile` open, and what a program reads when nothing is found.
// usage: node tools/module-cases.mjs <nilu> [--list] [--only=<case>]
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { runChecks } from './check-runner.mjs';

const [nilu, ...rest] = process.argv.slice(2);
if (!nilu || nilu.startsWith('--')) {
  console.error('module-cases: pass the nilu program first');
  process.exit(1);
}
const program = resolve(nilu);

/// Writes `files` under a fresh directory, runs nilu with `args` from `cwd`
/// (relative to it), and answers stdout, stderr and the exit status.
const scene = (files, args, cwd = '.') => {
  const root = mkdtempSync(join(tmpdir(), 'nilu-modules-'));
  try {
    for (const [name, text] of Object.entries(files)) {
      mkdirSync(dirname(join(root, name)), { recursive: true });
      writeFileSync(join(root, name), text);
    }
    mkdirSync(join(root, cwd), { recursive: true });
    const result = spawnSync(program, args, { cwd: join(root, cwd), encoding: 'utf8', timeout: 60000 });
    if (result.error) throw result.error;
    return { out: result.stdout, err: result.stderr, status: result.status };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
};

const cases = [
  {
    name: 'next-to-the-asking-file',
    run() {
      const { out, status } = scene({
        'main.nilu': 'print((require("sub.helper")))\n',
        'sub/helper.nilu': 'return "helper got " .. require("near")\n',
        'sub/near.nilu': 'return "sub/near.nilu"\n',
        'near.nilu': 'return "the top one"\n',
      }, ['main.nilu']);
      assert.equal(status, 0);
      assert.equal(out, 'helper got sub/near.nilu\n');
      return 'a module inside sub/ finds its neighbour before the top one';
    },
  },
  {
    name: 'next-to-the-script-from-elsewhere',
    run() {
      const { out, status } = scene({
        'proj/main.nilu': 'local value, key = require("util") print(value, key)\n',
        'proj/util.nilu': 'return "util"\n',
        'util.nilu': 'return "the current directory"\n',
      }, ['proj/main.nilu']);
      assert.equal(status, 0);
      assert.equal(out, 'util\tproj/util.nilu\n');
      return 'started from another directory, a module is found next to the script and keyed by its path';
    },
  },
  {
    name: 'without-a-script-the-current-directory',
    run() {
      const { out, status } = scene({ 'util.nilu': 'return "here"\n' }, ['-e', 'print((require("util")))']);
      assert.equal(status, 0);
      assert.equal(out, 'here\n');
      return '-e looks in the current directory';
    },
  },
  {
    name: 'not-found-names-every-place-tried',
    run() {
      const { err, status } = scene({ 'sub/a.nilu': 'require("gone")\n', 'main.nilu': 'require("sub.a")\n' }, ['main.nilu']);
      assert.equal(status, 1);
      assert.match(err, /^nilu: sub\/a\.nilu:1: cannot find module 'gone': no file 'sub\/gone\.nilu'; no file 'gone\.nilu'\n/);
      return 'the reason lists both places';
    },
  },
  {
    name: 'a-cycle-is-refused',
    run() {
      const { err, status } = scene({ 'a.nilu': 'require("b")\n', 'b.nilu': 'require("a")\n' }, ['a.nilu']);
      assert.equal(status, 1);
      // The script the command started is not itself a module, so its own
      // name is loaded once more as one before the cycle closes.
      assert.match(err, /^nilu: a\.nilu:1: cannot load module 'b' while it is loading \(b\.nilu -> a\.nilu -> b\.nilu\)\n/);
      return 'the links of the cycle are named';
    },
  },
  {
    name: 'dofile-and-loadfile-use-the-path-as-written',
    run() {
      const { out, status } = scene({
        'lib/run.nilu': 'return "ran", x\n',
        'main.nilu': [
          'print(dofile("lib/run.nilu"))',
          'print(loadfile("lib/run.nilu", "t", {x = 1})())',
          'print(loadfile("lib/none.nilu"))',
          'print(pcall(dofile, "lib/none.nilu"))',
        ].join('\n') + '\n',
      }, ['main.nilu']);
      assert.equal(status, 0);
      assert.equal(out, [
        'ran\tnil',
        'ran\t1',
        "nil\tcannot find file 'lib/none.nilu': no file 'lib/none.nilu'",
        "false\tcannot find file 'lib/none.nilu': no file 'lib/none.nilu'",
      ].join('\n') + '\n');
      return 'paths are relative to the current directory, as Lua\'s';
    },
  },
  {
    name: 'a-module-cannot-hold-a-zero-byte',
    run() {
      const { err, status } = scene({ 'z.nilu': 'return 1\0', 'main.nilu': 'require("z")\n' }, ['main.nilu']);
      assert.equal(status, 1);
      assert.match(err, /z\.nilu: a zero byte, which a source may not contain/);
      return 'a zero byte is refused as the command refuses it in a script';
    },
  },
];

runChecks('module-cases', cases, rest);
