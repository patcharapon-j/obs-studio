# Updating the Browser Source CEF / Chromium

This fork's **Browser Source** is powered by the `obs-browser` plugin
(`plugins/obs-browser`, a git submodule) linked against a **prebuilt Chromium
Embedded Framework (CEF)** distribution. The CEF build is pinned centrally in
[`CMakePresets.json`](../../CMakePresets.json) under the `dependencies` preset's
`cef` block; every platform's build flow downloads the matching archive from
`baseUrl` and verifies it against the per-platform SHA-256 in `hashes`.

> **Key constraint:** OBS does not use stock upstream CEF. It relies on a
> *patched* CEF fork (`obsproject/cef`) that adds shared-texture rendering
> (`OnAcceleratedPaint` with extra info), an OSR stutter fix, and `BUILD.gn`
> changes. Stock CEF builds from the official CDN will not give you working
> hardware-accelerated browser sources. To move to a newer Chromium you must
> **port those patches forward, rebuild CEF, host the result, and re-pin it.**

This document is the end-to-end runbook. The target chosen for this fork is
**CEF branch `7204` = Chromium `138.0.7204.x` (M138 Extended Stable / LTS)**.

---

## What's already wired up in this repo

| File | Purpose |
| --- | --- |
| `CMakePresets.json` (`cef` block) | Pins `version`, `baseUrl`, per-platform `hashes` + `revision`. Already repointed to `7204` and this fork's releases. Hashes are **placeholders** until the first build runs. |
| `.github/workflows/build-cef.yaml` | `workflow_dispatch` pipeline: builds patched CEF for all 6 targets, publishes a `cef-7204` GitHub Release on this fork, and rewrites `cef.hashes`. |
| `.github/scripts/cef/build-cef.sh` | Linux/macOS CEF build (wraps CEF `automate-git.py`). |
| `.github/scripts/cef/Build-CEF.ps1` | Windows CEF build. |
| `.github/scripts/cef/update-cef-hashes.py` | Computes SHA-256 of built artifacts and writes them into `CMakePresets.json`. |

Until real artifacts exist at the pinned `baseUrl`, **configuring OBS with
`-DENABLE_BROWSER=ON` will fail at the CEF download step** (placeholder hash /
missing release). That is expected; finish the steps below.

---

## Step 1 — Port the OBS patches onto Chromium 138 (M138)

The patches live on `obsproject/cef`. The current head used by upstream OBS is
branch **`6533-fix-stutter-and-osr-extra-info`** (Chromium 127). You need the
equivalent on top of the `7204` upstream CEF branch.

1. Fork `obsproject/cef` to `patcharapon-j/cef` (the workflow defaults to this
   URL; change the input if you fork elsewhere).
2. Add the canonical CEF remote and fetch the target branch:
   ```bash
   git clone https://github.com/patcharapon-j/cef.git && cd cef
   git remote add upstream https://bitbucket.org/chromiumembedded/cef.git
   git fetch upstream 7204 6533
   ```
3. Identify the OBS patch set — the commits OBS added on top of stock CEF 6533:
   ```bash
   git log --oneline upstream/6533..origin/6533-fix-stutter-and-osr-extra-info
   ```
   These are the shared-texture / `OnAcceleratedPaint` extra-info commits, the
   OSR stutter fix, and the `BUILD.gn`/`libcef` changes.
4. Create the new branch off stock CEF 7204 and replay the patches:
   ```bash
   git switch -c 7204-shared-textures-and-fixes upstream/7204
   git cherry-pick <first>^..<last>      # the range from step 3
   ```
5. **Resolve conflicts.** CEF's C/C++ API churns between milestones — expect
   signature changes around `CefRenderHandler::OnAcceleratedPaint`,
   `CefAcceleratedPaintInfo`, media/audio handlers, and `cef_types.h`. Update
   the patches to the 7204 API.
6. Push the branch. It is the `cef_repo_branch` input to the build workflow.

> Tip: if upstream `7204` does not yet have the hooks the shared-texture patch
> needs, you may need to forward-port the small Chromium-side `BUILD.gn`/`//cef`
> edits too. Compare against how the 6533 branch wires them.

---

## Step 2 — Build the patched CEF (heavy infra)

A full Chromium build needs **~100+ GB free disk, 32+ GB RAM, and several hours
per target**. GitHub-hosted runners will likely exceed the 6-hour job limit or
run out of disk — use **large or self-hosted runners**.

**Option A — CI (recommended):** run the *Build CEF* workflow
(`.github/workflows/build-cef.yaml`) via *Actions → Build CEF → Run workflow*,
with inputs:

- `cef_branch`: `7204`
- `cef_repo_url`: `https://github.com/patcharapon-j/cef.git`
- `cef_repo_branch`: `7204-shared-textures-and-fixes`
- `revision`: `1`
- `update_presets`: ✅

It builds all six targets, creates/updates the `cef-7204` release, uploads the
archives, and commits refreshed `cef.hashes` to the current branch.

**Option B — Locally**, per target, e.g.:

```bash
# Linux x86_64 / aarch64 (aarch64 cross-compiles on x86_64)
CEF_BRANCH=7204 \
CEF_REPO_URL=https://github.com/patcharapon-j/cef.git \
CEF_REPO_BRANCH=7204-shared-textures-and-fixes \
TARGET_ARCH=x86_64 \
.github/scripts/cef/build-cef.sh
```

```pwsh
# Windows x64 / arm64
.github/scripts/cef/Build-CEF.ps1 -CefBranch 7204 `
  -CefRepoUrl https://github.com/patcharapon-j/cef.git `
  -CefRepoBranch 7204-shared-textures-and-fixes -TargetArch x64
```

> The `GN_DEFINES` in the build scripts are a documented starting point. Before
> distributing, reconcile them with the obsproject/cef recipe for the branch you
> forked (proprietary-codec, shared-texture, sysroot and allocator flags in
> particular).

### File-name contract (must match exactly)

`CMakePresets.json` resolves `baseUrl/<file>` where `<file>` is:

| Hash key | Built file name |
| --- | --- |
| `windows-x64`    | `cef_binary_7204_windows_x64_v1.zip` |
| `windows-arm64`  | `cef_binary_7204_windows_arm64_v1.zip` |
| `macos-x86_64`   | `cef_binary_7204_macos_x86_64_v1.tar.xz` |
| `macos-arm64`    | `cef_binary_7204_macos_arm64_v1.tar.xz` |
| `ubuntu-x86_64`  | `cef_binary_7204_linux_x86_64_v1.tar.xz` |
| `ubuntu-aarch64` | `cef_binary_7204_linux_aarch64_v1.tar.xz` |

(`baseUrl` is `.../releases/download/cef-7204`, so all six are assets of the
`cef-7204` release on this fork.)

---

## Step 3 — Pin the hashes

If you used the workflow with `update_presets: true`, this is automatic. Manually:

```bash
python3 .github/scripts/cef/update-cef-hashes.py --artifacts ./cef-artifacts
git diff CMakePresets.json     # six PLACEHOLDER values become real SHA-256
```

---

## Step 4 — Fix obs-browser for the new CEF API

`plugins/obs-browser` is a submodule. Its source calls CEF APIs that may have
changed between 127 and 138 (most likely `OnAcceleratedPaint` /
`CefAcceleratedPaintInfo`, `CefMediaRouter`, V8 value/handler signatures, and
removed enums). Expect to:

1. Fork `obsproject/obs-browser`, branch it, and update the call sites to the
   7204 API until it compiles and the shared-texture path works.
2. Point this submodule at your fork/commit:
   ```bash
   cd plugins/obs-browser
   git remote set-url origin https://github.com/patcharapon-j/obs-browser.git
   git fetch origin && git checkout <your-7204-compatible-commit>
   cd ../.. && git add plugins/obs-browser
   ```

If obs-browser builds unchanged against 7204, you can keep the existing
submodule commit — but verify the accelerated-paint path at runtime (Step 5).

---

## Step 5 — Build and verify OBS

```bash
cmake --preset ubuntu-x86_64       # or windows-x64 / macos
cmake --build --preset ubuntu-x86_64
```

Verification checklist:

- [ ] CEF downloads & hash-verifies for every target you build.
- [ ] OBS launches; `Help → About` / log shows the new CEF/Chromium version.
- [ ] Add a **Browser** source — a page renders.
- [ ] Hardware acceleration / shared textures work (no fallback-to-CPU warning
      in the log; smooth rendering of an animated page).
- [ ] Interaction, audio, and `obs-browser` panels (docks) function.

---

## Maintenance notes

- Bumping to a later Chromium later = repeat Steps 1–4 with the new branch
  number; only `version`, `baseUrl`, `hashes` (+ `revision`) in `CMakePresets.json`
  and the patched-CEF / obs-browser branches change.
- Keep `revision` in sync with the `_vN` suffix in the artifact file names.
- `cmake/finders/FindCEF.cmake` parses `cef_version.h` from the distribution; no
  change is needed as long as the archive layout matches a standard CEF
  `*_minimal` distribution.
