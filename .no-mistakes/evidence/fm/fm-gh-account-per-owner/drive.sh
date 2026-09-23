set -u
. /Users/davidbeihl/.no-mistakes/worktrees/b5ea5ab83d56/01M37003DPEXDBDTXM7CGZSC8H/bin/fm-gh-auth-lib.sh
export FM_HOME=/tmp/fmgh.kb3A
act(){ gh auth status 2>&1 | grep -B1 'Active account: true' | head -1 | sed 's/.*account //;s/ (.*//'; }
echo "== active before: $(act)"
echo "== S1 owner dbeihl-utilicast -> login: $(fm_gh_run dbeihl-utilicast gh api user --jq .login)"
echo "== S2 owner masonrecipes -> login: $(fm_gh_run masonrecipes gh api user --jq .login)"
echo "   masonrecipes repo perms via map: $(fm_gh_run masonrecipes gh api repos/masonrecipes/masonrecipes.github.io --jq .permissions.admin)"
echo "   masonrecipes repo perms via active: $(gh api repos/masonrecipes/masonrecipes.github.io --jq .permissions.admin)"
echo "== S3 owner MasonRecipes (case) -> $(fm_gh_run MasonRecipes gh api user --jq .login)"
echo "== S4 unmapped owner dbeihl -> $(fm_gh_run dbeihl gh api user --jq .login)"
echo "== S5 mapped login missing from keyring:"; fm_gh_run ghostowner gh api user --jq .login; echo "   rc=$?"
echo "== S6 GH_TOKEN precedence (token of masonrecipes, owner dbeihl-utilicast) -> $(GH_TOKEN=$(gh auth token --user masonrecipes) fm_gh_run dbeihl-utilicast gh api user --jq .login)"
echo "== active after: $(act)"
