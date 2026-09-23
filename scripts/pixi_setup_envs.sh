#!/usr/bin/env bash
# Provision all HAITCH tool environments, each at the correct architecture.
#
# This is the thing plain `snakemake --use-conda` cannot do. CONDA_SUBDIR is
# process-wide, so Snakemake builds every env for one architecture -- which on
# Apple silicon meant the segmentation env lost Metal/MPS. pixi sets the
# platform per environment, so:
#
#   mrtrix, ants   -> osx-64 (Rosetta 2), because mrtrix3 has no osx-arm64 build
#   fedi, shard    -> native (pure python / built from source)
#   fetalbet       -> native, which is what preserves MPS on macOS and CUDA on Linux
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

HOST="$(python3 -c 'import platform,sys; m=platform.machine(); s=sys.platform
print("osx-arm64" if s=="darwin" and m=="arm64" else "osx-64" if s=="darwin" else "linux-64")')"
echo "host platform: $HOST"
echo

# pixi renames a platform when a feature raises its system requirements, e.g.
# "osx-64" becomes "osx-64-macos-14-5" once mrtrix3's __osx >=14.5 floor is
# declared. Discover the real identifier instead of hardcoding a brittle name.
target_platform_for() {
    local env="$1" want="$2"
    pixi info 2>/dev/null \
      | awk -v e="Environment: ${env}$" '
          $0 ~ e {f=1} f && /Target platforms:/ {print; exit}' \
      | sed 's/.*Target platforms: *//' \
      | tr ',' '\n' \
      | sed 's/(.*//; s/^ *//; s/ *$//' \
      | grep -E "^${want}(-|$)" \
      | head -1
}

install_env() {
    local env="$1" native="$2"
    if [[ "$native" == "native" ]]; then
        echo "--- $env (native $HOST) ---"
        pixi install -e "$env"
        return
    fi
    # Tool envs: on Apple silicon fall back to the osx-64 variant under Rosetta.
    local want="$HOST" plat
    [[ "$HOST" == "osx-arm64" ]] && want="osx-64"
    plat="$(target_platform_for "$env" "$want")"
    if [[ -z "$plat" ]]; then
        echo "ERROR: environment '$env' has no target platform matching '$want'" >&2
        exit 1
    fi
    if [[ "$plat" == "$HOST" ]]; then
        echo "--- $env (native $plat) ---"
        pixi install -e "$env"
    else
        echo "--- $env ($plat; emulated via Rosetta 2) ---"
        pixi install -e "$env" --platform "$plat"
    fi
}

install_env mrtrix tool
install_env ants   tool
install_env fedi     native
install_env fetalbet native
install_env shard    native

echo
echo "environments ready:"
for env in mrtrix ants fedi fetalbet shard; do
    p=".pixi/envs/$env"
    if [[ -d "$p" ]]; then
        sub=$(ls "$p"/conda-meta/*.json 2>/dev/null | head -1 \
              | xargs -I{} python3 -c "import json;print(json.load(open('{}')).get('subdir','?'))" 2>/dev/null)
        printf "  %-10s %-10s %s\n" "$env" "${sub:-?}" "$p"
    else
        printf "  %-10s %s\n" "$env" "MISSING"
    fi
done
echo
echo "next: pixi run build-shard   (compiles dwisliceoutliergmm; 30-60 min, once)"
