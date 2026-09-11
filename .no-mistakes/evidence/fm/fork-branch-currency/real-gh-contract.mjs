import http from 'node:http';
import { spawn } from 'node:child_process';
import assert from 'node:assert/strict';
const requests = [];
const rule = { type: 'required_status_checks', parameters: { strict_required_status_checks_policy: true, required_status_checks: [{context:'ci'}] } };
const server = http.createServer((req, res) => {
  requests.push(req.url);
  const requested = new URL(req.url, 'http://localhost');
  res.setHeader('Content-Type', 'application/json');
  if (req.url.startsWith('/payload')) {
    res.end(JSON.stringify({state:'OPEN', mergeStateStatus:'BLOCKED', mergeable:'MERGEABLE', headRefOid:'0123456789abcdef0123456789abcdef01234567', baseRefName: new URL(req.url, 'http://localhost').searchParams.get('base')}));
  } else if (requested.pathname.endsWith('/rules/branches/release%2Fv1%2Bhotfix') && requested.searchParams.get('page') !== '2') {
    res.setHeader('Link', `<http://127.0.0.1:${server.address().port}${requested.pathname}?page=2>; rel="next"`);
    res.end('[]');
  } else if (req.url.endsWith('/rules/branches/release%2Fv1%2Bhotfix?page=2')) {
    res.end(JSON.stringify([rule]));
  } else if (req.url.includes('/branches/release%2Fv1%2Bhotfix/protection/required_status_checks')) {
    res.end(JSON.stringify({strict:true, contexts:['ci']}));
  } else if (req.url.includes('/compare/release%2Fv1%2Bhotfix...')) {
    res.end(JSON.stringify({behind_by:2}));
  } else { res.statusCode=404; res.end('{}'); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;
async function gh(args) {
  const child = spawn('/opt/homebrew/bin/gh', args, {env:{...process.env, GH_TOKEN:'fixture-local-only', GITHUB_TOKEN:'fixture-local-only', GH_PROMPT_DISABLED:'1'}});
  let out='', err='';
  child.stdout.on('data', chunk => out += chunk);
  child.stderr.on('data', chunk => err += chunk);
  const rc = await new Promise((resolve, reject) => {child.on('error',reject); child.on('close',resolve);});
  console.log(`gh ${args.map(x => JSON.stringify(x)).join(' ')}\n${out}${err}exit=${rc}`);
  return {rc, out, err};
}
try {
  await gh(['--version']);
  for (const name of ['release/v1+hotfix','main#x','main%2Fx','release/a&b=c','release/café']) {
    const result = await gh(['api', `${base}/payload?base=${encodeURIComponent(name)}`, '--jq', '[.state, .mergeStateStatus, .mergeable, .headRefOid, .baseRefName, (.baseRefName | @uri)] | @tsv']);
    assert.equal(result.rc,0);
    assert.equal(result.out.trim().split('\t')[5], encodeURIComponent(name));
  }
  const protection = await gh(['api', `${base}/repos/o/r/branches/release%2Fv1%2Bhotfix/protection/required_status_checks`, '--jq', '.strict == true and (((.checks // []) + (.contexts // [])) | length > 0)']);
  assert.equal(protection.rc,0); assert.equal(protection.out,'true\n');
  const rulesArgs = ['api', `${base}/repos/o/r/rules/branches/release%2Fv1%2Bhotfix`, '--paginate', '--jq', '.[] | select(.type == "required_status_checks" and .parameters.strict_required_status_checks_policy == true and ((.parameters.required_status_checks // []) | length > 0)) | "true"'];
  const rules = await gh(rulesArgs);
  assert.equal(rules.rc,0); assert.equal(rules.out,'true\n');
  assert(requests.includes('/repos/o/r/rules/branches/release%2Fv1%2Bhotfix?page=2'));
  const compare = await gh(['api', `${base}/repos/o/r/compare/release%2Fv1%2Bhotfix...0123456789abcdef0123456789abcdef01234567`, '--jq','.behind_by']);
  assert.equal(compare.rc,0); assert.equal(compare.out,'2\n');
  const rejected = await gh([...rulesArgs,'--slurp']);
  assert.notEqual(rejected.rc,0);
  assert(rejected.err.includes('the `--slurp` option is not supported'));
  console.log('\nRequests received by the local HTTP fixture:\n'+requests.join('\n'));
  console.log('\nReal gh preserves encoded paths and applies jq per page; no remote repository was contacted.');
} finally { server.close(); }
