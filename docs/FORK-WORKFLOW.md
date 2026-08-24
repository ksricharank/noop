# Fork workflow: tracking upstream while carrying local features

This repo is a downstream copy of [`ryanbr/noop`](https://github.com/ryanbr/noop) that carries
local features which are not (yet) upstream. The problem it solves: as the number of local features
grows, combining them into something installable gets harder — and naively merging them into `main`
makes every future upstream sync a conflict.

## The rule that makes this work

**`main` is a pure mirror of upstream. It never carries a local commit.**

Because `main` only ever fast-forwards, syncing upstream can never conflict, and its history stays
identical to `ryanbr/noop`. A feature being "mature" is expressed by its membership in the
`FEATURES` list in [`Tools/build-release-branch.sh`](../Tools/build-release-branch.sh) — never by
merging it into `main`.

The tempting alternative — `main` = upstream + mature features — moves the pain rather than
removing it: each upstream sync becomes a real merge that can conflict, and those resolutions
accumulate in `main`'s history permanently, where they can no longer be revisited per-feature.

```
upstream/main ──(fast-forward only)──> main
                                        │
              ┌─────────────────────────┼─────────────────────┐
         feature/a                 feature/b             feature/c    durable; rebased onto main
              └─────────────────────────┼─────────────────────┘
                                        ▼
                                     release        disposable; rebuilt from scratch each time
```

Two kinds of branch, and the distinction is the whole design:

| | `feature/*` | `release` |
|---|---|---|
| Lifetime | Durable — the real artifact | Disposable — deleted and rebuilt every run |
| Conflicts | Resolved once, permanently | Never resolved here; a fix here is lost on rebuild |
| History | Your commits, on a current base | Throwaway merge commits |

## The lifecycle

### 1 + 2. Upstream updates, and features move onto it

```bash
./Tools/sync-upstream.sh
```

Fetches upstream, fast-forwards `main`, and rebases every feature branch onto it. A branch that
conflicts is left untouched and reported, so one messy feature never blocks the others; resolve
those by hand with `git checkout <branch> && git rebase origin/main`.

Resolving on the feature branch is the point. The same conflict resolved inside `release` would be
discarded on the next rebuild and would return every single time.

### 3. Combine features into a release

```bash
./Tools/build-release-branch.sh
```

Deletes `release`, recreates it at `origin/main`, merges each branch in `FEATURES` in order, and
regenerates `Strand.xcodeproj`. Then build the `NOOPiOS` scheme to your phone.

### Adding a feature

```bash
git checkout -b feature/<name> origin/main
# ... commit ...
```

Then add `"feature/<name>"` to `FEATURES` in `Tools/build-release-branch.sh`.

## Keeping the feature list from growing forever

The one real cost of this layout is that `release` merges N branches every rebuild, so the conflict
surface grows with N. The fix is retiring features, not relocating them:

- **Upstream it.** Open a PR to `ryanbr/noop`. Once merged, delete the branch and drop it from
  `FEATURES` — it now arrives free with every sync. This is the only thing that genuinely shrinks N.
- **Abandon it.** Delete the branch.
- **Fold it in.** Two features that always conflict with each other should be one branch.

Watch for superseded branches. A branch whose commits are duplicated elsewhere is pure cost — find
them by comparing patch-ids:

```bash
git log --no-merges --format='%h %s' origin/main..<branch> |
  while read h s; do echo "$(git show $h | git patch-id --stable | cut -c1-12)  $s"; done
```

Identical patch-ids across two branches mean the same change is being carried twice.

## Remotes

If a personal fork is added later, the convention is `upstream` = `ryanbr/noop` (read-only) and
`origin` = the fork:

```bash
git remote rename origin upstream
git remote add origin <your-fork-url>
```

`sync-upstream.sh` prefers a remote named `upstream` and falls back to `origin`, so it works either
way with no edits.

Note that feature branches are **rebased**, so pushing an already-pushed branch needs
`git push --force-with-lease` (never a plain `--force`: it refuses when the remote moved
underneath you).
