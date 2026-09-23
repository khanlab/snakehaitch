#!/usr/bin/env bash
# Archive the pipeline's intermediate work/ tree into a single zip.
#
# Called automatically by the workflow's onsuccess hook (see Snakefile) when a
# run uses --notemp, and available by hand as `pixi run archive`.
#
#   archive_work.sh <work_dir>            zip, verify, keep     (default)
#   archive_work.sh <work_dir> --remove   zip, verify, delete the tree
#
# STORE MODE, NOT DEFLATE
# -----------------------
# work/ is ~49 GB for a 5-run cohort and is almost entirely .nii.gz and .mif --
# already-compressed data. Deflating it again costs a great deal of CPU for a
# few percent, so the archive is created with -0 (store). The point here is
# packaging into one movable artefact, not saving space.
#
# THE TREE IS KEPT BY DEFAULT
# ---------------------------
# Removing intermediates is temp()'s job, not this script's: every work/ output
# is declared temp(), so a normal run deletes each file as soon as nothing
# needs it and leaves no tree to archive at all. This script therefore only
# runs when the user asked to keep the intermediates (--notemp), and deleting
# them here would contradict that.
#
# --remove stays available for the by-hand case. When used, deletion happens
# only after the archive has been written to a .partial name, renamed into
# place atomically, and verified to contain every file present when zipping
# started. If any of that fails the tree is left alone, and nothing is lost
# that `unzip work.zip` cannot restore.
set -euo pipefail
CALLER_PWD="$PWD"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# A relative argument means what the caller typed, resolved against THEIR cwd
# -- not against the app root we just cd'd into. Without this, running
# `bash snakehaitch-app/scripts/archive_work.sh derivatives_v2/work` from the
# parent directory silently reports "nothing to do" and exits 0, because
# derivatives_v2/ does not exist relative to the app root. The bare default
# stays relative to the app root, which is where `pixi run archive` puts it.
WORK="${1:-derivatives/work}"
if [[ -n "${1:-}" && "$WORK" != /* ]]; then
    WORK="${CALLER_PWD}/${WORK}"
fi
REMOVE=0
case "${2:-}" in
    --remove) REMOVE=1 ;;
    --keep)   ;;   # accepted for symmetry; keeping is the default
    "")       ;;
    *)        echo "[archive] unknown option: $2" >&2 ; exit 2 ;;
esac

if [[ ! -d "$WORK" ]]; then
    # Print the RESOLVED path: a typo or a cwd mix-up is otherwise invisible,
    # since this exits 0 so the onsuccess hook stays non-fatal when a previous
    # run already archived and removed the tree.
    echo "[archive] nothing to do: no such directory: $WORK"
    exit 0
fi

OUT="${WORK%/}.zip"
SIZE=$(du -sh "$WORK" | cut -f1)
echo "[archive] $WORK ($SIZE) -> $OUT  (store mode; contents are pre-compressed)"

# Snapshot the file list BEFORE zipping, and verify against this snapshot
# rather than against a fresh count afterwards.
#
# Counting after the fact is racy: anything that appears in work/ while zip is
# running looks like a file the archive is missing. On macOS that is routine --
# Finder drops a .DS_Store the moment someone browses the output directory, and
# a 19 GB archive takes minutes to write. The first version of this script
# refused to delete a perfectly good archive for exactly that reason.
#
# .DS_Store is excluded outright: it is Finder metadata, not pipeline output,
# and it is the one file likely to be created mid-archive.
EXCLUDE='.DS_Store'
LIST=$(mktemp); GOT=$(mktemp); MISSING=$(mktemp)
trap 'rm -f "$LIST" "$GOT" "$MISSING"' EXIT

( cd "$(dirname "$WORK")" \
  && find "$(basename "$WORK")" -type f ! -name "$EXCLUDE" | sort ) > "$LIST"

# -0 store, -q quiet, -r recurse. Write to a temp name so an interrupted run
# never leaves a half-written archive that looks complete.
rm -f "${OUT}.partial"
( cd "$(dirname "$WORK")" \
  && zip -0 -q -r "$(basename "${OUT}").partial" "$(basename "$WORK")" -x "*/$EXCLUDE" "$EXCLUDE" )
mv "${OUT}.partial" "$OUT"

echo "[archive] wrote $OUT ($(du -sh "$OUT" | cut -f1))"

if [[ "$REMOVE" != "1" ]]; then
    echo "[archive] keeping $WORK (pass --remove to delete it)"
    exit 0
fi

# Verify before deleting anything: every file in the pre-zip snapshot must be
# present in the archive. A set difference, not a count -- extra entries in the
# archive are harmless, absent ones are not. zipinfo reads only the central
# directory, so this is fast even on a 49 GB archive, unlike `zip -T` which
# would have to read every byte back. Directory entries end in '/'.
zipinfo -1 "$OUT" 2>/dev/null | grep -v '/$' | sort > "$GOT"
comm -23 "$LIST" "$GOT" > "$MISSING"

if [[ -s "$MISSING" ]]; then
    echo "[archive] REFUSING to delete: $(wc -l < "$MISSING" | tr -d ' ') file(s) are in $WORK but not in $OUT:" >&2
    head -10 "$MISSING" | sed 's/^/[archive]   /' >&2
    echo "[archive] the tree is untouched; inspect the archive before removing it by hand." >&2
    exit 1
fi

echo "[archive] verified $(wc -l < "$LIST" | tr -d ' ') files; removing $WORK as requested (--remove)"
rm -rf "$WORK"
echo "[archive] done. Restore with: unzip -d $(dirname "$WORK") $OUT"
echo "[archive] note: without work/, the next run recomputes rather than resumes."
