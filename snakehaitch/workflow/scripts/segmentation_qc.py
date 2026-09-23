#!/usr/bin/env python3
"""Per-volume brain-mask volume plot, to spot segmentation outliers.

Replaces the FEDI segm_outliers.py call in step 4. Reports mask volume and
connected-component count per DWI volume; both degrade at high b-value, which
is expected and is what the step-5 union+dilate absorbs.
"""
import glob, os, re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import nibabel as nib
import numpy as np
from scipy import ndimage

snakemake = globals()["snakemake"]

masks = sorted(
    glob.glob(os.path.join(str(snakemake.input.maskdir), "*mask.nii.gz")),
    key=lambda p: int(re.search(r"_v(\d+)", os.path.basename(p)).group(1)),
)
if not masks:
    raise SystemExit(f"no masks found in {snakemake.input.maskdir}")

idx, vols, comps = [], [], []
for m in masks:
    a = np.asanyarray(nib.load(m).dataobj).astype(bool)
    zx, zy, zz = nib.load(m).header.get_zooms()[:3]
    idx.append(int(re.search(r"_v(\d+)", os.path.basename(m)).group(1)))
    vols.append(a.sum() * zx * zy * zz / 1000.0)
    comps.append(ndimage.label(a)[1])

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(11, 6), sharex=True)
ax1.plot(idx, vols, ".-", lw=0.8, ms=4)
med = float(np.median(vols))
ax1.axhline(med, ls="--", lw=0.8, color="grey", label=f"median {med:.0f} mL")
ax1.set_ylabel("mask volume (mL)"); ax1.legend(); ax1.grid(alpha=0.3)
ax2.plot(idx, comps, ".-", lw=0.8, ms=4, color="tab:orange")
ax2.set_ylabel("connected components"); ax2.set_xlabel("DWI volume index")
ax2.grid(alpha=0.3)
fig.suptitle(f"Fetal-BET per-volume masks -- {os.path.basename(str(snakemake.output.plot))}")
fig.tight_layout()
os.makedirs(os.path.dirname(str(snakemake.output.plot)), exist_ok=True)
fig.savefig(str(snakemake.output.plot), dpi=110)
print(f"[qc] {len(masks)} volumes, median {med:.1f} mL")
