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
// Carried cases that set up a condition only Linux provides (the owner's
// answer on hidetzu/nilu#8). Elsewhere the harness cannot make that condition,
// so what such a case reports there says nothing about the command: it is
// announced as not run, never counted as passed. Any other failure fails.
const linuxOnly = {
  'a failed flush says its errno': '/dev/full',
  'running out of memory says so': 'setrlimit(RLIMIT_AS)',
  'a count that cannot be read says which way': 'setrlimit(RLIMIT_AS)',
};
const failedCases = [...result.stdout.matchAll(/^  FAIL (.+?) - /gm)].map(match => match[1]);
const notRun = process.platform === 'linux' ? [] : failedCases.filter(name => name in linuxOnly);
const realFailures = failedCases.filter(name => !notRun.includes(name));
assert.ok(result.status === 0 || (failedCases.length > 0 && realFailures.length === 0), 'the command cases did not pass');
if (!forwarded.includes('--list')) {
  const announced = /cli: running (\d+) of (\d+) cases/.exec(result.stdout);
  assert.ok(announced, 'the harness did not announce its count');
  const passed = Number(announced[1]) - notRun.length;
  if (notRun.length === 0) assert.match(result.stdout, new RegExp(`cli: ${announced[1]} of ${announced[1]} cases passed`), 'not every announced case passed');
  else assert.match(result.stdout, new RegExp(`cli: ${notRun.length} of ${announced[1]} cases failed`), 'the harness failed other cases than the ones not run here');
  console.log(`cli-test: ${passed} of ${announced[2]} carried command cases passed`);
  for (const name of notRun) console.log(`NOT-RUN: ${name}: needs ${linuxOnly[name]}, which ${process.platform} does not provide`);
}
