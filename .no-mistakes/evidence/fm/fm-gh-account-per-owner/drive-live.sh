#!/usr/bin/env bash
set -u
unset GH_TOKEN GITHUB_TOKEN
export FM_HOME=/var/folders/h4/89z_m16d0sq00pkwstv182280000gn/T/tmp.TOvetsImMD
. /Users/davidbeihl/.no-mistakes/worktrees/b5ea5ab83d56/01M376HVYGNZ977XM01B0PHHPA/bin/fm-gh-auth-lib.sh
echo "== config/gh-accounts"; cat $FM_HOME/config/gh-accounts
echo "== active account before"; gh api user --jq .login
for o in dbeihl dbeihl-utilicast masonrecipes unmapped-owner; do
  printf 'owner=%-18s -> api user login: ' "$o"; fm_gh_run "$o" gh api user --jq .login
done
echo "== real repo reads, each under its owner's login"
fm_gh_run dbeihl-utilicast gh pr view 86 -R dbeihl-utilicast/firstmate --json number,state --jq '"firstmate PR #"+(.number|tostring)+" "+.state'
fm_gh_run masonrecipes gh api repos/masonrecipes/masonrecipes.github.io --jq '"masonrecipes.github.io admin=" + (.permissions.admin|tostring)'
echo "   (same repo as active account dbeihl, collaborator):"
gh api repos/masonrecipes/masonrecipes.github.io --jq '"masonrecipes.github.io admin=" + (.permissions.admin|tostring)'
echo "== active account after (must be unchanged)"; gh api user --jq .login
gh auth status 2>&1 | grep -B1 'Active account: true' | head -1
echo "== adversarial: mapped login missing from keyring"
printf 'ghost-owner no-such-login-xyz\n' >> $FM_HOME/config/gh-accounts
fm_gh_run ghost-owner sh -c 'echo COMMAND-RAN'; echo "exit=$?"
echo "== adversarial: caller GH_TOKEN wins over mapping"
GH_TOKEN=$(gh auth token --user masonrecipes) fm_gh_run dbeihl-utilicast gh api user --jq .login
echo "== default <login> catch-all"
printf 'default masonrecipes\n' >> $FM_HOME/config/gh-accounts
printf 'unmapped-owner -> '; fm_gh_run unmapped-owner gh api user --jq .login
