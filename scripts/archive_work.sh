#!/usr/bin/env bash
# Archive the pipeline's intermediate work/ tree into a single zip.
#
# Called automatically by the workflow's onsuccess hook (see Snakefile), and
# available by hand as `pixi run archive`.
#
# STORE MODE, NOT DEFLATE
# -----------------------
# work/ is ~49 GB for a 5-run cohort and is almost entirely .nii.gz and .mif --
# already-compressed data. Deflating it again costs a great deal of CPU for a
# few percent, so the archive is created with -0 (store). The point here is
# packaging into one movable artefact, not saving space.
#
# The source tree is NOT deleted. Snakemake needs work/ to decide what is
# already done; removing it forces a full recompute on the next run (hours).
# Pass --remove explicitly if you really want it gone.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORK="${1:-derivatives/work}"
REMOVE=0
[[ "${2:-}" == "--remove" ]] && REMOVE=1

if [[ ! -d "$WORK" ]]; then
    echo "[archive] nothing to do: $WORK does not exist"
    exit 0
fi

OUT="${WORK%/}.zip"
SIZE=$(du -sh "$WORK" | cut -f1)
echo "[archive] $WORK ($SIZE) -> $OUT  (store mode; contents are pre-compressed)"

# -0 store, -q quiet, -r recurse. Write to a temp name so an interrupted run
# never leaves a half-written archive that looks complete.
rm -f "${OUT}.partial"
( cd "$(dirname "$WORK")" && zip -0 -q -r "$(basename "${OUT}").partial" "$(basename "$WORK")" )
mv "${OUT}.partial" "$OUT"

echo "[archive] wrote $OUT ($(du -sh "$OUT" | cut -f1))"

if [[ "$REMOVE" == "1" ]]; then
    echo "[archive] removing $WORK as requested"
    rm -rf "$WORK"
    echo "[archive] note: the next run will recompute everything from scratch"
fi
