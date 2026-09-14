const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync, execFileSync } = require('node:child_process');

const workspace = '/Users/davidsair/.no-mistakes/worktrees/2f2b4426b91c/01M2GV838797KXQEJSX6E01A6B';
const evidence = '/Users/davidsair/.no-mistakes/evidence/01M2GV838797KXQEJSX6E01A6B';
const baseCommit = '3e03587515ceadee6f4e9ea621ae2cb90c4c9d41';
const targetCommit = '7927f5c416bfacd56d48cdfb502d4aabb95e24fb';
assert.equal(process.cwd(), workspace);
assert.equal(execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(), targetCommit);
const baseline = process.argv.includes('--baseline');
const only = process.argv.find(arg => arg.startsWith('--only='))?.slice(7);
const original = JSON.parse(fs.readFileSync(path.join(workspace, 'docs/examples/crew-dispatch.json'), 'utf8'));
const cases = [];
const add = (id, scenario, edit, expected = null, baseError = null, verbose = true) => {
  const input = structuredClone(original);
  edit(input);
  cases.push({ id, scenario, input, expected, baseError, verbose });
};
const ordinary = (model, harness = 'cursor', id = model) => ({ id, harness, model, model_class: 'ordinary' });
const fleet = [ordinary('gpt-5.6-sol-xhigh'), ordinary('grok-4.6', 'grok'), ordinary('cursor-grok-4.6-high-fast'), ordinary('composer-2.5')];
add('published-example', 'existing-policy', () => {});
add('published-example-quiet', 'existing-policy', () => {}, null, null, false);
for (const profile of fleet) {
  add(`accept-${profile.id}`, 'new-models', config => {
    config.rules[0].use = [profile];
    config.default = [profile];
  }, null, `v2 unclassified model: ${profile.model}`);
  add(`refuse-typo-${profile.id}`, 'model-boundary', config => {
    config.rules[0].use = [{ ...profile, model: `${profile.model}-typo` }];
  }, `v2 unclassified model: ${profile.model}-typo`);
}
add('qualified-new-model', 'new-models', config => {
  config.rules[0].use = [ordinary('openai/gpt-5.6-sol-xhigh', 'pi', 'qualified-sol')];
  config.default = [ordinary('openai/gpt-5.6-sol-xhigh', 'pi', 'qualified-sol')];
});
add('unknown-default-model', 'model-boundary', config => { config.default[0].model = 'unclassified-model'; }, 'v2 unclassified model: unclassified-model');
add('automatic-default-model', 'model-boundary', config => { config.default[0].model = 'auto'; }, 'v2 unclassified model: auto');
add('ordinary-model-misclassified', 'model-boundary', config => {
  config.rules[0].use = [{ ...fleet[0], model_class: 'astra' }];
}, 'v2 profile.model_class does not match model: gpt-5.6-sol-xhigh');
add('new-model-invalid-effort', 'model-boundary', config => {
  config.rules[0].use = [{ ...fleet[3], effort: 'high' }];
}, 'v2 invalid effort: cursor:high');
add('new-model-unverified-harness', 'model-boundary', config => {
  config.rules[0].use = [{ ...fleet[3], harness: 'spaceship' }];
}, 'v2 unverified harness: spaceship');
add('fallback-without-match', 'fallback', config => {
  config.rules.push({ id: 'fallback', when: 'All remaining work after earlier rules have been considered.', reasoning: { mode: 'generic' }, use: structuredClone(config.default) });
}, null, 'v2 rule missing required key: match');
add('combined-fallback-with-fleet-order', 'fallback', config => {
  config.rules.push({ id: 'fallback', when: 'Keep this exact fallback text: punctuation, spacing, and precedence.', reasoning: { mode: 'generic' }, use: fleet });
  config.default = fleet;
});
for (const [label, value] of [['null', null], ['empty-object', {}], ['array', []], ['string', 'all'], ['number', 1]]) {
  add(`invalid-match-${label}`, 'match-boundary', config => { config.rules[0].match = value; }, value && !Array.isArray(value) && typeof value === 'object' ? 'v2 rule match needs at least one field' : 'v2 rule match must be an object');
}
add('fallback-missing-reasoning', 'match-boundary', config => {
  delete config.rules[0].match;
  delete config.rules[0].reasoning;
}, 'v2 rule missing required key: reasoning');
add('fallback-missing-use', 'match-boundary', config => {
  delete config.rules[0].match;
  delete config.rules[0].use;
}, 'v2 rule missing required key: use');
add('unknown-match-field', 'match-boundary', config => { config.rules[0].match.hosts = ['dev-host']; }, 'v2 rule match has unknown field: hosts');
add('host-only-rule', 'host', config => { config.rules[0].match = { host: 'dev-host' }; }, null, 'v2 rule match has unknown field: host');
add('host-combined-with-existing-fields', 'host', config => {
  config.rules[0].match = { host: 'dev-host', task_kind: ['review'], task_shape: ['large'], delivery: 'no-mistakes', project: 'dbeihl-utilicast/firstmate' };
});
for (const [label, value] of [['empty', ''], ['null', null], ['array', ['dev-host']], ['number', 1], ['boolean', true], ['object', { name: 'dev-host' }]]) {
  add(`invalid-host-${label}`, 'host-boundary', config => { config.rules[0].match.host = value; }, 'v2 rule match.host must be a non-empty string');
}
add('host-outside-match', 'host-boundary', config => { config.rules[0].host = 'dev-host'; }, 'v2 rule has unknown field: host');
add('host-in-profile', 'host-boundary', config => { config.rules[0].use[0].host = 'dev-host'; }, 'v2 profile has unknown field: host');
add('host-at-top-level', 'host-boundary', config => { config.host = 'dev-host'; }, 'v2 top-level has unknown field: host');
add('host-in-placement-match', 'host-boundary', config => { config.placement.rules[0].match.host = 'dev-host'; }, 'v2 placement rule match has unknown field: host');
for (const profile of [
  { id: 'astra', harness: 'codex', model: 'gpt-6-astra', model_class: 'astra' },
  { id: 'fable', harness: 'claude', model: 'fable', model_class: 'fable' },
]) {
  const refusal = `v2 top-tier model class ${profile.model_class} requires rule match.project Utilicast-LLC/utilicast-triage`;
  add(`${profile.id}-triage-and-host`, 'triage-boundary', config => {
    config.rules[0].use = [profile];
    config.rules[0].match = { project: 'Utilicast-LLC/utilicast-triage', host: 'dev-host' };
  });
  add(`${profile.id}-absent-match`, 'triage-boundary', config => {
    config.rules[0].use = [profile];
    delete config.rules[0].match;
  }, refusal);
  add(`${profile.id}-host-without-project`, 'triage-boundary', config => {
    config.rules[0].use = [profile];
    config.rules[0].match = { host: 'dev-host' };
  }, refusal);
  add(`${profile.id}-wrong-project`, 'triage-boundary', config => {
    config.rules[0].use = [profile];
    config.rules[0].match = { host: 'dev-host', project: 'Utilicast-LLC/utilicast-management-portal' };
  }, refusal);
  add(`${profile.id}-default`, 'triage-boundary', config => { config.default = [profile]; }, `v2 top-tier model class ${profile.model_class} cannot appear in default`);
  add(`${profile.id}-misclassified`, 'triage-boundary', config => {
    config.rules[0].use = [{ ...profile, model_class: 'ordinary' }];
    delete config.rules[0].match;
  }, `v2 profile.model_class does not match model: ${profile.model}`);
  const qualifiedModel = profile.id === 'astra' ? 'codex-native/gpt-6-astra' : 'anthropic/fable';
  add(`${profile.id}-qualified-absent-match`, 'triage-boundary', config => {
    config.rules[0].use = [{ ...profile, harness: 'pi', model: qualifiedModel }];
    delete config.rules[0].match;
  }, refusal);
}

const selected = cases.filter(test => (!baseline || test.baseError) && (!only || test.id === only));
assert(selected.length > 0);
const scratch = fs.mkdtempSync(path.join(workspace, '.crew-dispatch-live-'));
const runName = `${baseline ? 'base' : 'target'}${only ? `-${only}` : ''}`;
const transcriptPath = path.join(evidence, `${runName}-bootstrap.log`);
const results = [];
try {
  let script = path.join(workspace, 'bin/fm-bootstrap.sh');
  if (baseline) {
    const baseRoot = path.join(scratch, 'base');
    fs.mkdirSync(baseRoot);
    execFileSync('git', ['archive', '--format=tar', `--output=${path.join(scratch, 'base.tar')}`, baseCommit, 'bin']);
    execFileSync('tar', ['-xf', path.join(scratch, 'base.tar'), '-C', baseRoot]);
    script = path.join(baseRoot, 'bin/fm-bootstrap.sh');
  }
  const instance = path.join(scratch, 'home');
  for (const directory of ['config', 'data', 'state', 'projects']) fs.mkdirSync(path.join(instance, directory), { recursive: true });
  fs.writeFileSync(path.join(instance, 'config/backlog-backend'), 'manual\n');
  const configPath = path.join(instance, 'config/crew-dispatch.json');
  const envFlags = {
    FM_HOME: instance, FM_ROOT_OVERRIDE: instance,
    FM_CONFIG_OVERRIDE: path.join(instance, 'config'), FM_DATA_OVERRIDE: path.join(instance, 'data'),
    FM_STATE_OVERRIDE: path.join(instance, 'state'), FM_PROJECTS_OVERRIDE: path.join(instance, 'projects'),
    FM_BACKEND: 'tmux', FM_BOOTSTRAP_DETECT_ONLY: '1', FM_BOOTSTRAP_NETWORK: 'skip', FM_TIMING_LOG: '',
  };
  fs.writeFileSync(transcriptPath, `Real bootstrap CLI; ${baseline ? baseCommit : targetCommit}; ${new Date().toISOString()}\nNo tool stubs. Inputs are synthetic policies consumed by the real validator. No model launch or routing execution is claimed.\n`);
  for (const test of selected) {
    const inputBytes = JSON.stringify(test.input, null, 2) + '\n';
    fs.writeFileSync(configPath, inputBytes);
    const flags = { ...envFlags, FM_BOOTSTRAP_VERBOSE_FACTS: test.verbose ? '1' : '0' };
    const result = spawnSync('/bin/bash', [script], { cwd: instance, env: { ...process.env, ...flags }, encoding: 'utf8', timeout: 30000 });
    const stdout = result.stdout || '';
    const stderr = result.stderr || '';
    const expected = baseline ? test.baseError : test.expected;
    const diagnostics = stdout.split('\n').filter(line => line.startsWith('CREW_DISPATCH:'));
    const facts = stdout.split('\n').filter(line => line.startsWith('BOOTSTRAP_INFO: crew dispatch'));
    const checks = [];
    if (result.status !== 0 || result.error) checks.push(`Bootstrap failed: ${result.status} ${result.error || ''}`);
    if (stderr) checks.push(`Unexpected stderr: ${stderr}`);
    if (fs.readFileSync(configPath, 'utf8') !== inputBytes) checks.push('Configuration bytes changed');
    if (expected) {
      if (JSON.stringify(diagnostics) !== JSON.stringify([`CREW_DISPATCH: invalid config/crew-dispatch.json - ${expected}`])) checks.push('Expected exact refusal diagnostic');
      if (facts.length) checks.push('Invalid policy was reported active');
    } else {
      if (diagnostics.length) checks.push('Valid policy was refused');
      const profile = value => value.harness + '/' + value.model + (value.effort ? '/' + value.effort : '');
      const expectedFacts = test.verbose ? [
        'BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json',
        ...test.input.rules.map(rule => `BOOTSTRAP_INFO: crew dispatch rule: ${rule.when} -> quota-balanced[${rule.use.map(profile).join(', ')}]`),
        `BOOTSTRAP_INFO: crew dispatch default: quota-balanced[${test.input.default.map(profile).join(', ')}]`,
      ] : [];
      if (JSON.stringify(facts) !== JSON.stringify(expectedFacts)) checks.push('Active facts did not preserve rule text, rule order, profile order, and default');
    }
    const command = Object.entries(flags).map(([key, value]) => `${key}=${JSON.stringify(value)}`).join(' ') + ` /bin/bash ${JSON.stringify(script)}`;
    const record = { id: test.id, scenario: test.scenario, input: test.input, command, exitCode: result.status, stdout, stderr, expectedDiagnostic: expected, inputUnchanged: fs.readFileSync(configPath, 'utf8') === inputBytes, result: checks.length ? 'fail' : 'pass', failures: checks };
    results.push(record);
    fs.appendFileSync(transcriptPath, `\n## ${test.id}\n$ ${command}\n${stdout}${stderr ? `STDERR:\n${stderr}` : ''}exit_code=${result.status}; input_unchanged=${record.inputUnchanged}; observed_result=${record.result}\n${checks.join('\n')}\n`);
    console.log(`${record.result.toUpperCase()}: ${test.id}${checks.length ? ': ' + checks.join('; ') : ''}`);
    fs.writeFileSync(path.join(evidence, `${runName}-results.json`), JSON.stringify({ commit: baseline ? baseCommit : targetCommit, mode: baseline ? 'pre-fix reproduction' : 'live current product', results }, null, 2) + '\n');
  }
} finally {
  fs.rmSync(scratch, { recursive: true });
}
if (results.some(result => result.result !== 'pass')) process.exitCode = 1;
