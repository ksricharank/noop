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

Before pressing ▶ in a worktree you have not built in before, confirm the signing identity actually
resolved — a worktree missing its gitignored `Config/BundleIdSecrets.xcconfig` builds as
`com.noopapp` with no team and only fails later, at the signing step:

```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Release -showBuildSettings \
  | grep -E 'PRODUCT_BUNDLE_IDENTIFIER =|DEVELOPMENT_TEAM ='
```

### 6. Write the build notes

One file per fork build in [`docs/releases/fork/`](releases/fork/), covering the `.N` portion only.
Record what shipped — version, build number, the branches in the stack, what was verified and what
was not — and restate the profile reset from step 4, since the notes are what gets re-read when
reinstalling a build later and a stale profile is the first thing to check.

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

### BLE behaviour cannot be verified by any of this

Compiling proves nothing about connection behaviour, and neither does one good night. Anything on
the CoreBluetooth / offload / live-HR path needs a real strap, and the fork's Live Activity work
needs a toggle-off/toggle-on cycle against a streaming strap plus a disconnect/reconnect pass. Say
what you tested on hardware — and say plainly when you have not.

---

## Conflicts

`build-release-branch.sh` stops on a conflict and leaves the tree mid-merge. Resolve it to finish
the build — then **fix it permanently on the feature branch**, or it returns on every rebuild.

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
