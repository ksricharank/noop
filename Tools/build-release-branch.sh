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

# Overridable so a second integration branch can be built while `release` is checked out in
# another worktree (git refuses to update a branch that is), and to test a stack without
# clobbering the one currently installed on the phone.
RELEASE_BRANCH="${RELEASE_BRANCH:-release}"
# Match sync-upstream.sh: build on the UPSTREAM remote's main, falling back to origin only when no
# separate upstream is configured. Hardcoding origin/main built the release on the FORK's mirror of
# main, which is only as current as the last push to it — after an upstream sync that mirror is
# behind, so the release silently omitted upstream commits that sync-upstream.sh had already
# rebased every feature branch onto.
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 || UPSTREAM_REMOTE="origin"
UPSTREAM="$UPSTREAM_REMOTE/main"

# The feature branches to stack, in order. Order matters only if two features touch the same lines.
FEATURES=(
  "feature/release-branch-tooling"
  # Touches HealthKitBridge/AppleHealthView/HealthSyncPolicy, which no other branch in this stack
  # modifies, so it merges clean from anywhere in the order.
  "feature/health-read-only-sync"
  # Log-only instrumentation (IntelligenceEngine cost line + WhoopStore SQL tally). Touches
  # IntelligenceEngine.swift, which locked-rescore-deferral also edits, but in different regions
  # (the pass-1 loop vs the debt/scheduler wiring) - merges clean as of this writing.
  "feature/rescore-prep-instrumentation"
  # Log/header-only battery attribution (BLE wake counters, getrusage at export, MetricKit daily
  # line). Touches BLEManager's didUpdateValueFor and the LiveState header assembly - regions no
  # other branch edits.
  "feature/battery-instrumentation"
  "feature/lock-screen-hr-average"
  # DEPENDENT BRANCH: based on feature/lock-screen-hr-average, not on main. The duty cycle's -1
  # sentinel lives in that branch's Lock-Screen refresh setting and its Live Activity handling
  # extends that branch's lock-aware cadence code — as an independent branch it would conflict in
  # Units.swift / SettingsView.swift / LiveActivityController.swift on every rebuild. Keep it
  # directly after its base, rebase it with `git rebase --onto feature/lock-screen-hr-average`,
  # and upstream the two together, base first.
  "feature/locked-stream-duty-cycle"
  "feature/locked-rescore-deferral"
  # DEPENDENT BRANCH: based on feature/locked-rescore-deferral, not on main. Both rewrite the same
  # opt-out/disconnect guard in LiveActivityController — the deferral branch replaces it with a
  # LiveActivityPresentationPolicy switch, this one replaces the `Task { await end() }` inside it
  # with the generation-gated `endIfCurrent()`. As independent branches they conflicted here on
  # every rebuild; stacked, the fix is expressed against the policy and merges clean. So: keep it
  # directly after its base, rebase it with `git rebase --onto feature/locked-rescore-deferral`
  # (a plain rebase onto main flattens the stack and brings the conflict back), and upstream the
  # two together, base first.
  "feature/dynamic-ui-bug-fix"
  "feature/dynamic-island-minimal-hr"
  "feature/synthesis-horizons"
  "feature/release-by-default"
)

cd "$(git rev-parse --show-toplevel)"

if [[ "${1:-}" != "--no-fetch" ]]; then
  echo "==> Fetching $UPSTREAM_REMOTE"
  git fetch "$UPSTREAM_REMOTE" --prune
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
cat <<'NEXT'
Next:
  1. Clear the stale provisioning profiles, or a rebuild silently reuses one with days already
     spent on it and the app dies mid-week (free personal teams issue 7-day profiles):
       rm -f ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision
  2. Open Strand.xcodeproj, scheme NOOPiOS, and build to your iPhone.
  3. Write the build's notes in docs/releases/fork/, restating step 1 there.

See docs/FORK-RELEASE.md for the full procedure.
NEXT
