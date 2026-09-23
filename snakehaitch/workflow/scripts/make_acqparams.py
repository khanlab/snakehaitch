#!/usr/bin/env python3
"""Write an FSL-style acqparams line from a BIDS DWI sidecar.

Replaces prerequisite_files.sh :: generate_acqp. Unlike the original, there is
no DEFAULT_TOTAL_READOUT / DEFAULT_PEDIR fallback: a missing field is an error
rather than a silent guess, because guessing the phase-encoding direction
silently corrupts distortion correction.

Run as a Snakemake `script:`, so `snakemake.input` / `snakemake.output` exist.
"""

import json

PE_VECTORS = {
    "i": (1, 0, 0),
    "i-": (-1, 0, 0),
    "j": (0, 1, 0),
    "j-": (0, -1, 0),
    "k": (0, 0, 1),
    "k-": (0, 0, -1),
}


def main(json_path, out_path):
    with open(json_path) as fh:
        meta = json.load(fh)

    ped = meta.get("PhaseEncodingDirection")
    if ped not in PE_VECTORS:
        raise SystemExit(
            f"{json_path}: missing or unsupported PhaseEncodingDirection: {ped!r}. "
            f"Expected one of {sorted(PE_VECTORS)}."
        )

    trt = meta.get("TotalReadoutTime", meta.get("EstimatedTotalReadoutTime"))
    if trt in (None, ""):
        raise SystemExit(
            f"{json_path}: missing TotalReadoutTime / EstimatedTotalReadoutTime."
        )

    x, y, z = PE_VECTORS[ped]
    with open(out_path, "w") as fh:
        fh.write(f"{x} {y} {z} {float(trt)}\n")


if __name__ == "__main__":
    main(str(snakemake.input.json), str(snakemake.output.acqp))  # noqa: F821
