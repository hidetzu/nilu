export function runChecks(name, cases, args = process.argv.slice(2)) {
  const invalid = args.filter(argument => argument !== '--list' && !argument.startsWith('--only='));
  const filters = args.filter(argument => argument.startsWith('--only='));
  if (invalid.length || filters.length > 1 || filters.some(argument => argument === '--only=')) {
    console.error(`${name}: invalid arguments; use --list or --only=<case>`);
    process.exitCode = 1;
    return;
  }
  if (args.includes('--list')) {
    console.log(`${name}: ${cases.length} cases, none run`);
    for (const entry of cases) console.log(`  ${entry.name}`);
    return;
  }
  const only = filters[0]?.slice('--only='.length);
  const selected = only ? cases.filter(entry => entry.name === only) : cases;
  console.log(`${name}: running ${selected.length} of ${cases.length} cases${only ? ` (--only=${only})` : ''}`);
  if (!selected.length) {
    console.error(`${name}: no case named ${JSON.stringify(only)}; use --list`);
    process.exitCode = 1;
    return;
  }
  let failed = 0;
  for (const entry of selected) {
    try {
      console.log(`  ok ${entry.name}: ${entry.run()}`);
    } catch (error) {
      failed++;
      console.error(`  FAIL ${entry.name}: ${error.message}`);
    }
  }
  console.log(`${name}: ${selected.length - failed} of ${selected.length} cases passed`);
  if (failed) process.exitCode = 1;
}
