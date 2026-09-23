# SnakeHAITCH — pipeline reference

What each stage does, what it reads and writes, and which knobs affect it.
Assumes familiarity with diffusion MRI preprocessing.

For deviations from the original HAITCH, see [CHANGES.md](CHANGES.md).
For how to run it, see [README.md](README.md).

**Validation status.** Steps 1–8 are tested on macOS (Apple silicon) against a
5-run fetal cohort. The downstream block is **not validated**: it requires the
DWI to be co-registered to the subject's T2w, and in fetal data that alignment
is normally a manually initiated step (see the downstream section). Linux is
expected to work but is unrun; there, MRtrix and ANTs are native rather than
Rosetta, and segmentation uses CUDA rather than Metal.

---

## Overview

26 rules across 6 files. The default target stops after motion correction;
the downstream block runs only with `--downstream`.

```
BIDS dwi ─┬─ make_grad_table ─┐
          ├─ make_acqparams ──┤
          └─ make_grad5cls ───┤
                              │
 [1] denoise ─── [2] degibbs ─┴─ [3] rician_correct
                                        │
                        ┌───────────────┴──────────────┐
                        │                              │
            [4] split_volumes (checkpoint)    (lowb_noisemap, LOWSNR only)
                        │
            [4] segment_volumes ── segmentation_qc
                        │
            [5] union_mask ── dilate_union_mask ── crop_dwi
                        │
            [7] match_mask_to_dwi ── bias_correct
                        │
            [8] shore_prepare
                        │
              ┌─────────┴──────────┐
              │  iterate 0..N-1    │
              │  outliers → fit →  │
              │  (register)        │
              └─────────┬──────────┘
                        │
            [8] shore_finalize  ──►  desc-preproc_dwi + desc-brain_mask
                        │
                   --downstream
                        │
      mean_b0 ─ atlas_to_t2w ─ labels_to_dwi ─ extract_roi
                        └─ response_and_fod ─ tckgen_bundle ─ tract_density
```

Step numbers in brackets map to the original bash. **Step 6 (distortion
correction) is absent** — it requires multi-echo data; see
[CHANGES.md §2.6](CHANGES.md).

---

## Inputs

`config/snakebids.yml` declares two pybids components:

| component | filters | wildcards |
|---|---|---|
| `dwi` | `suffix=dwi, datatype=dwi, extension=.nii.gz` | subject, session, run |
| `t2w` | `suffix=T2w, datatype=anat, extension=.nii.gz` | subject, session |

`t2w` is optional and used only by `--downstream`; its absence is not an error
unless you request that target.

Each DWI needs `.bval`, `.bvec` and a `.json` carrying `PhaseEncodingDirection`
and `TotalReadoutTime`.

---

## Setup rules

### `make_grad_table` — `mrtrix`
FSL `.bval`/`.bvec` → MRtrix gradient table.
```
mrinfo <dwi> -fslgrad <bvec> <bval> -export_grad_mrtrix <out>
```
Needed because `dwisliceoutliergmm` rejects the FSL pair for this data
([CHANGES.md §5](CHANGES.md)).

### `make_acqparams` — `fedi`
Sidecar → FSL-style acqparams line. Maps `PhaseEncodingDirection` to a
direction vector and appends `TotalReadoutTime`. **Hard-fails** on a missing
field rather than guessing — a wrong phase-encoding direction corrupts
distortion correction invisibly.

### `make_grad5cls` — `fedi`
5-column gradient table + eddy index file, via the vendored
`create_grad5cls_index.py`. Consumed by `degibbs` and `rician_correct` through
`-import_pe_eddy`.

---

## Step 1 — `denoise` (`mrtrix`)

MP-PCA / GSVS denoising.

```
dwidenoise -noise <noisemapfull> -estimator Exp2 -nthreads N <in> <out>
mrcalc <in> <out> -subtract <residuals>
```

Emits **three** products from one pass: the denoised image, a full-volume noise
map, and residuals for inspection. The noise map is free here, which is what
makes `--rician-method STANDARD` cheap.

`--denoise-estimator` selects `Exp2` (GSVS, Cordero-Grande 2019) or `Exp1`
(original MP-PCA).

**~6–16 min per run.**

---

## Step 2 — `degibbs` (`mrtrix`)

Gibbs ringing removal (Kellner 2016), then reattachment of the gradient table
and PE/eddy metadata:

```
mrdegibbs <in> - | mrconvert - -grad <grad5cls> -import_pe_eddy <acqp> <index> <out>
```

MRtrix warns that loading FSL eddy PE information onto a non-NIfTI image "may
be erroneous". The original does the same thing, and since step 6 is absent the
PE information is never consumed downstream.

**~3–4 min per run.**

---

## Step 3 — `rician_correct` (`mrtrix`)

Rician bias correction (Ades-Aron 2019): √(S² − σ²), with non-finite values
zeroed.

The noise map σ comes from one of two places:

| `--rician-method` | source | cost |
|---|---|---|
| `STANDARD` (default) | `noisemapfull` from step 1 | free |
| `LOWSNR` | `lowb_noisemap` — a second `dwidenoise` on the lowest non-zero shell | 6–16 min |

**This is a data property, not a quality setting.** `LOWSNR` exists because in
multi-shell acquisitions high-b volumes have poor SNR and bias the estimate.
On single-shell data the "lowest shell" is 91–99% of the volumes, so the second
pass reproduces the first to within 0.72%.

---

## Step 4 — brain extraction

### `fetch_fetalbet_weights` — `fetalbet`, localrule
Pulls `AttUNet.pth` (127 MB) by downloading **one layer** of
`arfentul/fetalbet-model:first` straight from the Docker registry over HTTPS,
digest-verified. No Docker daemon, and none of the 6 GB CUDA image.

### `split_volumes` — `mrtrix`, **checkpoint**
4D → per-volume 3D files. A checkpoint because the volume count is
data-dependent (137 or 150 here) and the DAG below it cannot be known in
advance.

> Assumes single-echo. Multi-echo volumes are interleaved along the 4th axis
> and would need de-interleaving — see [CHANGES.md §13](CHANGES.md).

### `segment_volumes` — `fetalbet`
Fetal-BET: a 2D MONAI `AttentionUnet` applied slice-by-slice via `SliceInferer`.

- Device resolved at runtime: cuda → mps → xpu → cpu
- Defaults `fp16` / overlap `0.25` (upstream: fp32 / 0.50); see
  [CHANGES.md §4.1](CHANGES.md) for the Dice measurements justifying that
- `threads: 4`, `resources: gpu=1` — the latter is only enforced if the run
  passes `--resources gpu=1`, which the wrapper does
- **Resumable**: masks are written to a cache *outside* the declared output,
  because Snakemake deletes `directory()` outputs before re-running. The
  declared output is hardlinked from the cache.

**~3.1 s/volume on MPS; ~10 min per run.**

### `segmentation_qc` — `fedi`
Per-volume mask volume (mL) and connected-component count. Both degrade at
high b-value — expected, and precisely what step 5 absorbs.

---

## Step 5 — crop and skull-strip

### `union_mask` — `mrtrix`
Per volume: keep the largest connected component (`maskfilter -largest`), then
accumulate a union (`mrcalc -max`). This is what makes per-volume segmentation
failures tolerable.

### `dilate_union_mask` — `mrtrix`
`maskfilter -npass 3 dilate` (`--mask-dilate-npass`). **This defines the crop
box for everything downstream** — the reason fp16/overlap-0.25 segmentation is
safe is that all tested settings produced an identical box.

### `crop_dwi` — `mrtrix`
`mrgrid crop` of both DWI and mask to that box, then forces even dimensions on
each spatial axis.

---

## Step 7 — bias field

### `match_mask_to_dwi` — `mrtrix`
`mrtransform -interp nearest` onto the DWI grid. ANTs requires identical
geometry.

### `bias_correct` — `ants`
```
dwibiascorrect ants -mask <mask> -bias <field> <in> <out>
```
N4 on the mean b0, then applied to all volumes. Only the `Using_B0` path is
implemented; the original's `Individually` and `using_mask` branches are stubs
that print "To be implemented".

---

## Step 8 — 3D-SHORE motion correction

The core. The bash `for ((ITER=0; ITER<EPOCHS; ITER++))` loop is unrolled into
one rule instance per iteration.

### `shore_prepare` — `mrtrix`
Iteration-0 starting point. Critically, applies the **raw image's stride
layout**:

```bash
mrconvert <dwibc>  <dwimc>  -stride "$STRIDES"
mrconvert <mask>   <mcmask> -stride "$STRIDES3D"
```

Omitting this lets `mrconvert` choose its own layout, which moves the slice
axis and breaks the GMM weighting below.

### `shore_outliers_init` (iter 0) / `shore_outliers_gmm` (iter ≥1) — `shard`

Slice-wise outlier scoring. Two rules because the underlying script produces
different files depending on whether a previous prediction exists:

| | iteration 0 | iterations ≥1 |
|---|---|---|
| prior `spred` | none | `spred(i-1)` |
| modified z-score | yes | yes |
| neighbour consistency | yes | yes |
| **GMM weights** | **no** | yes |

The GMM branch shells out to **`dwisliceoutliergmm`** — a SHARD-recon binary,
not part of stock MRtrix3, compiled by `pixi run build-shard`.

> `pixi run setup` provisions the shard *prefix* (a compiler toolchain plus
> Python); `pixi run build-shard` puts the *binaries* in it. A prefix that
> exists but was never built still looks provisioned to `tool_env()`, so
> [common.smk](snakehaitch/workflow/rules/common.smk) checks for `mrinfo` and
> `dwisliceoutliergmm` in `<prefix>/bin` before the DAG is built. Without that
> check the failure lands in `shore_outliers_init` — about 30 minutes in, after
> denoising and segmentation. And it lands as a bare `FileNotFoundError` on
> **`mrinfo`**, not on `dwisliceoutliergmm`: iteration 0 skips the GMM branch
> entirely but still calls `mrinfo` to derive `AXSLICES`. The build is per
> checkout, since it installs into that project's `.pixi/`.

**The GMM reorientation.** `dwisliceoutliergmm` slices along the image's third
axis, but whether the slice axis *sits* there depends on stride layout, which
varies per acquisition. The wrapper therefore derives `AXSLICES` as the index
of the smallest raw dimension and, for axis 0 or 1, applies the original's
permutation matrix before passing `--dmrigmm` / `--maskgmm` / `--spredgmm`:

```
AXSLICES=2  ->  pass through
AXSLICES=1  ->  mrtransform -linear trans_axis1.txt
AXSLICES=0  ->  mrtransform -linear trans_axis0.txt
```

That is the entire purpose of the separate `*gmm` arguments. Getting it wrong
yields one weight row per *wrong* axis and an `IndexError` downstream.

**~27 s per job.**

### `shore_fit` — `fedi`
Weighted 3D-SHORE fit predicting a motion- and artifact-free signal.
Iteration 0 uses z-score weights, later iterations GMM weights.

Two gradient tables, kept distinct exactly as the bash does:

| argument | value |
|---|---|
| `--bvec_in` | the *carried* table — rotated from iteration 2 on |
| `--bvec_out` | always the **original** |

**~16 min per job — 61% of total pipeline cost.**

### `shore_register` — `ants`
Runs only on iterations in `--shore-iter-reg` (default 1 2 3 4).
Volume-to-volume registration of the **original** data to the current
prediction, then per-volume bvec rotation.

Each round is independent: `--rdmri` is fixed before the loop and rotation
starts from the original table, so rotations never compound.

**~7 min per job.**

### `shore_finalize` — `mrtrix`
Publishes `desc-preproc_dwi.{nii.gz,bval,bvec}` and `desc-brain_mask.nii.gz`.
The bvec index is **derived** from `--shore-iter-reg`, not hardcoded.

---

## Downstream (`--downstream`)

Requires a T2w per subject and `--atlas-dir` holding
`t2w_GA<weeks>_atlas.nii.gz` + `t2w_GA<weeks>_regional.nii.gz`.

> Ported but **not validated**. These stages hinge on DWI→T2w co-registration,
> which for fetal data is normally a manually initiated step: head pose is
> arbitrary and differs between the structural and diffusion acquisitions, so
> `antsRegistrationSyNQuick` generally needs a manual initial alignment before
> it converges.
>
> Both references acknowledge this with a `REGSTRAT=manual` path that imports a
> matrix prepared in Slicer or ITK-SNAP
> (`dMRI_HAITCH_Fixed.sh:1898`, `dMRI_HAITCH.sh:1921`). The port implements
> **only `ants`** — the fork's default (`REGSTRAT="${REGSTRAT:-ants}"`) — so
> `manual` is unavailable. Budget for supervising this stage rather than
> expecting it to run unattended.

| rule | env | action |
|---|---|---|
| `mean_b0` | mrtrix | mean b0 from the corrected data; registration moving image |
| `atlas_to_t2w` | ants | `antsRegistrationSyNQuick -t s`, atlas → subject T2w, propagate parcellation |
| `labels_to_dwi` | ants | refine b0 → T2w, apply the **inverse** to bring labels into native DWI space |
| `extract_roi` | mrtrix | binarise one atlas label |
| `response_and_fod` | mrtrix | `dwi2response dhollander` + `dwi2fod msmt_csd` (WM + CSF) |
| `tckgen_bundle` | mrtrix | iFOD2, seed ROI → include ROI, per bundle |
| `tract_density` | mrtrix | `tckmap -precise`, then threshold |

Labels move to the data; the diffusion data is never resampled.

Bundles (`config/snakebids.yml`):

| bundle | seed | include |
|---|---|---|
| AF_L / AF_R | IFG pars triangularis | superior temporal |
| SLF_L / SLF_R | IFG pars opercularis | supramarginal |

Label IDs come from `T2WAtlas_labelkey-region.txt` and are configurable.

---

## Environments

Five, each a pixi prefix that Snakemake treats as externally managed.

| env | arch (macOS) | holds |
|---|---|---|
| `mrtrix` | osx-64 (Rosetta) | MRtrix3 3.0.8 |
| `ants` | osx-64 (Rosetta) | ANTs 2.6 + MRtrix |
| `fedi` | **osx-arm64** | numpy 1.26.4, scipy 1.15.2, dipy 1.9.0, cvxpy, fury |
| `fetalbet` | **osx-arm64** | PyTorch + MONAI — native, so MPS works |
| `shard` | **osx-arm64** | SHARD-recon + MRtrix, built from source |

The split exists because `CONDA_SUBDIR` is process-wide: plain
`snakemake --use-conda` would build every environment for one architecture and
the segmentation env would lose GPU access. pixi sets it per environment.

The `fedi`/`shard` pins mirror `HAITCH/requirements.txt` exactly. They are not
arbitrary — see [CHANGES.md §3.2](CHANGES.md) for the four import failures that
loose bounds produced.

---

## Execution model

**Parallelism is bounded by the DAG, not by `--cores`.** The five per-run
chains are independent, but iterations inside a chain are strictly sequential.
Peak observed concurrency for `shore_fit` was 5 with `--cores 8`.

Consequence: wall clock scales with **iteration count**, not subject count,
until subjects exceed available cores.

**Resumption.** Snakemake's DAG replaces the original's lockfiles. A re-run
picks up at the first missing output. Segmentation additionally resumes
mid-volume via its mask cache.

**Re-run triggers.** `pixi run snakehaitch` sets `--rerun-triggers mtime`, so
editing a rule does *not* invalidate completed outputs. That is a development
convenience; for a production run pass the full set:

```bash
--rerun-triggers code input mtime params software-env
```

**On success** the workflow zips `work/` to `work.zip` in store mode via an
`onsuccess` hook — not a rule, so it is not rebuilt on every partial re-run —
then deletes the tree. `--keep-work` retains it; `--no-archive-work` skips the
step entirely.

---

## Runtime

Measured on Apple M5, 10 cores, `--cores 8`, 5 runs, steps 1–8. Parsed from
the Snakemake logs.

| rule | n | median | total job-time |
|---|---:|---:|---:|
| `shore_fit` | 30 | 967 s | **499 min** |
| `shore_register` | 20 | 414 s | 191 min |
| `segment_volumes` | 5 | 607 s | 45 min |
| `denoise` | 5 | 445 s | 43 min |
| `degibbs` | 5 | 217 s | 16 min |
| `shore_outliers_gmm` | 25 | 27 s | 11 min |
| everything else | 64 | < 80 s | 18 min |

- **Sum of job durations: 13.7 h.**
- **Wall clock, complete run: ~2 h 33 min** (≈3.7× parallel compression).

`shore_fit` is 61% of job-time and `shore_register` another 23% — together 84%.
Everything before step 8 is noise by comparison.

### Why more cores will not always help

Peak observed concurrency for `shore_fit` was **5**, with `--cores 8`. The
limit is the DAG, not the core count: there is one chain per run and iterations
within a chain are strictly sequential.

Consequently **wall clock scales with iteration count, not subject count**,
until subjects exceed available cores. A 20-run cohort costs roughly what 5 do,
given enough cores. `--shore-epochs 3` is the effective lever, removing ~15
`shore_fit` and ~10 `shore_register` jobs from the critical path.

`shore_fit` declares no `threads:`, so Snakemake budgets it as one core while
`shorerecon.py` uses more. That over-subscription is the likely reason its mean
(998 s) exceeds the 905 s measured for a single job in isolation.

### The work/ archive

On success an `onsuccess` hook zips the intermediate tree to `work.zip` in
**store mode** — its contents are `.nii.gz` and `.mif`, already compressed, so
deflating again costs significant CPU for a few percent. The archive exists to
package intermediates into one movable artefact, not to save space; for real
compression use `tar` + `zstd`.

It is a hook rather than a rule deliberately: making `work.zip` a DAG output
would force it rebuilt whenever anything under a ~49 GB tree changed.

The source tree is then **deleted**, but only after verification: the archive
is written to a `.partial` name, renamed atomically, and then every file from
a snapshot taken **before** zipping must be present in it. A missing file, or
any non-zero exit from `zip`, aborts before the `rm` and leaves the tree in
place. `zipinfo` reads only the central directory, so the check is instant even
at 49 GB — unlike `zip -T`, which would read every byte back.

> The snapshot is taken first on purpose. Counting files afterwards is racy:
> anything created while `zip` runs looks like a file the archive is missing,
> and a 19 GB archive takes minutes to write. On macOS this is routine — Finder
> writes `.DS_Store` the moment anyone opens the output folder, which is enough
> to block deletion of a perfectly good archive. `.DS_Store` is also excluded
> outright, being Finder metadata rather than pipeline output.

Deleting `work/` costs resumability. Snakemake reads it to decide what is
already done, and the segmentation mask cache lives under it, so a subsequent
incremental run — adding a subject, `--forcerun`, resuming a partial cohort —
recomputes instead of resuming. Outputs under `<output_dir>/sub-*/` live
outside `work/` and are unaffected.

```bash
--keep-work                                    # zip, keep the tree
--no-archive-work                              # neither zip nor delete
pixi run archive <output_dir>/work --keep      # by hand, keeping it
unzip -d <output_dir> <output_dir>/work.zip    # restore afterwards
```

---

## Parameter reference

All exposed on the CLI; defaults in `config/snakebids.yml`.

| parameter | default | stage |
|---|---|---|
| `--denoise-estimator` | `Exp2` | 1 |
| `--rician-method` | `STANDARD` | 3 |
| `--seg-device` | `auto` | 4 |
| `--seg-precision` | `fp16` | 4 |
| `--seg-overlap` | 0.25 | 4 |
| `--seg-batch` | 4 | 4 |
| `--mask-dilate-npass` | 3 | 5 |
| `--shore-epochs` | 6 | 8 |
| `--shore-iter-reg` | 1 2 3 4 | 8 |
| `--tract-select` | 5000 | downstream |
| `--tract-cutoff` | 0.05 | downstream |
| `--atlas-dir` | — | downstream |
| `--keep-work` | off | post |
| `--no-archive-work` | off | post |

Non-CLI parameters (whole-brain tckgen settings, atlas label IDs, bundle
definitions, Fetal-BET weight source) live under `snakehaitch:` in
`config/snakebids.yml`.

`--shore-iter-reg` is validated at parse time: any value ≥ `--shore-epochs`
raises a `WorkflowError` rather than failing mid-run.
