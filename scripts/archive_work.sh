#!/usr/bin/env bash
# Archive the pipeline's intermediate work/ tree into a single zip, then
# delete the tree.
#
# Called automatically by the workflow's onsuccess hook (see Snakefile), and
# available by hand as `pixi run archive`.
#
#   archive_work.sh <work_dir>            zip, verify, delete   (default)
#   archive_work.sh <work_dir> --keep     zip, verify, keep the tree
#
# STORE MODE, NOT DEFLATE
# -----------------------
# work/ is ~49 GB for a 5-run cohort and is almost entirely .nii.gz and .mif --
# already-compressed data. Deflating it again costs a great deal of CPU for a
# few percent, so the archive is created with -0 (store). The point here is
# packaging into one movable artefact, not saving space.
#
# WHY DELETION IS SAFE TO DEFAULT TO
# ----------------------------------
# Deletion only ever happens after the archive has been written to a .partial
# name, renamed into place atomically, and verified to contain exactly as many
# file entries as the tree does. If any of that fails the tree is left alone.
# Nothing is lost that `unzip work.zip` cannot restore.
#
# WHAT IT COSTS YOU
# -----------------
# Snakemake uses work/ to decide what is already done, and the segmentation
# mask cache lives there. With the tree gone, a later incremental run -- adding
# a subject, --forcerun, resuming a partial cohort -- recomputes from scratch
# instead of resuming. Completed final outputs under <output_dir>/sub-*/ are
# NOT affected; they live outside work/. Pass --keep, or --no-archive-work to
# the app, if you intend to keep working on the same output directory.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORK="${1:-derivatives/work}"
KEEP=0
case "${2:-}" in
    --keep)   KEEP=1 ;;
    --remove) ;;   # accepted for backwards compatibility; now the default
    "")       ;;
    *)        echo "[archive] unknown option: $2" >&2 ; exit 2 ;;
esac

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

if [[ "$KEEP" == "1" ]]; then
    echo "[archive] keeping $WORK as requested (--keep)"
    exit 0
fi

# Verify before deleting anything. zipinfo reads only the central directory,
# so this is fast even on a 49 GB archive -- unlike `zip -T`, which would have
# to read every byte back. Directory entries end in '/' and are excluded so
# the count matches `find -type f`.
want=$(find "$WORK" -type f | wc -l | tr -d ' ')
got=$(zipinfo -1 "$OUT" 2>/dev/null | grep -cv '/$' || true)

if [[ "$want" != "$got" ]]; then
    echo "[archive] REFUSING to delete: $OUT holds $got file entries but $WORK has $want." >&2
    echo "[archive] the tree is untouched; inspect the archive before removing it by hand." >&2
    exit 1
fi

echo "[archive] verified $got/$want files; removing $WORK"
rm -rf "$WORK"
echo "[archive] done. Restore with: unzip -d $(dirname "$WORK") $OUT"
echo "[archive] note: without work/, the next run recomputes rather than resumes."
