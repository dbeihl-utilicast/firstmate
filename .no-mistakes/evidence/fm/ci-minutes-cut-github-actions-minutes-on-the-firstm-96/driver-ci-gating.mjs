// Drives GitHub's OWN Actions expression engine (@actions/expressions, the
// library GitHub publishes and uses) over the real expressions parsed out of
// .github/workflows/ci.yml, under each job-outcome scenario.
import { Lexer, Parser, Evaluator, data } from '@actions/expressions'
import { FunctionCall, Logical, Binary, Unary, Grouping, IndexAccess } from '@actions/expressions/ast'
import fs from 'node:fs'

const CONTEXTS = ['needs', 'github', 'steps', 'env', 'matrix', 'inputs', 'vars', 'secrets', 'runner', 'job', 'strategy']
const STATUS_FUNCS = ['success', 'failure', 'cancelled', 'always']
const FUNC_INFO = STATUS_FUNCS.map(name => ({ name, minArgs: 0, maxArgs: 0 }))

function parse (expr) {
  let body = String(expr).trim()
  if (body.startsWith('${{') && body.endsWith('}}')) body = body.slice(3, -2).trim()
  const tokens = new Lexer(body).lex().tokens
  return { ast: new Parser(tokens, CONTEXTS, FUNC_INFO).parse(), body }
}

// Walks the parsed tree for a status-check FunctionCall. GitHub applies an
// implicit success() to a job-level `if` only when none is present.
function namesStatusFunction (n) {
  if (!n || typeof n !== 'object') return false
  if (n instanceof FunctionCall) {
    if (STATUS_FUNCS.includes(n.functionName.lexeme.toLowerCase())) return true
    return n.args.some(namesStatusFunction)
  }
  if (n instanceof Logical) return n.args.some(namesStatusFunction)
  if (n instanceof Binary) return namesStatusFunction(n.left) || namesStatusFunction(n.right)
  if (n instanceof Unary) return namesStatusFunction(n.expr)
  if (n instanceof Grouping) return namesStatusFunction(n.group)
  if (n instanceof IndexAccess) return namesStatusFunction(n.expr) || namesStatusFunction(n.index)
  return false
}

function dict (obj) {
  const d = new data.Dictionary()
  for (const [k, v] of Object.entries(obj)) {
    if (v === null || v === undefined) d.add(k, new data.Null())
    else if (typeof v === 'boolean') d.add(k, new data.BooleanData(v))
    else if (typeof v === 'number') d.add(k, new data.NumberData(v))
    else if (typeof v === 'object') d.add(k, dict(v))
    else d.add(k, new data.StringData(v))
  }
  return d
}

function statusFuncs (scenario) {
  // How the runner resolves the status functions for a dependent job.
  const cancelled = scenario.cancelled === true
  const allNeedsOk = scenario.needsResult === 'success' || scenario.needsResult === 'skipped'
  const map = new Map()
  map.set('success', { name: 'success', minArgs: 0, maxArgs: 0, call: () => new data.BooleanData(!cancelled && allNeedsOk) })
  map.set('failure', { name: 'failure', minArgs: 0, maxArgs: 0, call: () => new data.BooleanData(!cancelled && scenario.needsResult === 'failure') })
  map.set('cancelled', { name: 'cancelled', minArgs: 0, maxArgs: 0, call: () => new data.BooleanData(cancelled) })
  map.set('always', { name: 'always', minArgs: 0, maxArgs: 0, call: () => new data.BooleanData(true) })
  return map
}

function willRun (expr, scenario) {
  const { ast } = parse(expr)
  const ctx = new data.Dictionary()
  ctx.add('needs', dict({ changes: { result: scenario.needsResult, outputs: { docs_only: scenario.docsOnly } } }))
  ctx.add('github', dict({ event_name: scenario.event ?? 'pull_request', sha: scenario.sha ?? 'aaa', event: { pull_request: { number: scenario.pr ?? 96, base: { sha: 'base1' } } } }))
  const funcs = statusFuncs(scenario)
  let gated = new Evaluator(ast, ctx, funcs).evaluate()
  let value = truthy(gated)
  if (!namesStatusFunction(ast)) {
    // implicit success() gate
    value = value && truthy(funcs.get('success').call())
  }
  return value
}

function truthy (v) {
  if (v === undefined || v === null) return false
  if (v.kind === 3 /* boolean */ || typeof v.value === 'boolean') return Boolean(v.value)
  if (typeof v.value === 'string') return v.value.length > 0
  if (typeof v.value === 'number') return v.value !== 0
  return Boolean(v.value)
}

// A concurrency group is a template: literal text with embedded ${{ }} parts.
function evalString (expr, scenario) {
  const ctx = new data.Dictionary()
  ctx.add('github', dict({ event_name: scenario.event, sha: scenario.sha, event: { pull_request: scenario.pr === null ? null : { number: scenario.pr } } }))
  return String(expr).replace(/\$\{\{([^}]*(?:\}[^}][^}]*)*)\}\}/g, (_m, body) => {
    const tokens = new Lexer(body.trim()).lex().tokens
    const ast = new Parser(tokens, CONTEXTS, FUNC_INFO).parse()
    return new Evaluator(ast, ctx, statusFuncs({ needsResult: 'success' })).evaluate().coerceString()
  })
}

const wf = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const mode = process.argv[3]

if (mode === 'lanes') {
  const scenarios = [
    ['classifier FAILED (clone/diff error, force-push)', { needsResult: 'failure', docsOnly: '', cancelled: false }, true],
    ['classifier SKIPPED (push to main)', { needsResult: 'skipped', docsOnly: '', cancelled: false, event: 'push' }, true],
    ['classifier ok, no verdict written', { needsResult: 'success', docsOnly: '', cancelled: false }, true],
    ['classifier ok, docs_only=false (code diff)', { needsResult: 'success', docsOnly: 'false', cancelled: false }, true],
    ['classifier ok, docs_only=true (prose diff)', { needsResult: 'success', docsOnly: 'true', cancelled: false }, false],
    ['run CANCELLED (superseded by fix-round push)', { needsResult: 'cancelled', docsOnly: '', cancelled: true }, false],
  ]
  const lanes = Object.entries(wf.lanes)
  let bad = 0
  const w = 50
  process.stdout.write('LANE'.padEnd(34) + scenarios.map(s => s[0].slice(0, 20).padEnd(22)).join('') + '\n')
  process.stdout.write('-'.repeat(34 + 22 * scenarios.length) + '\n')
  for (const [name, expr] of lanes) {
    let row = name.padEnd(34)
    for (const [, sc, expected] of scenarios) {
      const actual = willRun(expr, sc)
      const ok = actual === expected
      if (!ok) bad++
      row += `${actual ? 'RUNS' : 'skip'}${ok ? '' : ' <<WRONG'}`.padEnd(22)
    }
    process.stdout.write(row + '\n')
  }
  process.stdout.write('\nlegend: expected per column -> ' + scenarios.map(s => `${s[0]}=${s[2] ? 'RUNS' : 'skip'}`).join(' | ') + '\n')
  process.stdout.write('\nimplicit-success() gate dropped (condition names a status function)?\n')
  for (const [name, expr] of lanes) {
    process.stdout.write(`  ${name.padEnd(30)} ${namesStatusFunction(parse(expr).ast) ? 'yes' : 'NO  <<fail-open shape'}\n`)
  }
  process.stdout.write(`\nclassifier job \`if\`: ${wf.changesIf}\n`)
  for (const ev of ['pull_request', 'push', 'workflow_dispatch']) {
    const runs = willRun(wf.changesIf, { needsResult: 'success', docsOnly: '', cancelled: false, event: ev })
    process.stdout.write(`  event=${ev.padEnd(20)} classifier ${runs ? 'RUNS' : 'does not run'}\n`)
  }
  process.exit(bad === 0 ? 0 : 1)
}

if (mode === 'concurrency') {
  const cases = [
    ['pull_request run 1 (PR #96, sha aaaa)', { event: 'pull_request', pr: 96, sha: 'aaaa' }],
    ['pull_request run 2 (PR #96, sha bbbb - fix round)', { event: 'pull_request', pr: 96, sha: 'bbbb' }],
    ['pull_request run 3 (PR #97, sha cccc)', { event: 'pull_request', pr: 97, sha: 'cccc' }],
    ['push to main, merge commit dddd', { event: 'push', pr: null, sha: 'dddd' }],
    ['push to main, next merge commit eeee', { event: 'push', pr: null, sha: 'eeee' }],
  ]
  for (const [label, sc] of cases) {
    const group = evalString(wf.group, sc)
    const cancel = evalString(wf.cancel, sc)
    process.stdout.write(`${label.padEnd(50)} group=${group.padEnd(28)} cancel-in-progress=${cancel}\n`)
  }
}
