# Cutting a fork release

How a build of this fork gets from "upstream moved / I changed a feature" to "installed on my
phone". [`FORK-WORKFLOW.md`](FORK-WORKFLOW.md) explains *why* the branch model is shaped this way;
this page is the procedure, the version rules, and the traps that cost real time.

Everything here is local except the pushes at the end. Two steps must be run **by hand** and are
marked where they appear: the [provisioning reset](#4-reset-the-provisioning-clock-manual-gate)
before the build, and the [pushes](#pushing) after it.

---

## The model in one picture

```
upstream/main (ryanbr/noop) ──fast-forward only──> main
                                                    │
        ┌───────────────────────────────────────────┼──────────────────┐
   feature/a                                   feature/b          feature/c    durable, rebased
        └───────────────────────────────────────────┼──────────────────┘
                                                    ▼
                                            release   disposable, rebuilt from scratch
```

`main` never carries a local commit, so an upstream sync always fast-forwards and can never
conflict. The feature branches are the durable artifact. `release` is thrown away and rebuilt every
time — **a conflict resolved in `release` is lost on the next rebuild**, so the fix belongs on the
feature branch.

---

## The procedure

### 1–2. Sync upstream, restack the features

```bash
./Tools/sync-upstream.sh
```

Fetches `upstream`, fast-forwards `main`, and rebases every feature branch onto it. A branch that
conflicts is left untouched and reported, so one messy branch never blocks the rest. `--dry-run`
reports what would move without changing anything.

### 3. Build the integration branch

```bash
./Tools/build-release-branch.sh
```

Deletes `release`, recreates it at `upstream/main`, merges each branch in `FEATURES` in order, and
regenerates `Strand.xcodeproj`. Two env knobs:

| Variable | Default | Use |
|---|---|---|
| `RELEASE_BRANCH` | `release` | Build under another name — `release` is often checked out in another worktree, and git refuses to update a branch that is |
| `UPSTREAM_REMOTE` | `upstream`, falling back to `origin` | Only for a non-standard remote layout |

### 4. Reset the provisioning clock (manual gate)

> **Run this yourself, and run it before step 5. Do not start the build until it has been done.**
> It deletes files outside the repository, so an agent working in this repo is blocked from doing it
> and cannot do it for you — the same shape of manual step as the [pushes](#pushing).

```bash
rm -f ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision
```

Do this on **every** release, before the build. A free personal team issues 7-day profiles, and
Xcode reuses an existing valid one rather than minting a new one — so a rebuild does *not* reliably
reset the clock, and the app can die mid-week after what looked like a fresh build. Deleting them
first forces a new profile and buys the full seven days. See
[Provisioning expires in 7 days](#provisioning-expires-in-7-days).

Cheap to do and cheap to get wrong in the other direction: the profiles are regenerated on demand,
so deleting them when they did not need it costs one extra fetch at build time.

**Confirm it took, before trusting the build.** The profiles are re-minted the moment Xcode next
needs them, so "files are present" proves nothing — read their dates. A `CreationDate` from minutes
ago and an `ExpirationDate` seven days out is the proof; anything older means the reset did not
happen (or a build beat it) and the clock was not reset:

```bash
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$f" | plutil -extract Name raw -
  security cms -D -i "$f" | plutil -extract CreationDate raw -
  security cms -D -i "$f" | plutil -extract ExpirationDate raw -
done
```

This is the one cheap check that distinguishes a good build from the mid-week-death build described
above, and it takes a second.

**Why this is a gate and not a reminder.** Skipping it produces a build that succeeds, signs,
installs, and looks correct — and then dies partway through the week on a profile that was already
part-expired when it was reused. There is nothing in the build output that distinguishes that build
from a good one, so the failure surfaces days later as "the app stopped launching", far from the
step that caused it. Ordering is the only defence: a build started before the reset cannot be
salvaged afterwards, it has to be rebuilt.

If an agent is driving the release, it should stop here, hand you this command, and wait for
confirmation before continuing to step 5 rather than building and mentioning the reset afterwards.

### 5. Build to the phone

**Precondition: step 4 has been run in this session.** If it has not, stop and do it first — a build
made before the reset carries the stale profile and has to be thrown away.

Open `Strand.xcodeproj`, scheme **NOOPiOS**, press ▶.

Confirm the phone is actually attached first — a signed build for a `generic/platform=iOS`
destination succeeds with no device present and produces a `.app` that never installs, which reads
as success until you look for it on the phone:

```bash
xcrun xctrace list devices | sed -n '/^== Devices ==/,/^== /p' | grep -vi simulator
```

Before pressing ▶ in a worktree you have not built in before, confirm the signing identity actually
resolved — a worktree missing its gitignored `Config/BundleIdSecrets.xcconfig` builds as
`com.noopapp` with no team and only fails later, at the signing step:

```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Release -showBuildSettings \
  | grep -E 'PRODUCT_BUNDLE_IDENTIFIER =|DEVELOPMENT_TEAM ='
```

**ONE Xcode window, and verify the version ON THE PHONE before judging anything.** The repo exists
as the main checkout plus several worktrees, each with its own `Strand.xcodeproj`, and their Xcode
windows are indistinguishable at a glance. During the 10.6.0.9 cycle a ▶ pressed in a window on the
stale main checkout installed the months-old `release` assembly (10.6.0.6) — a build with none of
the features under test — which read as "the fix made things worse" and burned an evening. Two rules
close it:

- Before ▶: quit Xcode entirely, keep the main checkout's `release` branch reset to the current
  assembly (`git -C <main-checkout> reset --hard release-NNNNN && xcodegen generate` — the branch is
  disposable by design), and open exactly ONE project window.
- After install, before any testing: confirm the app itself reports the new version (the strap-log
  header's `App:` line, or the About display). The version on the phone is the only build identity
  that counts; three separate incidents (the 10.6.0.6 log header, a stale-DerivedData verification,
  and this one) all trace to skipping this check. Settings persist across installs, so a sentinel
  value entered under a newer build silently degrades under an older one (10.6.0.6 clamped a stored
  `-1` to `0` = fully-live locked pushes — "worse", not just "unchanged").

### 6. Write the build notes

One file per fork build in [`docs/releases/fork/`](releases/fork/), covering the `.N` portion only.
Record what shipped — version, build number, the branches in the stack, what was verified and what
was not — and restate the profile reset from step 4, since the notes are what gets re-read when
reinstalling a build later and a stale profile is the first thing to check.

**Commit them on `feature/release-branch-tooling`, not on `release`.** The notes are a durable
artifact and `release` is deleted on the next rebuild, so a note committed there is silently lost —
including one written *after* a hand-finished merge, when `release` is the branch you happen to be
standing on. If that happens, recover it rather than retyping:

```bash
git checkout feature/release-branch-tooling
git cherry-pick <the-commit-on-release>
```

The same applies to anything else durable that gets written mid-release: the fix belongs on a feature
branch, and only the merge commits belong on `release`.

State plainly what was **not** verified. A fork build is normally compiled and unit-tested but not
exercised on a strap, and the notes are the only place that distinction survives — see
[BLE behaviour cannot be verified by any of this](#ble-behaviour-cannot-be-verified-by-any-of-this).
Where a change predicts a measurable outcome, write the number down: it is what the next build's log
gets compared against, and a prediction recorded before the fact is worth more than one reconstructed
afterwards.

### 7. Push

See [Pushing](#pushing) — those are manual.

---

## Versioning: why fork builds are four-part

An upstream-versioned build and a fork build were indistinguishable on the phone, which made "which
one is actually installed?" unanswerable from the About screen.

> **A fork build's version is the last *released* upstream tag plus a fork counter.**
> `10.6.0.2` = upstream `v10.6.0`, second fork build.

The counter moves whenever the `FEATURES` set changes — a branch added, removed, or materially
reworked. The first three parts move when upstream **tags** a new release.

**Base on the newest tag, not on upstream's `project.yml`.** They disagree routinely: upstream bumps
`MARKETING_VERSION` to the *next* version as soon as it starts staging builds toward it. At the time
of writing `git describe` says `v10.6.0` while upstream's `project.yml` reads `10.6.1` — a version
that is not tagged and not released. Basing on the file would name the fork after a release that
does not exist.

```bash
git fetch upstream --tags
git describe --tags --abbrev=0 upstream/main   # -> the base for the first three parts
```

**iOS only.** `MARKETING_VERSION` in `project.yml` is forked; `versionName` in
`android/app/build.gradle.kts` is deliberately left tracking upstream, because no APK is built from
this fork and forking it would invent cross-platform drift no one reads.

`CURRENT_PROJECT_VERSION` (the build number) increments on every build, independently of all of the
above. It is global in `project.yml` so the app and its widget extension always match — iOS refuses
a mismatch ("extension version must match parent app", upstream #416).

Both live on `feature/release-by-default`, which already owns `project.yml`, so the rebuild resolves
one change against that file instead of two.

#### The build number conflicts on most rebuilds — resolve it UPWARD

`CURRENT_PROJECT_VERSION` is the one key the fork and upstream **both** write, and upstream bumps it
every time it stages a build ("Bump build numbers for the next 10.6.1 staging build"). So
`feature/release-by-default` collides with `upstream/main` on that line whenever upstream has staged
since the last fork build — routinely, and mid-rebuild if upstream moves while you are working.

**Always keep the higher number.** A build number may only ever increase: iOS refuses to install a
build whose number is lower than the one already on the phone, and the app and its widget must match
(#416). Taking "ours" mechanically can therefore hand you a build that will not install.

```
<<<<<<< HEAD
    CURRENT_PROJECT_VERSION: "248"      # upstream staged this
=======
    CURRENT_PROJECT_VERSION: "247"      # what the fork bumped to
>>>>>>> feature/release-by-default
```
→ keep **248**, and note the real number in the build notes. `MARKETING_VERSION` in the same hunk is
not in conflict — the fork's four-part value wins there, since upstream never writes it.

This is expected, not a sign anything is wrong. It is a two-line resolution in the throwaway release
branch, so it does **not** need a permanent fix on the feature branch — unlike a structural conflict,
it recurs by design.

Verify what actually shipped, rather than what the file says:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  ~/Library/Developer/Xcode/DerivedData/Strand-*/Build/Products/Release-iphoneos/NOOP\ Staging.app/Info.plist
```

Per-build notes go in [`docs/releases/fork/`](releases/fork/) — one file per fork build, covering the
`.N` portion only. Upstream's own notes for the base release stay in `docs/releases/`.

---

## Guarantees, not habits

Two things that used to be "remember to set it" are now committed configuration. Both survive
`xcodegen generate`, which overwrites anything you set by hand in the Xcode UI.

### ▶ builds Release

`project.yml`, on `feature/release-by-default`:

```yaml
schemes:
  NOOPiOS:
    run:
      config: Release
  Strand:
    run:
      config: Release
    test:
      config: Debug      # XCTest needs @testable, which Release disables
```

These builds get sideloaded and left installed for days, so the optimised build and its battery
behaviour are what matter. **The tradeoff: Run carries no debugger.** For a breakpoint session,
switch that scheme back in Edit Scheme → Run → Build Configuration.

```bash
xmllint --xpath 'string(//LaunchAction/@buildConfiguration)' \
  Strand.xcodeproj/xcshareddata/xcschemes/NOOPiOS.xcscheme      # -> Release
```

### The right team and bundle ID

A two-layer xcconfig, wired into `project.yml`'s project-wide `configFiles` so every target inherits
it:

| File | Tracked? | Holds |
|---|---|---|
| `Config/BundleId.xcconfig` | yes | upstream defaults (`com.noopapp`, empty team); `#include?`s the file below |
| `Config/BundleIdSecrets.xcconfig` | **gitignored** | your `BUNDLE_ID_PREFIX` and `DEVELOPMENT_TEAM` |

The include comes last, so local values win. Everything derives from the one prefix:

```
com.sricharan.noop  /  .noop.widgets  /  .noop.watch  /  .noop.watch.complications
com.sricharan.noop.staging (macOS)     group.com.sricharan.noop.staging (App Group)
```

`CODE_SIGN_STYLE = Automatic`, so Xcode provisions against the team itself.

```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Release -showBuildSettings \
  | grep -E 'PRODUCT_BUNDLE_IDENTIFIER =|DEVELOPMENT_TEAM ='
```

Because the file is gitignored it survives upstream merges and keeps the Team ID off the public
fork. The costs: **a fresh clone needs it recreated** from `BundleIdSecrets.example.xcconfig`, and
**every git worktree needs its own copy** — a worktree without one silently builds as `com.noopapp`
with no team, which then only fails at the signing step.

---

## Traps

### `DEVELOPMENT_TEAM` wants the OU, not the CN

The certificate carries two identifiers that look equally plausible:

```
CN=Apple Development: you@example.com (A1B2C3D4E5), OU=ABCDE12345
                                       ^^^^^^^^^^      ^^^^^^^^^^
                                       Apple ID        Team ID  <- this one
```

`DEVELOPMENT_TEAM` needs the **`OU`**. The `CN` value is the Apple ID identifier, and using it makes
every target fail to find a provisioning profile. Read it off the certificate rather than guessing:

```bash
security find-identity -v -p codesigning
security find-certificate -c "<the CN from above>" -p | openssl x509 -noout -subject
```

Because each worktree has its own gitignored copy, this can be right in one worktree and wrong in
another. Check the effective value with `-showBuildSettings` above, not the file you assume is in use.

### Provisioning expires in 7 days

A free personal team issues 7-day profiles. Xcode reuses an existing valid profile rather than
minting a new one, so **a rebuild does not reliably reset the clock** — the app can die mid-week
after what looked like a fresh build. For a full week, force a new profile:

```bash
rm ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision
```

This is [step 4 of the procedure](#4-reset-the-provisioning-clock-manual-gate) rather than a remedy
to reach for once the app has already died — by then the build is gone from the phone and has to be
redone.

Then rebuild. Check what you actually shipped with:

```bash
security cms -D -i "<App>.app/embedded.mobileprovision" | plutil -extract ExpirationDate raw -
```

### No CI covers app-target Swift

`swift-packages.yml` tests `Packages/**` only, and `app-build.yml` is disabled. Anything under
`Strand/`, `StrandiOS/`, `StrandiOSShared/`, or `StrandiOSWidgets/` **must be compiled locally** — a
compile error there passes every green check on GitHub.

Before pushing a feature branch that touches app-target Swift:

```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' \
  -configuration Release CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

Build **both** app targets: `StrandiOS/` is iOS-only, but `Strand/` is shared, so an edit there can
compile for iOS and break macOS.

### The macOS build cannot be skipped, even on an iOS-only fork

Tempting, since this fork only ever installs an iPhone build — but the macOS target is load-bearing
for two independent reasons:

1. **`StrandTests` is a macOS target.** In `project.yml` it is `platform: macOS`, depends on
   `target: Strand`, and is hosted in the macOS app (`TEST_HOST` → `NOOP Staging.app/Contents/MacOS/
   NOOP Staging`, with `@testable import Strand`). There is no iOS unit-test target at all, so
   **dropping the macOS build drops the entire 1350-test suite** — the only automated check this fork
   has, given `app-build.yml` is disabled.
2. **`Strand/` is shared source, not macOS source.** The iOS app compiles most of it. A change there
   that builds for iOS can still break macOS (and vice versa), and that break is what the macOS
   compile catches before it reaches a feature branch.

So the macOS *app* is not a deliverable here, but its target is the test host and the second compiler
pass over shared code. Build it; just do not ship it. If the goal is a faster loop, narrow the test
run (`-only-testing:StrandTests/<Suite>`) rather than dropping the target.

### BLE behaviour cannot be verified by any of this

Compiling proves nothing about connection behaviour, and neither does one good night. Anything on
the CoreBluetooth / offload / live-HR path needs a real strap, and the fork's Live Activity work
needs a toggle-off/toggle-on cycle against a streaming strap plus a disconnect/reconnect pass. Say
what you tested on hardware — and say plainly when you have not.

---

## Conflicts

`build-release-branch.sh` stops on a conflict and leaves the tree mid-merge. Resolve it to finish
the build — then **fix it permanently on the feature branch**, or it returns on every rebuild.

Two mechanics worth knowing before you resolve one:

- **`git merge --continue` opens an editor** and rejects `--no-edit` (that flag belongs on `git
  merge`, not on `--continue`). In a non-interactive shell it will appear to hang or error. Use
  `git -c core.editor=true merge --continue` to accept the generated message.
- **The script exits before `xcodegen generate`** when a merge fails, so a hand-finished merge leaves
  a *stale* `Strand.xcodeproj` referencing the pre-merge source list. Run `xcodegen generate`
  yourself after `merge --continue`, or re-run the script with `--no-fetch` once the tree is clean.

Which fix depends on what kind of conflict it is:

**Two branches adding the same thing.** Make the text *identical* on both sides and git merges it
silently. A comment on one side only is enough to recreate the conflict one line lower.

**Two branches restructuring the same code.** No rebase onto `main` can fix this; the edits genuinely
overlap. Rebase the dependent branch onto the other one instead:

```bash
git rebase --onto feature/<base> upstream/main feature/<dependent>
```

Resolve once, and the pair merges clean forever after. The price is that the two must move together
— rebase the dependent with `--onto`, never a plain rebase onto `main` (which flattens the stack and
brings the conflict straight back), and upstream the base first. Note the dependency in `FEATURES`
next to the entry, since branch order alone does not show it.

**Two branches that always conflict.** Fold them into one, per
[`FORK-WORKFLOW.md`](FORK-WORKFLOW.md).

Regenerated `Localizable.xcstrings` churn is not real work — Xcode rewrites those on almost every
build, and both scripts refuse to run on a dirty tree because of it:

```bash
git checkout -- '**/Localizable.xcstrings'
```

---

## Pushing

The Intuit push guard (`intuit-git-push-guard`) blocks pushes to github.com issued by an AI agent,
so these are run by hand. Everything else in this workflow is local and unaffected.

```bash
git push origin upstream/main:main                       # keep the fork's mirror current
git push -u --force-with-lease origin feature/<name>     # features are rebased
git push --force-with-lease origin release-10602:release # release is disposable
```

`--force-with-lease`, never a plain `--force`: it refuses when the remote moved underneath you.

Opening a PR upstream needs the base named explicitly — `ryanbr/noop` is itself a fork, so GitHub
defaults the base to the dormant root of the network:

```bash
gh pr create --repo ryanbr/noop --base main --head ksricharank:<branch>
```

---

## Retiring a feature

The one real cost of this layout is that `release` merges N branches every rebuild, so the conflict
surface grows with N. Shrink it by **upstreaming** (open a PR; once merged, delete the branch and
drop it from `FEATURES` — it then arrives free with every sync), **abandoning**, or **folding** two
always-conflicting branches into one. Relocating a branch does not help.

Before assuming a branch is still needed, check whether upstream has since fixed the same thing:

```bash
# does upstream already carry this branch's change?
git log --oneline upstream/main -- <the files the branch touches>

# is the same patch carried on two branches?
git log --no-merges --format='%h %s' upstream/main..<branch> |
  while read h s; do echo "$(git show $h | git patch-id --stable | cut -c1-12)  $s"; done
```

Identical patch-ids across two branches mean the same change is being carried twice.
