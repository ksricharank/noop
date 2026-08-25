#!/usr/bin/env bash
#
# Step 1+2 of the fork lifecycle: pull upstream, then restack every feature branch onto it.
#
# `main` is a PURE MIRROR of upstream — it never carries local commits, so it always
# fast-forwards and can never conflict. Maturity is expressed by a branch's membership in the
# FEATURES list in build-release-branch.sh, not by melting it into main.
#
#   ./Tools/sync-upstream.sh            # fetch, fast-forward main, rebase every feature branch
#   ./Tools/sync-upstream.sh --dry-run  # report what would move, change nothing
#
# A branch that conflicts is left UNTOUCHED (its rebase is aborted) and reported at the end, so
# one messy feature never blocks the others. Resolve those by hand:
#
#     git checkout <branch> && git rebase origin/main
#
# Resolving here is the whole point: the fix lands on the durable feature branch and is paid for
# once, instead of resurfacing in every throwaway `release` rebuild.

set -euo pipefail

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
# Fall back to origin when no separate upstream remote is configured (pre-fork layout).
git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 || UPSTREAM_REMOTE="origin"
UPSTREAM="$UPSTREAM_REMOTE/main"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

cd "$(git rev-parse --show-toplevel)"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree is dirty. Commit, stash, or discard first:" >&2
  git status --short >&2
  echo "  Tip: regenerated Localizable.xcstrings churn is safe to discard with" >&2
  echo "       git checkout -- '**/Localizable.xcstrings'" >&2
  exit 1
fi

STARTING_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
restore() { git checkout -q "$STARTING_BRANCH" 2>/dev/null || true; }
trap restore EXIT

echo "==> Fetching $UPSTREAM_REMOTE"
git fetch "$UPSTREAM_REMOTE" --prune

# Every local branch that is not main/release is treated as a feature branch. This deliberately
# includes branches absent from the FEATURES list: keeping them current costs little, and a stale
# branch is the thing that makes a later merge painful.
# (read -a rather than mapfile: macOS ships bash 3.2, where mapfile does not exist.)
BRANCHES=()
while IFS= read -r _b; do
  [[ -n "$_b" ]] && BRANCHES+=("$_b")
done < <(git for-each-ref --format='%(refname:short)' refs/heads/ | grep -vE '^(main|release|tmp/)' || true)

echo "==> main -> $UPSTREAM ($(git rev-parse --short "$UPSTREAM"))"
if ! $DRY_RUN; then
  # A branch checked out in ANY worktree cannot be force-updated; update it in place there instead.
  if wt=$(git worktree list --porcelain | grep -B2 "^branch refs/heads/main$" | head -1 | cut -d' ' -f2-) \
     && [[ -n "$wt" ]]; then
    if git -C "$wt" merge --ff-only "$UPSTREAM" >/dev/null 2>&1; then
      echo "    fast-forwarded in worktree $wt"
    elif ! git merge-base --is-ancestor main "$UPSTREAM"; then
      echo "    WARNING: main has diverged from $UPSTREAM -- it is meant to be a pure mirror." >&2
      echo "             Inspect with: git log --oneline $UPSTREAM..main" >&2
    else
      # main is a clean fast-forward; something in the worktree is in the way. Almost always the
      # .xcstrings catalogs, which Xcode regenerates on nearly every build.
      echo "    WARNING: main could not fast-forward -- worktree $wt is dirty:" >&2
      git -C "$wt" status --porcelain | sed 's/^/               /' >&2
      echo "             Discard generated churn, then re-run:" >&2
      echo "               git -C $wt checkout -- '\''**/Localizable.xcstrings'\''" >&2
    fi
  else
    git branch -f main "$UPSTREAM"
  fi
fi

CLEAN=(); CONFLICTED=(); SKIPPED=()
for b in "${BRANCHES[@]}"; do
  ahead=$(git rev-list --count "$UPSTREAM..$b")
  if [[ "$ahead" == "0" ]]; then SKIPPED+=("$b (nothing to restack)"); continue; fi

  if $DRY_RUN; then
    base=$(git merge-base "$b" "$UPSTREAM")
    behind=$(git rev-list --count "$base..$UPSTREAM")
    printf '    %-45s %s commit(s), base %s behind\n' "$b" "$ahead" "$behind"
    continue
  fi

  if ! git checkout -q "$b" 2>/dev/null; then
    SKIPPED+=("$b (checked out in another worktree)"); continue
  fi
  if git rebase "$UPSTREAM" >/dev/null 2>&1; then
    CLEAN+=("$b")
  else
    git rebase --abort 2>/dev/null || true
    CONFLICTED+=("$b")
  fi
done

$DRY_RUN && { echo; echo "(dry run — nothing changed)"; exit 0; }

echo
echo "==> Restacked onto $(git rev-parse --short "$UPSTREAM")"
for b in "${CLEAN[@]}";      do echo "    ok        $b"; done
for b in "${SKIPPED[@]}";    do echo "    skipped   $b"; done
for b in "${CONFLICTED[@]}"; do echo "    CONFLICT  $b"; done

if (( ${#CONFLICTED[@]} )); then
  echo
  echo "These need a hand-resolved rebase (they were left untouched):" >&2
  for b in "${CONFLICTED[@]}"; do echo "    git checkout $b && git rebase $UPSTREAM" >&2; done
  exit 1
fi

echo
echo "Next: ./Tools/build-release-branch.sh"
