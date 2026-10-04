#!/bin/bash
set -u

NAME="public repository"
REPO="russellchen001/MosaicRestore"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  echo "FAIL $NAME — $1"
  exit 1
}

cd "$ROOT" || fail "cannot enter repository"

visibility="$(gh repo view "$REPO" --json visibility --jq '.visibility')" || fail "cannot read GitHub visibility"
if [ "$visibility" = "PUBLIC" ]; then
  echo "✓ visibility is public"
else
  fail "visibility is $visibility"
fi

default_branch="$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')" || fail "cannot read default branch"
if [ "$default_branch" = "master" ]; then
  echo "✓ default branch is master"
else
  fail "default branch is $default_branch"
fi

readme_url="$(gh api "repos/$REPO/readme" --jq '.html_url')" || fail "README is not recognized on the repository homepage"
if [ -n "$readme_url" ]; then
  echo "✓ README is visible on the repository homepage"
else
  fail "README URL is empty"
fi

local_sha="$(git rev-parse HEAD)" || fail "cannot read local commit"
remote_sha="$(gh api "repos/$REPO/commits/master" --jq '.sha')" || fail "cannot read remote master commit"
if [ "$local_sha" = "$remote_sha" ]; then
  echo "✓ local HEAD matches remote master at $local_sha"
else
  fail "local HEAD $local_sha does not match remote master $remote_sha"
fi

if [ -z "$(git status --porcelain)" ]; then
  echo "✓ working tree is clean"
else
  fail "working tree has uncommitted changes"
fi

echo "PASS $NAME"
exit 0
