#!/usr/bin/env python3
"""Converter: dcm2niix series-folder layout -> valid BIDS.

For data exported as one folder per series, e.g. the FIND cohort:

    source : sub-X/ses-1/DTI/_FIND_..._33.{nii,bval,bvec,json}      main DWI
             sub-X/ses-1/DTI_b0/_FIND_..._32.{nii,bval,bvec,json}   reverse-PE b0
    BIDS   : sub-X/ses-01/dwi/sub-X_ses-01_run-01_dwi.{nii.gz,bval,bvec,json}
             sub-X/ses-01/fmap/sub-X_ses-01_dir-<PE>_run-01_epi.{nii.gz,json}

    1. zero-pads the session label (ses-1 -> ses-01) to match the cohort
    2. gzips .nii -> .nii.gz (the app filters on extension .nii.gz)
    3. places the reverse-PE series in fmap/ as _epi with IntendedFor, so the
       app's `datatype: dwi` filter does not pick it up as a second DWI run
       (the app performs no TOPUP-style correction; see CHANGES.md §2.6)
    4. writes dataset_description.json, participants.tsv and README

Usage
-----
    python scripts/bidsify_dcm2niix.py data bids
    python scripts/bidsify_dcm2niix.py data bids --dry-run
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import re
import shutil
import sys
from pathlib import Path

DWI_DIR = "DTI"
FMAP_DIR = "DTI_b0"

# dcm2niix PhaseEncodingDirection -> BIDS dir- label, for an axial slice
# with InPlanePhaseEncodingDirectionDICOM = ROW. Direction naming is
# informational only; the full vector is kept in the sidecar.
PE_LABEL = {"i": "LR", "i-": "RL", "j": "PA", "j-": "AP"}


def gzip_to(src: Path, dst: Path):
    with open(src, "rb") as fi, gzip.open(dst, "wb", compresslevel=6) as fo:
        shutil.copyfileobj(fi, fo, length=16 << 20)


def series_files(folder: Path) -> dict[str, Path]:
    """Return {ext: path} for the single series inside a dcm2niix folder."""
    files = {}
    for p in folder.iterdir():
        if p.name.startswith("."):
            continue
        ext = ".nii.gz" if p.name.endswith(".nii.gz") else p.suffix
        if ext in files:
            raise SystemExit(f"{folder}: more than one {ext} file; resolve by hand")
        files[ext] = p
    return files


def session_label(name: str) -> str:
    label = name.removeprefix("ses-")
    return f"{int(label):02d}" if label.isdigit() else label


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", type=Path, help="source data directory")
    ap.add_argument("output", type=Path, help="BIDS dataset to create")
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would happen, change nothing")
    args = ap.parse_args(argv)

    subjects, problems = [], []
    for sub_dir in sorted(args.source.glob("sub-*")):
        if not sub_dir.is_dir():
            continue
        sub = sub_dir.name
        for ses_dir in sorted(sub_dir.glob("ses-*")):
            ses = f"ses-{session_label(ses_dir.name)}"
            stem = f"{sub}_{ses}"
            out_ses = args.output / sub / ses
            print(f"{sub} {ses}  (from {ses_dir.name})")

            dwi_src = ses_dir / DWI_DIR
            if not dwi_src.is_dir():
                problems.append(f"{sub} {ses}: no {DWI_DIR}/ folder")
                continue
            dwi = series_files(dwi_src)
            missing = {".nii", ".bval", ".bvec", ".json"} - set(dwi)
            if ".nii.gz" in dwi:
                missing.discard(".nii")
            if missing:
                problems.append(f"{sub} {ses}: DWI missing {sorted(missing)}")
                continue
            if sub not in subjects:
                subjects.append(sub)

            dwi_rel = f"dwi/{stem}_run-01_dwi.nii.gz"
            plan = [
                (dwi.get(".nii.gz") or dwi[".nii"], out_ses / dwi_rel),
                (dwi[".bval"], out_ses / f"dwi/{stem}_run-01_dwi.bval"),
                (dwi[".bvec"], out_ses / f"dwi/{stem}_run-01_dwi.bvec"),
                (dwi[".json"], out_ses / f"dwi/{stem}_run-01_dwi.json"),
            ]

            fmap_json = None
            fmap_src = ses_dir / FMAP_DIR
            if fmap_src.is_dir():
                fm = series_files(fmap_src)
                meta = json.loads(fm[".json"].read_text())
                pe = PE_LABEL.get(meta.get("PhaseEncodingDirection"))
                if pe is None:
                    problems.append(f"{sub} {ses}: fmap has unknown PhaseEncodingDirection")
                else:
                    base = out_ses / f"fmap/{stem}_dir-{pe}_run-01_epi"
                    plan.append((fm.get(".nii.gz") or fm[".nii"], Path(f"{base}.nii.gz")))
                    meta["IntendedFor"] = [f"bids::{sub}/{ses}/{dwi_rel}"]
                    fmap_json = (Path(f"{base}.json"), meta)

            for src, dst in plan:
                action = "gzip" if src.suffix == ".nii" else "copy"
                print(f"    {action:>5}  {dst.relative_to(args.output)}")
                if args.dry_run:
                    continue
                dst.parent.mkdir(parents=True, exist_ok=True)
                if action == "gzip":
                    gzip_to(src, dst)
                else:
                    # copyfile, not copy2: source mtimes can be skewed (e.g.
                    # UTC stamps from a transfer read as local time), and a
                    # future mtime makes Snakemake reject every output as
                    # older than its input.
                    shutil.copyfile(src, dst)
            if fmap_json:
                print(f"    write  {fmap_json[0].relative_to(args.output)}")
                if not args.dry_run:
                    fmap_json[0].write_text(json.dumps(fmap_json[1], indent=4) + "\n")

    if not subjects:
        ap.error(f"no convertible sessions found under {args.source}")

    if not args.dry_run:
        (args.output / "dataset_description.json").write_text(json.dumps(
            {"Name": "FIND fetal dMRI", "BIDSVersion": "1.8.0", "DatasetType": "raw"},
            indent=4) + "\n")
        with open(args.output / "participants.tsv", "w", newline="") as fh:
            w = csv.writer(fh, delimiter="\t")
            w.writerow(["participant_id"])
            w.writerows([s] for s in subjects)
        (args.output / "README").write_text(
            "Converted from dcm2niix series folders by scripts/bidsify_dcm2niix.py.\n")

    print(f"\n{len(subjects)} subject(s) -> {args.output}")
    if problems:
        print("\nWARNING:")
        for p in problems:
            print(f"  {p}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
