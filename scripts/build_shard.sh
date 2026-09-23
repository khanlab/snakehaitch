#!/usr/bin/env bash
# Compile MRtrix3 + the SHARD-recon module into the pixi `shard` environment.
#
# WHY THIS IS A PIXI TASK, NOT A SNAKEMAKE POST-DEPLOY SCRIPT
# -----------------------------------------------------------
# It used to be envs/shard.post-deploy.sh. Three things were wrong with that:
#   1. Snakemake deletes the env directory when a post-deploy script fails,
#      destroying configure.log -- the one file needed to debug the failure.
#   2. Post-deploy scripts run on *every* env creation, surprising the user with
#      a 30-60 minute compile in the middle of a pipeline run.
#   3. Snakemake refuses post-deploy scripts on Windows outright
#      (deployment/conda.py: `if ON_WINDOWS: raise WorkflowError(...)`).
# As an explicit pixi task it is idempotent, resumable, and debuggable.
#
# VERSION PINS
# ------------
# Taken from arfentul/shard-recon:latest, the reference image published by the
# HAITCH authors: its MRtrix3 reports 3.0.8-54-g03a8c7b0 and its shard tree is
# at 9c734a4. The shard-recon README names MRtrix 3.0.5, but that contradicts
# the authors' own working build, so we follow the container.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PREFIX="$(pwd)/.pixi/envs/shard"
MRTRIX_REF="${MRTRIX_REF:-03a8c7b05}"
SHARD_REF="${SHARD_REF:-9c734a4}"
JOBS="${SHARD_BUILD_JOBS:-$( (command -v nproc >/dev/null && nproc) || sysctl -n hw.ncpu || echo 4 )}"
SRC="${PREFIX}/src"

if [[ ! -d "$PREFIX" ]]; then
    echo "ERROR: $PREFIX missing. Run 'pixi run setup' first." >&2
    exit 1
fi

# ---------------------------------------------------------------- compiler ---
# MRtrix's configure probes for the BARE names clang++/g++, but conda ships
# prefixed binaries (arm64-apple-darwin20.0.0-clang++). Worse, configure
# deliberately IGNORES $CXX when it points into a conda prefix:
#
#   if not conda and 'conda' in cxx_env:
#       report('WARNING: anaconda/miniconda compiler ... ignored to avoid conflicts')
#
# The `-conda` flag (configure line 232) disables that guard. So BOTH are
# required: export CXX *and* pass -conda. Setting only one silently fails.
CXX_BIN="$(ls "${PREFIX}"/bin/*-clang++ "${PREFIX}"/bin/*-g++ 2>/dev/null | head -1 || true)"
[[ -z "$CXX_BIN" ]] && CXX_BIN="$(ls "${PREFIX}/bin/clang++" "${PREFIX}/bin/g++" 2>/dev/null | head -1 || true)"
if [[ -z "$CXX_BIN" ]]; then
    echo "ERROR: no C++ compiler found in ${PREFIX}/bin" >&2
    ls "${PREFIX}/bin" | grep -iE 'clang|gcc|g\+\+' >&2 || true
    exit 1
fi
export CXX="$CXX_BIN"
export CC="${CXX_BIN%++}"          # clang++ -> clang
[[ -x "$CC" ]] || export CC="$CXX_BIN"

export EIGEN_CFLAGS="-isystem ${PREFIX}/include/eigen3"
export ZLIB_CFLAGS="-I${PREFIX}/include"
export ZLIB_LDFLAGS="-L${PREFIX}/lib -lz"
export PATH="${PREFIX}/bin:${PATH}"

echo "=============================================================="
echo " Building SHARD-recon (dwisliceoutliergmm)"
echo "   prefix : $PREFIX"
echo "   CXX    : $CXX"
echo "   mrtrix : $MRTRIX_REF"
echo "   shard  : $SHARD_REF"
echo "   jobs   : $JOBS"
echo " First run compiles MRtrix3 from source: 30-60 minutes."
echo "=============================================================="
mkdir -p "$SRC"

# ------------------------------------------------------------- MRtrix core ---
if [[ ! -x "${SRC}/mrtrix3/bin/mrinfo" ]]; then
    if [[ ! -d "${SRC}/mrtrix3/.git" ]]; then
        rm -rf "${SRC}/mrtrix3"
        git clone https://github.com/MRtrix3/mrtrix3.git "${SRC}/mrtrix3"
    fi
    git -C "${SRC}/mrtrix3" checkout --quiet "$MRTRIX_REF"
    pushd "${SRC}/mrtrix3" >/dev/null
    # -conda : honour $CXX from a conda prefix (see above)
    # -nogui : the reference image builds WITH the GUI, pulling Qt5 + mesa. Every
    #          shard binary we call is command-line, so this drops that chain.
    ./configure -conda -nogui || { echo "--- configure.log ---"; tail -40 configure.log 2>/dev/null; exit 1; }
    NUMBER_OF_PROCESSORS="$JOBS" ./build
    popd >/dev/null
else
    echo "[skip] MRtrix3 already built"
fi

# ------------------------------------------------------------ shard module ---
if [[ ! -x "${SRC}/shard-recon/bin/dwisliceoutliergmm" ]]; then
    if [[ ! -d "${SRC}/shard-recon/.git" ]]; then
        rm -rf "${SRC}/shard-recon"
        git clone https://github.com/dchristiaens/shard-recon.git "${SRC}/shard-recon"
    fi
    pushd "${SRC}/shard-recon" >/dev/null
    git checkout --quiet "$SHARD_REF"
    ln -sf "${SRC}/mrtrix3/build" build
    ln -sf "${SRC}/mrtrix3/bin/mrtrix3.py" bin/mrtrix3.py
    NUMBER_OF_PROCESSORS="$JOBS" ./build
    popd >/dev/null
else
    echo "[skip] shard-recon already built"
fi

# ------------------------------------------------------ expose on env PATH ---
for exe in "${SRC}/shard-recon/bin/"*; do
    [[ -f "$exe" && -x "$exe" ]] || continue
    ln -sf "$exe" "${PREFIX}/bin/$(basename "$exe")"
done

# The core MRtrix binaries too. outlier_detection_wrapper.py needs mrinfo (to
# derive AXSLICES from the raw input, as the bash does at step 0) and
# mrtransform (to build the reoriented GMM copies). They cannot come from the
# conda mrtrix3 package: that has no osx-arm64 build, so pulling it in would
# force this environment to osx-64 and lose the native source build.
for exe in "${SRC}/mrtrix3/bin/"*; do
    [[ -f "$exe" && -x "$exe" ]] || continue
    ln -sf "$exe" "${PREFIX}/bin/$(basename "$exe")"
done
ln -sf "${SRC}/mrtrix3/lib/"libmrtrix* "${PREFIX}/lib/" 2>/dev/null || true

if ! "${PREFIX}/bin/dwisliceoutliergmm" -help >/dev/null 2>&1; then
    echo "ERROR: dwisliceoutliergmm built but will not run." >&2
    exit 1
fi
echo "[ok] ${PREFIX}/bin/dwisliceoutliergmm"
