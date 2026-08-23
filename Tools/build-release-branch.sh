#!/usr/bin/env bash
#
# Rebuild the local integration branch: latest upstream main + every feature branch.
#
# The release branch is DISPOSABLE — it is deleted and rebuilt from scratch on every run, so it
# never accumulates its own history and never needs its own conflict resolution carried forward.
# The feature branches are the durable artifacts; this just stacks them.
#
#   ./Tools/build-release-branch.sh              # rebuild from the FEATURES list below
#   ./Tools/build-release-branch.sh --no-fetch   # skip the network fetch (offline / just re-stack)
#
# Adding a feature: create `feature/<name>` off origin/main, commit to it, add it to FEATURES.
#
# On a merge conflict the script stops with the conflict in place, so you can resolve it and
# `git merge --continue`. That is a signal worth reading: it means upstream changed something your
# feature also touches, and the fix belongs on the FEATURE branch (rebase it onto the new main),
# not in the throwaway release branch where it would be lost on the next rebuild.

set -euo pipefail

RELEASE_BRANCH="release"
UPSTREAM="origin/main"

# The feature branches to stack, in order. Order matters only if two features touch the same lines.
FEATURES=(
  "feature/conditional-daytime-hrv"
  "feature/dynamic-island-minimal-hr"
)

cd "$(git rev-parse --show-toplevel)"

if [[ "${1:-}" != "--no-fetch" ]]; then
  echo "==> Fetching $UPSTREAM"
  git fetch origin --prune
fi

# A dirty tree would be silently carried into the rebuild (or block the checkout). Xcode regenerates
# the .xcstrings catalogs on almost every build, so this trips often; it is not a sign of real work.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree is dirty. Commit, stash, or discard first:" >&2
  git status --short >&2
  echo >&2
  echo "  Tip: regenerated Localizable.xcstrings churn is safe to discard with" >&2
  echo "       git checkout -- '**/Localizable.xcstrings'" >&2
  exit 1
fi

echo "==> Rebuilding '$RELEASE_BRANCH' from $UPSTREAM ($(git rev-parse --short $UPSTREAM))"
git checkout -q -B "$RELEASE_BRANCH" "$UPSTREAM"

for branch in "${FEATURES[@]}"; do
  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "ERROR: no such branch: $branch" >&2
    exit 1
  fi
  # How far is this feature's base from current upstream? A large number is not fatal — the merge
  # may still be clean — but it is worth knowing before a conflict surprises you.
  base=$(git merge-base "$branch" "$UPSTREAM")
  behind=$(git rev-list --count "$base".."$UPSTREAM")
  ahead=$(git rev-list --count "$UPSTREAM".."$branch")
  printf '==> Merging %-40s (%s commit(s); base is %s behind upstream)\n' "$branch" "$ahead" "$behind"

  if ! git merge --no-edit --no-ff "$branch" >/dev/null 2>&1; then
    echo >&2
    echo "CONFLICT merging $branch. The tree is left mid-merge for you to resolve." >&2
    git --no-pager diff --name-only --diff-filter=U >&2
    echo >&2
    echo "  Resolve, then:  git merge --continue" >&2
    echo "  Or abandon:     git merge --abort" >&2
    echo >&2
    echo "  Then fix it PERMANENTLY on the feature branch, or the same conflict returns next run:" >&2
    echo "      git checkout $branch && git rebase $UPSTREAM" >&2
    exit 1
  fi
done

# The Xcode project is generated, not tracked, and stale project files silently reference the wrong
# set of source files (a new test file on one branch and not another is the usual way this bites).
echo "==> Regenerating Strand.xcodeproj"
xcodegen generate >/dev/null

echo
echo "'$RELEASE_BRANCH' is ready: $UPSTREAM + ${#FEATURES[@]} feature branch(es)."
git --no-pager log --oneline "$UPSTREAM..$RELEASE_BRANCH" | sed 's/^/    /'
echo
echo "Next: open Strand.xcodeproj, scheme NOOPiOS, and build to your iPhone."
