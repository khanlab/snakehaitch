#!/usr/bin/env python3
"""Snakemake wrapper around the vendored FEDI outlierdetection.py.

The FEDI helpers are argparse CLIs that write a fixed set of filenames into an
--outpath directory. This wrapper translates Snakemake's input/output objects
into that calling convention and renames the products to the BIDS-style paths
the rules declare.

It also reproduces the step-8 GMM reorientation the bash performs, which is the
reason outlierdetection.py takes separate --dmri/--dmrigmm, --mask/--maskgmm
and --spred/--spredgmm arguments. See reorient_for_gmm() below.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

snakemake = globals()["snakemake"]

HERE = Path(__file__).parent
FEDI = HERE / "_fedi_outlierdetection.py"

# Permutation matrices copied verbatim from dMRI_HAITCH_Fixed.sh (lines
# 1719-1745). They rotate the volume so the slice axis lands where
# dwisliceoutliergmm expects it (the third axis).
TRANS = {
    0: "0 0  1 0\n1 0 0 0\n0 1  0 0\n0 0  0 1\n",
    1: "1 0  0 0\n0 0 -1 0\n0 1  0 0\n0 0  0 1\n",
}


def axslices(raw_dwi):
    """Index of the smallest spatial dimension -- the bash's AXSLICES.

    Derived exactly as dMRI_HAITCH_Fixed.sh does at step 0 (lines 137-149):
    take mrinfo -size of the RAW input and find the axis holding the minimum.
    It must come from the raw image, not from the cropped working volume,
    because that is what the original uses.

    This varies across acquisitions in the same study -- for this dataset,
    three runs give AXSLICES=1 and two give AXSLICES=2 -- so it cannot be
    assumed. Getting it wrong makes dwisliceoutliergmm emit one row per *wrong*
    axis, and gmm_weighting then dies with
        IndexError: index 32 is out of bounds for axis 2 with size 32
    """
    out = subprocess.run(["mrinfo", "-size", str(raw_dwi)],
                         capture_output=True, text=True, check=True)
    dims = [int(x) for x in out.stdout.split()[:3]]
    return dims.index(min(dims))


def reorient_for_gmm(images, axis, workdir):
    """Apply the trans_axis<N> permutation, as the bash does inside the loop.

    Returns a {key: path} map. For AXSLICES==2 the bash passes the images
    through untouched (WORKING_DMRI_GMM=${WORKING_DMRI}), so we do the same.
    """
    if axis == 2:
        return dict(images)

    matrix = workdir / f"trans_axis{axis}.txt"
    matrix.write_text(TRANS[axis])

    out = {}
    for key, src in images.items():
        dst = workdir / f"{key}_GMM.nii.gz"
        subprocess.run(
            ["mrtransform", "-linear", str(matrix), str(src), str(dst),
             "-force", "-quiet"],
            check=True,
        )
        out[key] = dst
    return out


it = snakemake.wildcards.iter
mz_name = f"fsliceweights_mzscore_{it}.txt"
gmm_name = f"fsliceweights_gmmodel_{it}.txt"

prev = getattr(snakemake.input, "prev_spred", None)
grad = getattr(snakemake.input, "grad", None)

with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)

    # --- GMM reorientation -------------------------------------------------
    axis = axslices(snakemake.input.raw)
    to_reorient = {"dmri": snakemake.input.dwi, "mask": snakemake.input.mask}
    if prev:
        to_reorient["spred"] = prev
    gmm = reorient_for_gmm(to_reorient, axis, tmpdir)
    print(f"[gmm] AXSLICES={axis} "
          f"({'pass-through' if axis == 2 else f'reoriented via trans_axis{axis}'})",
          flush=True)

    cmd = [
        sys.executable, str(FEDI),
        "--dmri", str(snakemake.input.dwi),
        "--dmrigmm", str(gmm["dmri"]),
        "--bval", str(snakemake.input.bval),
        "--bvec", str(snakemake.input.bvec),
        "--outpath", str(tmpdir),
        "--fsliceweights_mzscore", mz_name,
        "--fsliceweights_angle_neighbors", f"fsliceweights_angle_neighbors_{it}.txt",
        "--fsliceweights_corre_neighbors", f"fsliceweights_corre_neighbors_{it}.txt",
        "--fsliceweights_gmmodel", gmm_name,
        "--fvoxelweights_shorebased", f"fvoxelweights_shore_{it}.nii.gz",
        "--mask", str(snakemake.input.mask),
        "--maskgmm", str(gmm["mask"]),
    ]

    # The previous iteration's SHORE prediction is what makes the loop
    # converge; absent only at iteration 0.
    if prev:
        cmd += ["--spred", str(prev), "--spredgmm", str(gmm["spred"])]

    # Prefer the MRtrix-format gradient table for the GMM step; dwisliceoutliergmm
    # rejects this dataset's FSL pair. Only the GMM rule declares it.
    if grad:
        cmd += ["--grad", str(grad)]

    print(" ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)

    # Iteration 0 declares only the z-score output, because the GMM branch
    # needs a prior prediction and is skipped there. Collect whichever outputs
    # this rule actually declared.
    wanted = [(mz_name, snakemake.output.weights_mz)]
    gmm_out = getattr(snakemake.output, "weights_gmm", None)
    if gmm_out is not None:
        wanted.append((gmm_name, gmm_out))

    for produced, declared in wanted:
        src = tmpdir / produced
        if not src.exists():
            raise SystemExit(f"outlierdetection.py did not produce {produced}")
        Path(declared).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, declared)
