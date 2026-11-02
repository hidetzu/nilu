// Checks what `zig build dist` wrote and writes SHA256SUMS beside it (ADR 0011).
// Every target directory must hold exactly the four files, the version in the
// directory names must be the header's, and the host's own binary is run with
// -v; a binary for another target is built, not run, and the summary says so.
//   node tools/dist-check.mjs --dist <dir> --version <v> --targets <a,b,c> --host <arch-os>
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
const option = name => {
  const index = args.indexOf(name);
  assert.ok(index !== -1 && args[index + 1] && !args[index + 1].startsWith('--'), `${name} needs a value`);
  return args[index + 1];
};
const dist = option('--dist');
const version = option('--version');
const targets = option('--targets').split(',');
const host = option('--host');
assert.match(version, /^\d+\.\d+\.\d+(-dev\.\d+)?$/, 'the version is not MAJOR.MINOR.PATCH[-dev.N]');
assert.ok(targets.length === 5, 'ADR 0011 names five targets');

const directories = readdirSync(dist).filter(name => name !== 'SHA256SUMS').sort();
const expected = targets.map(target => `nilu-${version}-${target}`).sort();
assert.deepEqual(directories, expected, 'the distribution directories differ from the five targets at this version');

const sums = [];
let ran = null;
for (const target of targets) {
  const directory = `nilu-${version}-${target}`;
  // Windows spells the two artifacts its own way; the header and licence are the same bytes everywhere.
  const windows = target.includes('windows');
  const binary = windows ? 'nilu.exe' : 'nilu';
  const files = readdirSync(join(dist, directory)).sort();
  assert.deepEqual(files, [binary, 'LICENSE', windows ? 'nilu.lib' : 'libnilu.a', 'nilu.h'].sort(), `${directory}: unexpected files`);
  for (const file of files) {
    const bytes = readFileSync(join(dist, directory, file));
    assert.ok(bytes.length > 0, `${directory}/${file} is empty`);
    sums.push(`${createHash('sha256').update(bytes).digest('hex')}  ${directory}/${file}`);
  }
  if (target.startsWith(host)) {
    const result = spawnSync(join(dist, directory, binary), ['-v'], { encoding: 'utf8', timeout: 30000 });
    if (result.error) throw result.error;
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, `nilu ${version}\n`, `${directory}/${binary} -v did not print its version`);
    ran = target;
  }
}
assert.ok(existsSync(join(dist, expected[0])), 'nothing was written');
writeFileSync(join(dist, 'SHA256SUMS'), sums.join('\n') + '\n');
console.log(`dist: ${targets.length} targets built at ${version}; ${sums.length} files hashed into SHA256SUMS; ran ${ran ?? 'none'} (-v); the other ${targets.length - (ran ? 1 : 0)} were built, not run`);
