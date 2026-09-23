#!/usr/bin/env python3
"""One-off converter: HAITCH source layout -> valid BIDS.

The snakebids app requires a BIDS-valid dataset; the raw HAITCH tree is not
one, so pybids would index zero files. This script rewrites it.

Deviations corrected
--------------------
    source : sub-X/ses-01/dwi/run-01/sub-X_ses-01_dwi_run-01.nii.gz
    BIDS   : sub-X/ses-01/dwi/sub-X_ses-01_run-01_dwi.nii.gz

    1. drops the extra run-01/ directory level
    2. reorders entities so the `dwi` suffix is last
    3. .bvals/.bvecs      -> .bval/.bvec   (BIDS uses the singular form)
    4. _info.json         -> _dwi.json
    5. writes dataset_description.json and participants.tsv
    6. skips backup directories, Zone.Identifier files, and .DS_Store

Symlinks by default so the ~2.5 GB of imaging data is not duplicated; pass
--copy for a standalone tree (needed on filesystems without symlink support,
including some Windows configurations).

Usage
-----
    python scripts/bidsify_haitch.py data bids
    python scripts/bidsify_haitch.py data bids --copy
    python scripts/bidsify_haitch.py data bids --dry-run
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import sys
from pathlib import Path

# sub-<label>_ses-<label>_dwi_run-<index>.<ext>
SOURCE_RE = re.compile(
    r"^(?P<sub>sub-[A-Za-z0-9]+)_(?P<ses>ses-[A-Za-z0-9]+)_dwi_(?P<run>run-[0-9]+)"
    r"(?P<tail>\.nii\.gz|\.nii|\.bvals|\.bvecs|_info\.json)$"
)

# source extension -> BIDS sidecar suffix
EXT_MAP = {
    ".nii.gz": "_dwi.nii.gz",
    ".nii": "_dwi.nii.gz",     # note: .nii is gzipped on the way across
    ".bvals": "_dwi.bval",
    ".bvecs": "_dwi.bvec",
    "_info.json": "_dwi.json",
}

SKIP_DIR_PAT = re.compile(r"backup|\.git$", re.IGNORECASE)


def discover(src_root: Path):
    """Yield (subject, session, run, {bids_tail: source_path})."""
    runs: dict[tuple[str, str, str], dict[str, Path]] = {}

    for path in sorted(src_root.rglob("*")):
        if not path.is_file():
            continue
        if any(SKIP_DIR_PAT.search(part) for part in path.relative_to(src_root).parts[:-1]):
            continue
        if path.name.endswith("Zone.Identifier") or path.name == ".DS_Store":
            continue

        m = SOURCE_RE.match(path.name)
        if not m:
            continue

        key = (m["sub"], m["ses"], m["run"])
        runs.setdefault(key, {})[EXT_MAP[m["tail"]]] = path

    for key in sorted(runs):
        yield (*key, runs[key])


def place(src: Path, dst: Path, mode: str, dry: bool) -> str:
    """Materialise src at dst. Returns a one-word description of what happened."""
    if dry:
        return "would-" + mode
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() or dst.is_symlink():
        dst.unlink()

    # A bare .nii must be gzipped to satisfy the _dwi.nii.gz target name.
    if src.suffix == ".nii" and dst.name.endswith(".nii.gz"):
        import gzip

        with open(src, "rb") as fi, gzip.open(dst, "wb") as fo:
            shutil.copyfileobj(fi, fo)
        return "gzip"

    if mode == "copy":
        shutil.copy2(src, dst)
        return "copy"

    os.symlink(os.path.relpath(src.resolve(), dst.parent), dst)
    return "symlink"


def write_dataset_files(out_root: Path, subjects: list[str], dry: bool):
    if dry:
        return
    out_root.mkdir(parents=True, exist_ok=True)

    (out_root / "dataset_description.json").write_text(
        json.dumps(
            {
                "Name": "HAITCH fetal dMRI",
                "BIDSVersion": "1.8.0",
                "DatasetType": "raw",
            },
            indent=4,
        )
        + "\n"
    )

    with open(out_root / "participants.tsv", "w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t")
        w.writerow(["participant_id"])
        for s in subjects:
            w.writerow([s])

    (out_root / "README").write_text(
        "Converted from the HAITCH source layout by scripts/bidsify_haitch.py.\n"
    )


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", type=Path, help="raw HAITCH data directory")
    ap.add_argument("output", type=Path, help="BIDS dataset to create")
    ap.add_argument("--copy", action="store_true",
                    help="copy files instead of symlinking")
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would happen, change nothing")
    args = ap.parse_args(argv)

    if not args.source.is_dir():
        ap.error(f"source not found: {args.source}")

    mode = "copy" if args.copy else "symlink"
    found = list(discover(args.source))
    if not found:
        ap.error(f"no HAITCH-style DWI runs found under {args.source}")

    subjects, n_files, incomplete = [], 0, []
    for sub, ses, run, files in found:
        if sub not in subjects:
            subjects.append(sub)

        missing = {"_dwi.nii.gz", "_dwi.bval", "_dwi.bvec"} - set(files)
        if missing:
            incomplete.append((sub, ses, run, sorted(missing)))

        print(f"{sub} {ses} {run}")
        for tail, src in sorted(files.items()):
            dst = (args.output / sub / ses / "dwi" / f"{sub}_{ses}_{run}{tail}")
            action = place(src, dst, mode, args.dry_run)
            print(f"    {action:>9}  {dst.relative_to(args.output)}")
            n_files += 1

    write_dataset_files(args.output, subjects, args.dry_run)

    print()
    print(f"{len(found)} run(s), {len(subjects)} subject(s), {n_files} file(s) -> {args.output}")
    if incomplete:
        print("\nWARNING -- runs missing required files:")
        for sub, ses, run, missing in incomplete:
            print(f"  {sub} {ses} {run}: {', '.join(missing)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
