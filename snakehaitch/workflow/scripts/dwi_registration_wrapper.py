#!/usr/bin/env python3
"""Snakemake wrapper around FEDI dwiregistration.sh + rotate_bvecs_ants.py.

Maps to dMRI_HAITCH_Fixed.sh lines ~1786-1798: register the original volumes
to the SHORE prediction, then rotate the bvecs by each volume's affine.

STATUS: scaffold -- needs ANTs present and has not been executed end to end.
"""
import subprocess, sys
from pathlib import Path

snakemake = globals()["snakemake"]
HERE = Path(__file__).parent
xfmdir = Path(snakemake.output.xfmdir)
xfmdir.mkdir(parents=True, exist_ok=True)
Path(snakemake.output.dwi).parent.mkdir(parents=True, exist_ok=True)

# 1. volume-to-volume registration against the SHORE prediction
subprocess.run([
    "bash", str(HERE / "_fedi_dwiregistration.sh"),
    "--rdmri", str(snakemake.input.dwi),
    "--spred", str(snakemake.input.spred),
    "--workingpath", str(xfmdir),
    "--rdmrireg", str(snakemake.output.dwi),
], check=True)

# 2. rotate the gradient table by the per-volume affines
subprocess.run([
    sys.executable, str(HERE / "_fedi_rotate_bvecs_ants.py"),
    "--bvecs", str(snakemake.input.bvec),
    "--bvecsnew", str(snakemake.output.bvec),
    "--pathofmatfile", str(xfmdir),
    "--startprefix", "Transform_v",
    "--endprefix", "_0GenericAffine.mat",
], check=True)
