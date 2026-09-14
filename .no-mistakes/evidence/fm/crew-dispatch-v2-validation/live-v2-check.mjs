import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';

const root = '/Users/davidsair/.no-mistakes/worktrees/2f2b4426b91c/01M2GFFY8KEP02EXM82B0P5G2X';
const evidence = '/Users/davidsair/.no-mistakes/evidence/01M2GFFY8KEP02EXM82B0P5G2X';
assert.equal(process.cwd(), root);
const example = fs.readFileSync(path.join(root, 'docs/examples/crew-dispatch.json'), 'utf8');
const original = JSON.parse(example);
const runtime = fs.mkdtempSync(path.join(root, '.crew-v2-live.'));
const configDir = path.join(runtime, 'config');
fs.mkdirSync(configDir);
fs.writeFileSync(path.join(configDir, 'backlog-backend'), 'manual\n');
fs.writeFileSync(path.join(configDir, 'backend'), 'tmux\n');
const configFile = path.join(configDir, 'crew-dispatch.json');
const cases = [];
const add = (group, name, change, diagnostic = null) => cases.push({ group, name, change, diagnostic });
const triage = 'Utilicast-LLC/utilicast-triage';
const otherProject = 'Utilicast-LLC/utilicast-management-portal';
const profile = (c, modelClass, qualified = false) => {
  const model = modelClass === 'astra' ? 'gpt-6-astra' : 'fable';
  c.rules[0].use = [{ id: 'top-tier', harness: qualified ? 'pi' : modelClass === 'astra' ? 'codex' : 'claude', model: qualified ? `${modelClass === 'astra' ? 'codex-native' : 'anthropic'}/${model}` : model, model_class: modelClass }];
};
add('copyable-example', 'Copy the shipped V2 example verbatim and list active rules', c => c);
add('obsolete-and-shape', 'Reject legacy V1 object policy', () => ({rules:[{when:'ordinary task',use:{harness:'codex'}}]}), 'missing required key: schema_version');
add('obsolete-and-shape', 'Reject missing schema version', c => { delete c.schema_version; }, 'missing required key: schema_version');
for (const version of [1, 3, '2', [2], null]) add('obsolete-and-shape', `Reject schema version ${JSON.stringify(version)}`, c => { c.schema_version = version; }, 'schema_version must be 2');
add('obsolete-and-shape', 'Reject unknown root key', c => { c.extra = true; }, 'top-level has unknown field: extra');
add('obsolete-and-shape', 'Reject missing required constraints', c => { delete c.constraints; }, 'missing required key: constraints');
add('obsolete-and-shape', 'Reject unknown nested profile field', c => { c.rules[0].use[0].unknown = true; }, 'profile has unknown field: unknown');
add('obsolete-and-shape', 'Reject missing nested placement enforcement', c => { delete c.placement.enforcement; }, 'placement missing required key: enforcement');
add('obsolete-and-shape', 'Reject missing profile class', c => { delete c.default[0].model_class; }, 'profile missing required key: model_class');
for (const key of ['rules', 'default', 'constraints']) add('obsolete-and-shape', `Reject empty ${key}`, c => { c[key] = []; }, `${key} must be a non-empty array`);
add('obsolete-and-shape', 'Reject legacy single-object candidates', c => { c.rules[0].use = c.rules[0].use[0]; }, 'rule use must be a non-empty array');
add('obsolete-and-shape', 'Reject empty candidate array', c => { c.rules[0].use = []; }, 'rule use must be a non-empty array');
add('obsolete-and-shape', 'Reject duplicate default profile IDs', c => { c.default.push(c.default[0]); }, 'default profile ids must be unique');
add('obsolete-and-shape', 'Reject duplicate candidate profile IDs', c => { c.rules[0].use.push(c.rules[0].use[0]); }, 'rule use profile ids must be unique');
for (const cls of ['astra', 'fable']) {
  add('triage-ceiling', `Accept ${cls} restricted to triage`, c => { profile(c, cls); c.rules[0].match.project = triage; });
  add('triage-ceiling', `Accept provider-qualified ${cls} restricted to triage`, c => { profile(c, cls, true); c.rules[0].match.project = triage; });
  add('triage-ceiling', `Reject ${cls} without an exact project`, c => { profile(c, cls); }, `top-tier model class ${cls} requires rule match.project`);
  add('triage-ceiling', `Reject ${cls} assigned to another project`, c => { profile(c, cls); c.rules[0].match.project = otherProject; }, `top-tier model class ${cls} requires rule match.project`);
  add('triage-ceiling', `Reject ${cls} hidden behind ordinary label`, c => { profile(c, cls); c.rules[0].use[0].model_class = 'ordinary'; }, 'profile.model_class does not match model');
  add('triage-ceiling', `Reject provider-qualified uppercase ${cls} hidden behind ordinary label`, c => { profile(c, cls, true); c.rules[0].use[0].model = c.rules[0].use[0].model.toUpperCase(); c.rules[0].use[0].model_class = 'ordinary'; }, 'profile.model_class does not match model');
  add('triage-ceiling', `Reject ${cls} in defaults`, c => { profile(c, cls); c.rules[0].match.project = triage; c.default = c.rules[0].use; }, `top-tier model class ${cls} cannot appear in default`);
  add('triage-ceiling', `Reject ${cls} default hidden behind ordinary label`, c => { profile(c, cls); c.default = [{...c.rules[0].use[0], model_class:'ordinary'}]; c.rules[0].match.project = triage; }, 'profile.model_class does not match model');
  add('triage-ceiling', `Reject widening allowed projects for ${cls}`, c => { profile(c, cls); c.rules[0].match.project = otherProject; c.constraints[0].allowed_projects.push(otherProject); }, 'constraint.allowed_projects must contain only');
}
add('triage-ceiling', 'Reject replacing triage with another allowed project', c => { profile(c, 'astra'); c.rules[0].match.project = otherProject; c.constraints[0].allowed_projects = [otherProject]; }, 'constraint.allowed_projects must contain only');
add('triage-ceiling', 'Reject unclassified model identity', c => { c.default[0].model = 'unknown-model'; }, 'unclassified model');
add('triage-ceiling', 'Reject automatic model alias', c => { c.default[0].model = 'auto'; }, 'unclassified model');
add('triage-ceiling', 'Reject ordinary identity labeled Astra', c => { c.default[0].model_class = 'astra'; }, 'profile.model_class does not match model');
add('reasoning-and-types', 'Accept native Astra ultra when triage restricted', c => { profile(c, 'astra', true); c.rules[0].match.project = triage; c.rules[0].use[0].effort = 'ultra'; });
add('reasoning-and-types', 'Accept supported provider-qualified ordinary model', c => { c.default[0].harness = 'pi'; c.default[0].model = 'anthropic/claude-sonnet-5'; });
add('reasoning-and-types', 'Reject array reasoning mode', c => { c.rules[0].reasoning = {mode:['fixed']}; }, 'rule reasoning.mode must be one of');
add('reasoning-and-types', 'Reject empty array reasoning mode', c => { c.rules[0].reasoning = {mode:[]}; }, 'rule reasoning.mode must be one of');
add('reasoning-and-types', 'Reject array reasoning target', c => { c.rules[1].reasoning.target = ['high']; }, 'rule reasoning.target must be one of');
add('reasoning-and-types', 'Reject array profile classification', c => { c.default[0].model_class = ['ordinary']; }, 'profile.model_class must be one of');
add('reasoning-and-types', 'Reject array placement target kind', c => { c.placement.rules[0].target.kind = ['secondmate']; }, 'placement target.kind must be one of');
for (const flag of [false, 'true', null]) add('reasoning-and-types', `Reject fixed reasoning reason flag ${JSON.stringify(flag)}`, c => { c.rules[1].reasoning.dispatch_reason_required = flag; }, 'rule reasoning.dispatch_reason_required must be true');
add('reasoning-and-types', 'Reject fixed reasoning without target', c => { delete c.rules[1].reasoning.target; }, 'rule reasoning missing required key: target');
add('reasoning-and-types', 'Reject fixed reasoning without reason flag', c => { delete c.rules[1].reasoning.dispatch_reason_required; }, 'rule reasoning missing required key: dispatch_reason_required');
add('reasoning-and-types', 'Reject generic reasoning with fixed fields', c => { c.rules[0].reasoning.target = 'high'; }, 'generic rule reasoning cannot set fixed-mode fields');
add('reasoning-and-types', 'Reject unverified harness', c => { c.default[0].harness = 'spaceship'; }, 'unverified harness: spaceship');
add('reasoning-and-types', 'Reject unsupported Codex effort', c => { c.default[0].effort = 'max'; }, 'invalid effort: codex:max');
add('reasoning-and-types', 'Reject ultra through a non-native provider', c => { c.default[0].harness = 'pi'; c.default[0].model = 'openai/gpt-5.6-terra'; c.default[0].effort = 'ultra'; }, 'invalid effort: pi:ultra');
add('policy-boundaries', 'Reject nonempty quota exceptions', c => { c.exceptions = [{id:'override'}]; }, 'exceptions must be empty');
add('policy-boundaries', 'Reject malformed exceptions object', c => { c.exceptions = {}; }, 'exceptions must be empty');
add('policy-boundaries', 'Reject parallel precedence declaration', c => { c.precedence = {runtime:['hard-work','default']}; }, 'top-level has unknown field: precedence');
add('policy-boundaries', 'Reject parallel default membership list', c => { c.dispatch.ordinary_default_profiles = ['codex-terra']; }, 'dispatch has unknown field: ordinary_default_profiles');
add('policy-boundaries', 'Reject removing Fable from blocked model classes', c => { c.constraints[0].blocked_model_classes = ['astra']; }, 'constraint.blocked_model_classes must contain only astra and fable');
add('policy-boundaries', 'Reject unknown-class admission', c => { c.constraints[0].unknown_model_class = 'allow'; }, 'constraint.unknown_model_class must be treat_as_blocked');
add('policy-boundaries', 'Reject silent no-candidate fallback', c => { c.constraints[0].on_no_eligible_candidate = 'fallback'; }, 'constraint.on_no_eligible_candidate must be report');
add('policy-boundaries', 'Reject disabling higher reasoning explanations', c => { c.dispatch.higher_reasoning_requires_reason = false; }, 'dispatch.higher_reasoning_requires_reason must be true');
add('policy-boundaries', 'Reject replacing quota-array selector', c => { c.dispatch.selector = 'first'; }, 'dispatch.selector must be quota-array-dispatch');
add('advisory-placement', 'Accept advisory secondmate target without creating a handoff', c => { c.placement.rules[0].target = {kind:'secondmate',id:'nonexistent-test-home',host:'nonexistent-test-host.invalid'}; });
add('advisory-placement', 'Reject claiming mechanical placement enforcement', c => { c.placement.enforcement.current = 'mechanical'; }, 'placement enforcement.current must be advisory');
add('advisory-placement', 'Reject missing non-reader declaration', c => { c.placement.enforcement.not_read_by = ['fm-spawn']; }, 'placement enforcement.not_read_by must list fm-bootstrap and fm-spawn');
add('advisory-placement', 'Reject unknown placement capability', c => { c.placement.rules[0].match.requires_capability = 'missing'; }, 'placement rule references unknown capability');
add('advisory-placement', 'Reject secondmate placement without a host', c => { c.placement.rules[0].target = {kind:'secondmate',id:'missing-host'}; }, 'secondmate placement target missing required key: host');
add('advisory-placement', 'Reject main-home placement with a host', c => { c.placement.rules[0].target.host = 'unexpected'; }, 'main-home placement target cannot set host');
add('advisory-placement', 'Reject unsupported unmatched placement policy', c => { c.placement.unmatched = 'move'; }, 'placement.unmatched must be retain-intake-home');
const env = {...process.env, FM_HOME:runtime, FM_CONFIG_OVERRIDE:configDir, FM_STATE_OVERRIDE:path.join(runtime,'state'), FM_DATA_OVERRIDE:path.join(runtime,'data'), FM_PROJECTS_OVERRIDE:path.join(runtime,'projects'), FM_ROOT_OVERRIDE:root, FM_BOOTSTRAP_DETECT_ONLY:'1', FM_BOOTSTRAP_NETWORK:'skip'};
const results = [];
function run(name, group, input, diagnostic, verbose = true) {
  if (input === undefined) { if (fs.existsSync(configFile)) fs.unlinkSync(configFile); }
  else fs.writeFileSync(configFile, input);
  const invocation = spawnSync('/bin/bash', ['bin/fm-bootstrap.sh'], {cwd:root, env:{...env, FM_BOOTSTRAP_VERBOSE_FACTS:verbose ? '1' : '0'}, encoding:'utf8', timeout:30000});
  let error = '';
  try {
    assert.equal(invocation.status, 0, invocation.error?.message || invocation.stderr);
    assert.equal(invocation.stderr, '');
    if (diagnostic) {
      assert.ok(invocation.stdout.includes(`CREW_DISPATCH: invalid config/crew-dispatch.json - ${diagnostic}`) || (invocation.stdout.includes('CREW_DISPATCH: invalid config/crew-dispatch.json - v2 ') && invocation.stdout.includes(diagnostic)), invocation.stdout);
      assert.ok(!invocation.stdout.includes('BOOTSTRAP_INFO: crew dispatch active'), 'Invalid input reported as active');
    } else if (input === undefined || !verbose) assert.equal(invocation.stdout, '');
    else {
      const parsed = JSON.parse(input);
      assert.equal(invocation.stdout.split('\n').filter(line => line.startsWith('BOOTSTRAP_INFO: crew dispatch rule:')).length, parsed.rules.length);
      assert.ok(invocation.stdout.startsWith('BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json\n'));
      assert.ok(invocation.stdout.includes('BOOTSTRAP_INFO: crew dispatch default:'));
      assert.ok(!invocation.stdout.includes('CREW_DISPATCH: invalid'));
    }
    if (input !== undefined) assert.equal(fs.readFileSync(configFile, 'utf8'), input, 'Bootstrap modified its input');
    assert.deepEqual(fs.readdirSync(runtime), ['config'], 'Bootstrap created routing or state artifacts');
  } catch (e) { error = e.message; }
  const result = {name, group, result:error ? 'fail' : 'pass', live:true, expectedDiagnostic:diagnostic, verbose, exit:invocation.status, stdout:invocation.stdout, stderr:invocation.stderr, error, input:input === undefined ? null : input};
  results.push(result);
  process.stdout.write(`${result.result.toUpperCase()}: ${name}\n${invocation.stdout}${error ? `ASSERTION: ${error}\n` : ''}`);
}
try {
  run('Missing optional dispatch file remains silent', 'copyable-example', undefined, null);
  run('Copied example remains silent by default', 'copyable-example', example, null, false);
  run('Malformed JSON produces an actionable diagnostic', 'obsolete-and-shape', '{"schema_version":2,', 'malformed JSON');
  run('Non-object JSON policy is refused', 'obsolete-and-shape', '[]\n', 'top-level value must be an object');
  for (const test of cases) {
    let config = structuredClone(original);
    config = test.change(config) ?? config;
    run(test.name, test.group, JSON.stringify(config, null, 2) + '\n', test.diagnostic);
  }
} finally {
  const report = {commit:'a8c677cc81af8fe4d805d11957e57e554510565b', runtime, entryPoint:'/bin/bash bin/fm-bootstrap.sh', mode:'real local detection, network skipped, mutation sweeps disabled', mocks:false, results};
  fs.writeFileSync(path.join(evidence, 'live-v2-results.json'), JSON.stringify(report, null, 2) + '\n');
  fs.writeFileSync(path.join(evidence, 'live-v2-transcript.log'), results.map(r => `${r.name}\nInput: ${r.input === null ? '(file absent)' : r.input.trim()}\nExit: ${r.exit}\nStdout:\n${r.stdout || '(silent)\n'}Stderr: ${r.stderr || '(empty)'}\nResult: ${r.result}${r.error ? `\n${r.error}` : ''}\n`).join('\n'));
  for (const name of fs.readdirSync(configDir)) fs.unlinkSync(path.join(configDir, name));
  fs.rmdirSync(configDir);
  fs.rmdirSync(runtime);
}
process.stdout.write(`RESULT: ${results.filter(r => r.result === 'pass').length}/${results.length} live checks passed\n`);
process.exitCode = results.some(r => r.result === 'fail') ? 1 : 0;
