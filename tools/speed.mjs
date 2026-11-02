// Compares the speed of builds on the scripts in bench/, in cycles counted by
// `perf stat` (user space only). Each set is one version of the code, built in
// one or more layouts (tools/README.md, "Measuring speed"); the runs are
// interleaved, every set in one layout after another, so that the machine's
// load falls on all of them alike. A difference that holds in one layout and
// not in another is the layout's, not the code's, so the ratio is reported per
// layout. Every build must print what the first one prints for each script.
//
// Where the data lands matters too: the size of the environment moves the
// stack, and with it which stores and loads share their low twelve address
// bits, which the processor takes for a collision. The same build has counted
// from 1M to 19M such stalls on one script as the environment grew in steps of
// 256 bytes. So every program runs with only PATH and a padding
// variable, padded by another amount on each pass (the same for every build in
// that pass), unless --pad fixes it.
//
//   node tools/speed.mjs [--runs=N] [--cpu=K] [--pad=B] [--only=a,b] [--list] <set>=<build>[,<build>...]...
//
// A build is a --prefix directory holding bin/nilu, or a program (lua5.5) to
// compare with. Every set has the same number of builds; the n-th build of
// each set is in the same layout. Reads files and runs programs only.
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const bench = path.join(root, 'bench');
const scripts = readdirSync(bench).filter(name => name.endsWith('.nilu')).map(name => name.slice(0, -5)).sort();

const options = { runs: 7, cpu: '2', pad: null, only: null, list: false };
const sets = [];
for (const argument of process.argv.slice(2)) {
  let match;
  if ((match = /^--runs=(\d+)$/.exec(argument))) options.runs = Number(match[1]);
  else if ((match = /^--cpu=(\d+)$/.exec(argument))) options.cpu = match[1];
  else if ((match = /^--pad=(\d+)$/.exec(argument))) options.pad = Number(match[1]);
  else if ((match = /^--only=(.+)$/.exec(argument))) options.only = match[1].split(',');
  else if (argument === '--list') options.list = true;
  else if ((match = /^([^=]+)=(.+)$/.exec(argument))) sets.push({ name: match[1], builds: match[2].split(',').map(program) });
  else fail(`speed: unknown argument ${argument}; use --runs=N, --cpu=K, --pad=B, --only=a,b, --list or <set>=<build>[,<build>...]`);
}

if (options.list) {
  for (const script of scripts) console.log(script);
  process.exit(0);
}
const chosen = options.only ?? scripts;
for (const name of chosen) if (!scripts.includes(name)) fail(`speed: there is no bench/${name}.nilu; --list names them`);
if (sets.length === 0) fail('speed: name at least one set, as <set>=<build>[,<build>...]');
const layouts = sets[0].builds.length;
if (sets.some(set => set.builds.length !== layouts)) fail('speed: every set needs the same number of builds, one per layout');
if (options.runs < 1) fail('speed: --runs must be at least 1');

const padding = options.pad === null ? 'environment padded anew each pass' : `environment padded by ${options.pad} bytes`;
console.log(`speed: ${chosen.length} of ${scripts.length} scripts, ${sets.length} sets x ${layouts} layouts, ${options.runs} runs each, on cpu ${options.cpu}, address randomization off, ${padding}; Mcycles (user)`);
console.log(`load average at the start: ${loadAverage()}`);

function fail(message) {
  console.error(message);
  process.exit(1);
}

function program(build) {
  const inPrefix = path.resolve(build, 'bin', 'nilu');
  if (existsSync(inPrefix)) return { label: build, file: inPrefix };
  const resolved = spawnSync('sh', ['-c', 'command -v "$1"', 'sh', build], { encoding: 'utf8' }).stdout.trim();
  if (resolved && existsSync(resolved) && statSync(resolved).isFile()) return { label: build, file: resolved };
  fail(`speed: ${build} is neither a prefix with bin/nilu nor a program`);
}

function loadAverage() {
  try {
    return readFileSync('/proc/loadavg', 'utf8').split(' ').slice(0, 3).join(' ');
  } catch {
    return 'not read';
  }
}

// Multiples of 16, since the stack starts 16-byte aligned, spread over 4096.
function padFor(pass) {
  return options.pad ?? (pass * 1552) % 4096;
}

function run(build, script, pass) {
  const result = spawnSync('setarch', ['-R', 'perf', 'stat', '-x,', '-e', 'cycles:u', 'taskset', '-c', options.cpu, build.file, `${script}.nilu`], {
    cwd: bench,
    env: { PATH: process.env.PATH ?? '/usr/bin:/bin', NILU_SPEED_PAD: 'x'.repeat(padFor(pass)) },
    encoding: 'utf8',
    timeout: 600000,
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error) fail(`speed: ${build.label} on ${script}: ${result.error.message}`);
  if (result.status !== 0) fail(`speed: ${build.label} on ${script} exited with ${result.status}:\n${result.stderr}`);
  const line = result.stderr.split('\n').find(text => text.includes('cycles'));
  const count = line ? Number(line.split(',')[0]) : NaN;
  // perf prints "<not counted>" or "<not supported>" when it cannot count.
  if (!Number.isFinite(count)) fail(`speed: perf did not count cycles for ${build.label} on ${script}:\n${result.stderr}`);
  return { cycles: count, output: result.stdout };
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = sorted.length >> 1;
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

const mega = value => (value / 1e6).toFixed(1);
const width = Math.max(8, ...sets.map(set => set.name.length + 2));
const header = ['script'.padEnd(10), ...sets.map(set => set.name.padStart(width))];
for (const set of sets.slice(1)) header.push(`${set.name}/${sets[0].name}`.padStart(26).padEnd(32));
console.log(header.join(' '));

for (const script of chosen) {
  // cycles[set][layout] = one count per run
  const cycles = sets.map(() => Array.from({ length: layouts }, () => []));
  let expected = null;
  for (let pass = 0; pass < options.runs; pass += 1) {
    for (let layout = 0; layout < layouts; layout += 1) {
      for (let index = 0; index < sets.length; index += 1) {
        const build = sets[index].builds[layout];
        const answer = run(build, script, pass);
        if (expected === null) expected = { output: answer.output, label: build.label };
        else if (answer.output !== expected.output) fail(`speed: ${build.label} printed something else on ${script} than ${expected.label}:\n${answer.output}\n--- against ---\n${expected.output}`);
        cycles[index][layout].push(answer.cycles);
      }
    }
  }
  const perLayout = cycles.map(set => set.map(median));
  const row = [script.padEnd(10), ...perLayout.map(medians => mega(median(medians)).padStart(width))];
  for (let index = 1; index < sets.length; index += 1) {
    const ratios = perLayout[index].map((value, layout) => value / perLayout[0][layout]);
    const low = Math.min(...ratios);
    const high = Math.max(...ratios);
    // Both sides of 1 means the layouts disagree about which is faster.
    const verdict = low < 1 && high > 1 ? ' mixed' : '';
    row.push(`${median(ratios).toFixed(3)} [${low.toFixed(3)}..${high.toFixed(3)}]${verdict.padEnd(6)}`.padStart(32));
  }
  console.log(row.join(' '));
}
console.log(`speed: ${chosen.length} of ${scripts.length} scripts measured; each figure is the median over layouts of each layout's median; [..] is the range of the per-layout ratios`);
