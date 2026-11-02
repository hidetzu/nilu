// Runs the carried command cases (test/c/cli.c) against the nilu the build
// made. The harness forks the program, so it runs where POSIX is. It announces
// its own count, selects with --only=<name> and lists with --list.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

const [harness, nilu, ...rest] = process.argv.slice(2);
const fixtures = rest.slice(0, 8);
const forwarded = rest.slice(8).filter(argument => argument === '--list' || argument.startsWith('--only='));
assert.ok(harness && nilu && fixtures.length === 8, 'pass the harness, the nilu program and the eight fixture scripts');
if (forwarded.length !== rest.length - 8) {
  console.error('run-cli-cases: use --list or --only=<case name>');
  process.exit(1);
}
const result = spawnSync(harness, [nilu, ...fixtures, ...forwarded], { encoding: 'utf8', timeout: 600000, maxBuffer: 16 * 1024 * 1024 });
if (result.error) throw result.error;
process.stdout.write(result.stdout);
if (result.stderr) process.stderr.write(result.stderr);
assert.equal(result.status, 0, 'the command cases did not pass');
if (!forwarded.includes('--list')) {
  const announced = /cli: running (\d+) of (\d+) cases/.exec(result.stdout);
  assert.ok(announced, 'the harness did not announce its count');
  assert.match(result.stdout, new RegExp(`cli: ${announced[1]} of ${announced[1]} cases passed`), 'not every announced case passed');
  console.log(`cli-test: ${announced[1]} of ${announced[2]} carried command cases passed`);
}
