#!/usr/bin/env bash

##############################################################################
# Build a patched OBS Chromium Embedded Framework (CEF) minimal distribution
# for Linux and macOS.
#
# This wraps CEF's canonical `automate-git.py` build against OBS's *patched*
# CEF fork (the one carrying the shared-texture / OnAcceleratedPaint and
# stutter-fix patches that obs-browser depends on). It produces a minimal
# distribution tarball named to match what obs-studio's dependency resolver
# expects, e.g.:
#
#   cef_binary_7204_linux_x86_64_v1.tar.xz
#   cef_binary_7204_macos_arm64_v1.tar.xz
#
# IMPORTANT: A full Chromium build needs ~100+ GB free disk, 32+ GB RAM and
# several hours on a fast multi-core machine. It cannot run on small CI
# runners. Use a large/self-hosted runner (see build-cef.yaml).
#
# The GN_DEFINES below are a documented starting point. Before relying on a
# build for distribution, reconcile them against OBS's own recipe on the
# obsproject/cef branch you forked from (BUILD.gn + the project's build
# instructions) -- proprietary-codec and shared-texture flags in particular.
##############################################################################

set -euo pipefail

# --- Parameters (env-overridable) -------------------------------------------
: "${CEF_BRANCH:?CEF_BRANCH is required, e.g. 7204 (Chromium 138 / M138 LTS)}"
: "${CEF_REPO_URL:?CEF_REPO_URL is required, e.g. https://github.com/patcharapon-j/cef.git}"
: "${CEF_REPO_BRANCH:?CEF_REPO_BRANCH is required, e.g. 7204-shared-textures-and-fixes}"
: "${CEF_REVISION:=1}"
: "${TARGET_ARCH:?TARGET_ARCH is required: x86_64 | aarch64 | arm64}"

WORK_DIR="${WORK_DIR:-${PWD}/cef-build}"
OUTPUT_DIR="${OUTPUT_DIR:-${PWD}/cef-artifacts}"

uname_s="$(uname -s)"
case "${uname_s}" in
  Linux)  platform="linux" ;;
  Darwin) platform="macos" ;;
  *) echo "Unsupported host platform: ${uname_s}" >&2; exit 2 ;;
esac

# automate-git arch flag + distribution arch token used in the file name.
case "${platform}:${TARGET_ARCH}" in
  linux:x86_64)  automate_arch="--x64-build"   ; dist_arch="x86_64"  ;;
  linux:aarch64) automate_arch="--arm64-build" ; dist_arch="aarch64" ;;
  macos:x86_64)  automate_arch="--x64-build"   ; dist_arch="x86_64"  ;;
  macos:arm64)   automate_arch="--arm64-build" ; dist_arch="arm64"   ;;
  *) echo "Unsupported ${platform}/${TARGET_ARCH} combination" >&2; exit 2 ;;
esac

echo "==> Building OBS CEF ${CEF_BRANCH} for ${platform}/${dist_arch}"
echo "    fork: ${CEF_REPO_URL} @ ${CEF_REPO_BRANCH}"

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"
cd "${WORK_DIR}"

# --- depot_tools ------------------------------------------------------------
if [[ ! -d depot_tools ]]; then
  git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
export PATH="${WORK_DIR}/depot_tools:${PATH}"
export DEPOT_TOOLS_UPDATE=1

# --- automate-git.py --------------------------------------------------------
if [[ ! -f automate-git.py ]]; then
  curl -fsSL -o automate-git.py \
    "https://bitbucket.org/chromiumembedded/cef/raw/master/tools/automate/automate-git.py"
fi

# --- GN defines -------------------------------------------------------------
# Starting point; align with the obsproject/cef recipe before distributing.
common_defines="is_official_build=true use_thin_lto=false chrome_pgo_phase=0 \
proprietary_codecs=true ffmpeg_branding=Chrome symbol_level=1 \
enable_widevine=false"

if [[ "${platform}" == "linux" ]]; then
  export GN_DEFINES="${common_defines} use_sysroot=true use_allocator_shim=false use_partition_alloc_as_malloc=false"
else
  export GN_DEFINES="${common_defines}"
fi
export CEF_ARCHIVE_FORMAT="tar.bz2"

# --- Build ------------------------------------------------------------------
python3 automate-git.py \
  --download-dir="${WORK_DIR}/chromium_git" \
  --branch="${CEF_BRANCH}" \
  --url="${CEF_REPO_URL}" \
  --checkout="${CEF_REPO_BRANCH}" \
  --minimal-distrib \
  --client-distrib \
  --force-clean \
  --no-debug-build \
  ${automate_arch}

# --- Repackage to the obs-studio file-name contract ------------------------
# automate-git emits a directory like:
#   chromium_git/chromium/src/cef/binary_distrib/cef_binary_<ver>_<os><arch>_minimal
distrib_root="${WORK_DIR}/chromium_git/chromium/src/cef/binary_distrib"
src_dir="$(find "${distrib_root}" -maxdepth 1 -type d -name 'cef_binary_*_minimal' | head -n1)"
if [[ -z "${src_dir}" ]]; then
  echo "Could not locate the minimal distribution under ${distrib_root}" >&2
  exit 1
fi

out_name="cef_binary_${CEF_BRANCH}_${platform}_${dist_arch}_v${CEF_REVISION}"
staging="${OUTPUT_DIR}/${out_name}"
rm -rf "${staging}"
cp -a "${src_dir}" "${staging}"

# obs-studio extracts with --strip-components 1, so the tarball's top-level
# directory name is irrelevant; we archive the contents directly.
tarball="${OUTPUT_DIR}/${out_name}.tar.xz"
echo "==> Writing ${tarball}"
XZ_OPT=-T0 tar -C "${staging}" -cJf "${tarball}" .

( cd "${OUTPUT_DIR}" && sha256sum "${out_name}.tar.xz" | tee "${out_name}.tar.xz.sha256" )

echo "==> Done: ${tarball}"
