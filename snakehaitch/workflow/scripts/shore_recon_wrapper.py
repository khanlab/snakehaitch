#!/usr/bin/env python3
"""Snakemake wrapper around the vendored FEDI shorerecon.py.

Maps to dMRI_HAITCH_Fixed.sh lines ~1769-1773.

STATUS: scaffold -- argument mapping transcribed from the bash, not yet run
against real data. Note `-do_not_use_mask` is passed exactly as the original
did (the mask is supplied but deliberately not applied during the fit).
"""
import subprocess, sys
from pathlib import Path

snakemake = globals()["snakemake"]
FEDI = Path(__file__).parent / "_fedi_shorerecon.py"
Path(snakemake.output.spred).parent.mkdir(parents=True, exist_ok=True)

cmd = [
    sys.executable, str(FEDI),
    "--dmri", str(snakemake.input.dwi),
    "--bval", str(snakemake.input.bval),
    # The bash keeps these distinct (line 1809): bvec_in is the carried table,
    # rotated from iteration 2 on; bvec_out is always the original.
    "--bvec_in", str(snakemake.input.bvec),
    "--bvec_out", str(snakemake.input.bvec_orig),
    "--mask", str(snakemake.input.mask),
    "--weights", str(snakemake.input.weights),
    "--fspred", str(snakemake.output.spred),
    "-do_not_use_mask",
]
print(" ".join(cmd), flush=True)
subprocess.run(cmd, check=True)
