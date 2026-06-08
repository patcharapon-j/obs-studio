# Handoff: Continue the CEF / Chromium update for the Browser Source

> **Audience:** the next Claude (or human) picking up this branch
> (`claude/compassionate-gauss-2qTyc`) **locally**.
> **Goal:** finish moving the OBS Browser Source from CEF `6533` (Chromium 127)
> to CEF `7204` (Chromium 138 / M138 Extended Stable / LTS).
> **Full details:** [`cef-update-runbook.md`](./cef-update-runbook.md). This file
> is the short "what's done / do this next" map; the runbook is the deep guide.

---

## TL;DR of the situation

- The Browser Source = `plugins/obs-browser` submodule + a **prebuilt patched
  CEF** pinned in `CMakePresets.json` (`dependencies` preset → `cef` block).
- OBS does **not** use stock CEF; it needs a *patched* CEF fork
  (`obsproject/cef`) with shared-texture `OnAcceleratedPaint` + OSR stutter
  fix. So "use newer Chromium" = port patches → rebuild CEF → host → re-pin.
- Target chosen and already wired: **CEF `7204` = Chromium `138.0.7204.x`**,
  artifacts to be hosted on **this fork's GitHub Releases** (tag `cef-7204`).

## What is ALREADY done on this branch (commit `e3668c4`)

- `CMakePresets.json` `cef` block repointed: `version=7204`,
  `baseUrl=https://github.com/patcharapon-j/obs-studio/releases/download/cef-7204`,
  `revision=1` for all six targets, and `hashes` reset to the literal
  placeholder `PLACEHOLDER-set-by-build-cef-workflow` (real values come from the
  first build).
- `.github/workflows/build-cef.yaml` — `workflow_dispatch` pipeline that builds
  all six targets, publishes the `cef-7204` release, and rewrites `cef.hashes`.
- `.github/scripts/cef/build-cef.sh` + `Build-CEF.ps1` — per-platform CEF builds
  via `automate-git.py` against the patched fork.
- `.github/scripts/cef/update-cef-hashes.py` — pins SHA-256s into
  `CMakePresets.json` (tested: replaces exactly the 6 CEF placeholders, JSON
  stays valid, other deps untouched).
- `docs/development/cef-update-runbook.md` — the end-to-end runbook.

## ⚠️ Known current state / gotchas

- **Configuring with `-DENABLE_BROWSER=ON` will FAIL right now** at the CEF
  download step — the release/artifacts don't exist yet and the hashes are
  placeholders. This is expected until the build (Step 2 below) runs. To build
  the rest of OBS meanwhile, configure with `-DENABLE_BROWSER=OFF`.
- The `GN_DEFINES` in the build scripts are a **documented starting point**, not
  verified against a real build. Reconcile them with the obsproject/cef recipe
  for the `7204` branch before trusting a distribution.
- A real CEF build needs **~100+ GB disk, 32+ GB RAM, hours/target** — not
  feasible on small runners or in an ephemeral container.

---

## DO THIS NEXT — ordered checklist

### 1. Port OBS's CEF patches onto Chromium 138
- [ ] Fork `obsproject/cef` → `patcharapon-j/cef` (or update the workflow's
      `cef_repo_url` input if you fork elsewhere).
- [ ] List the OBS patch set:
      `git log --oneline upstream/6533..origin/6533-fix-stutter-and-osr-extra-info`
      (add `upstream = https://bitbucket.org/chromiumembedded/cef.git`).
- [ ] Create `7204-shared-textures-and-fixes` off `upstream/7204`, cherry-pick
      the patches, resolve API conflicts (focus: `OnAcceleratedPaint`,
      `CefAcceleratedPaintInfo`, media/audio handlers, `cef_types.h`). Push it.
- → Runbook §1.

### 2. Build the patched CEF (heavy infra)
- [ ] Run **Actions → Build CEF → Run workflow** with `cef_branch=7204`,
      `cef_repo_url=…/cef.git`, `cef_repo_branch=7204-shared-textures-and-fixes`,
      `revision=1`, `update_presets=✅`. Use large/self-hosted runners.
- [ ] Confirm the `cef-7204` release has all six assets and that a commit
      pinning real `cef.hashes` landed on this branch.
- → Runbook §2–3. (Local alternative: run the build scripts per target, then
      `update-cef-hashes.py`.)

### 3. Make obs-browser compile against CEF 138
- [ ] Build OBS with `-DENABLE_BROWSER=ON`. If `obs-browser` fails on CEF API
      changes, fork `obsproject/obs-browser`, fix the call sites, and point the
      submodule (`plugins/obs-browser`) at your commit.
- → Runbook §4.

### 4. Verify end-to-end
- [ ] CEF downloads & hash-verifies; OBS launches; About/log shows Chromium 138.
- [ ] A Browser source renders; hardware-accel/shared-textures work (no
      CPU-fallback warning in the log); interaction + audio + browser docks OK.
- → Runbook §5.

### 5. Wrap up
- [ ] Commit any submodule bump + final hash pins.
- [ ] (If desired) open a PR from `claude/compassionate-gauss-2qTyc`.

---

## Useful pointers
- CEF download/verify logic: `cmake/common/buildspec_common.cmake`
  (`_check_dependencies`), `cmake/windows/buildspec.cmake`,
  `cmake/macos/buildspec.cmake`, and Linux `.github/scripts/utils.zsh/setup_ubuntu`.
- File-name ⇄ hash-key contract: runbook §2 table (must match exactly).
- CEF version is detected from `cef_version.h` by `cmake/finders/FindCEF.cmake` —
  no change needed for a standard `*_minimal` distribution layout.
- Decisions already made: target = **CEF LTS (M138/7204)**; hosting =
  **this fork's GitHub Releases**.
