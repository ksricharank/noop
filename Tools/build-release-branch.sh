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
  # ── v15 consolidation (260901) ──────────────────────────────────────────────────────────────
  # The 16-branch v14 stack (five-deep re-homing chain, two stacked pairs, three assembly-based
  # branches) was folded into the five features below; the v15 stack was verified TREE-IDENTICAL
  # to release-10614-14 (the last v14 build installed on the phone) before the upstream rebase.
  # The old branches survive on origin under their v14 names; the pre-v15-refactor tag pins the
  # exact installed state.
  #
  # Apple Health integration: read-only sync (writes off without losing reads; resume a read-only
  # grant). Touches HealthKitBridge/AppleHealthView/HealthSyncPolicy — no other branch does.
  "feature/health-read-only-sync"
  # BLE connection reliability, kept SEPARATE deliberately: it fixes upstream's own #1539 escape
  # (bond-loop pause + parked connect), so it must stay unentangled from fork-only branches to
  # remain upstreamable. Touches BLEManager's pause/re-park sites only.
  "feature/bond-loop-repark"
  # ── The v15 chain: battery → synthesis → widgets. STACKED, in this order. ──────────────────
  # Each is based on the branch above it (battery on upstream/main). After an upstream sync,
  # rebase in order:
  #   git rebase upstream/main feature/v15-battery
  #   git rebase --onto feature/v15-battery  <old battery tip>   feature/v15-synthesis
  #   git rebase --onto feature/v15-synthesis <old synthesis tip> feature/v15-widgets
  # (capture each old tip BEFORE rebasing its base; see docs/FORK-RELEASE.md §stacked features)
  #
  # BATTERY: everything that reduces (or measures) the phone-side battery bill of live HR /
  # background work. Locked-stream duty cycle + the user-configurable Lock-Screen refresh cadence
  # (-1 sentinel), the sleep-window ("night window") pause for Lock Screen / Dynamic Island,
  # locked re-score deferral (#1538 policy + debt), settle pacing, the background light re-score
  # (numerators advance every sync; full pass waits for the morning open), and the two
  # instrumentation sets (re-score prep spread; BLE wake/CPU/MetricKit attribution).
  "feature/v15-battery"
  # SYNTHESIS / LLM: the coach-written Today synthesis and every LLM-plumbing concern — 1h/3h/6h
  # horizons, per-provider API-key slots, model fallback + retry (observable, named on every
  # reply), timeout budget, unified Refresh, editable Today-synthesis instruction, and the extra
  # sleep detail/trends fed to the model.
  "feature/v15-synthesis"
  # WIDGETS & LOCK-SCREEN SURFACES: the targets widgets (steps n/t, cal n/t, effort n/t, sleep
  # target), the Today strip, three-pillar Live Activity card + the synthesis vocabulary for its
  # numbers, Dynamic Island presentation (minimal HR, disconnect hold, stale-end fix), breathe
  # automation (burst-retrospective stress scan + notification), calendar-day rollover, frozen
  # effort target, display-granularity reload dedup, and the widget-publish/retro-scan stats.
  "feature/v15-widgets"
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
