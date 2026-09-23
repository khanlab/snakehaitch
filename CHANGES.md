# HAITCH → Snakebids: change report

What this port changes relative to the two reference implementations, and why.

**Reference A — upstream HAITCH**
<https://github.com/IntelligentImaging/HAITCH> (local checkout `HAITCH/`).
The published pipeline and the `src/` FEDI helper scripts.

**Reference B — locally adapted HAITCH**
<https://github.com/Andy1Yang1/HAITECH-Locally-Adapted-Version> (local
checkout `HAITECH-Locally-Adapted-Version/`). The lab's fork, with its own
driver scripts; this is the implementation the port targets for behavioural
equivalence.

**This port**: `snakehaitch-app/` — a Snakebids BIDS app, driven by `pixi`.

Other upstream components referenced throughout:

| component | source |
|---|---|
| SHARD-recon (`dwisliceoutliergmm`) | <https://github.com/dchristiaens/shard-recon> |
| MRtrix3 | <https://github.com/MRtrix3/mrtrix3> |
| Snakebids | <https://github.com/khanlab/snakebids> |
| Fetal-BET weights | `docker.io/arfentul/fetalbet-model:first` |
| SHARD-recon reference build | `docker.io/arfentul/shard-recon:latest` |

Status: steps 1–8 run to completion on all 5 runs of the FIND cohort
(sub-FINDM073 ses-01, sub-FINDM075 ses-01/02, sub-FINDM081 ses-01/02),
producing `desc-preproc_dwi.{nii.gz,bval,bvec}` and `desc-brain_mask.nii.gz`
per run, plus 5 segmentation QC plots. The downstream stages (atlas → T2w →
DWI, ROI extraction, AF/SLF tractography) are ported but unexercised — the
cohort has no T2w images.

---

## 1. Design principle

The pipeline's **numerical behaviour is intended to be identical** to Reference
B. Every deviation below is either (a) infrastructure that does not touch the
maths, or (b) a bug fix, documented with the bash line number it derives from.

The vendored FEDI scripts are byte-identical to `HAITCH/src/` with **one
exception**, listed in §5.

---

## 2. Architecture changes (no effect on results)

### 2.1 Discovery: pybids replaces the `find` loop

Reference B discovers work with:

```bash
find "$PROJECT_DIR/data" -type d -path '*/ses-*/dwi/run-*'
```

The port uses pybids via `generate_inputs()`. Consequences:

- **The input must be a valid BIDS dataset.** The source layout is not one, so
  `scripts/bidsify_haitch.py` converts it (§6).
- Subject/session/run selection comes from `--participant-label`,
  `--filter-dwi` etc. rather than positional arguments.

### 2.2 Prerequisite pass folded into the DAG

`prerequisite_files.sh` had to be run manually before `run_batch_haitch.sh`.
It is now two ordinary rules — `make_grad_table` and `make_acqparams` — built
on demand. There is no separate pre-step.

One behavioural difference: `make_acqparams` **hard-fails** on a missing
`PhaseEncodingDirection` or `TotalReadoutTime`, where the original silently
substituted `DEFAULT_PEDIR` / `DEFAULT_TOTAL_READOUT`. Guessing a
phase-encoding direction corrupts distortion correction without any visible
error, so this is deliberate.

### 2.3 Lockfiles replaced by the DAG

`locks/lock_STEP*` and the `TODO`/`DONE` switchboard in
`user_config_steps1_8.sh` are gone. Snakemake's dependency graph decides what
to run; a re-run resumes from the first missing output.

### 2.4 Step 8 loop unrolled

The bash `for ((ITER=0; ITER<$EPOCHS; ITER++))` is unrolled into one rule per
iteration (`shore_outliers_init`, `shore_outliers_gmm`, `shore_fit`,
`shore_register`). Same operations, same order. This buys resumability and
per-iteration provenance.

It also removes a latent bug: the bash hardcodes `rotated_bvecs3` when handing
off to step 9, which silently desynchronises if `ITER_REG` is retuned. The port
derives that index from `--shore-iter-reg` and validates the range at parse
time.

### 2.5 Inputs are immutable

Reference B step 1 ran:

```bash
mrconvert $INPUT -set_property comments "FEDI Pipeline" $INPUT -force
```

which rewrites the raw NIfTI in place. Dropped — Snakemake treats inputs as
read-only.

### 2.6 Step 6 not ported

Distortion correction. **This is governed by echo count, not shell count** —
a distinct property from the single-shell structure that drives the Rician
choice in §11. The two happen to coincide in this cohort, but they are
unrelated conditions.

The bash gates step 6 on two things (line 662):

```bash
[[ $DWIMODALITY == "dwiME" ]] && [[ $NUMBER_ECHOTIME -gt 1 ]]
```

where `NUMBER_ECHOTIME` is the number of unique values in the sidecar's
`EchoTime` field (1 if scalar). Both conditions fail for this cohort:

| run | EchoTime | NUMBER_ECHOTIME | PhaseEncodingDirection |
|---|---|---|---|
| FINDM073 ses-01 | 0.0959 | 1 | `i-` |
| FINDM075 ses-01 | 0.0979 | 1 | `i-` |
| FINDM075 ses-02 | 0.0876 | 1 | `j` |
| FINDM081 ses-01 | 0.0920 | 1 | `i-` |
| FINDM081 ses-02 | 0.0981 | 1 | `j` |

Every scan is single-echo, and `DWIMODALITY` defaults to `dwi` rather than
`dwiME`. Control therefore falls to the fallback branch (line 1512), which
prints *"No 2nd TE is available ==> No Distortion Correction will be done"* and
does nothing. Porting it would mean porting dead code.

**To enable it you would need multi-echo data**, not multi-shell:
`DWIMODALITY=dwiME` and a sidecar whose `EchoTime` is an array. The step would
then have to be written — the multi-echo branch (lines 662–1510, covering the
BM / EPIC / TOPUP / VOSS variants) is the largest single block in the original
and has no counterpart here.

Two consequences worth noting:

- The phase-encoding information assembled by `make_acqparams` is currently
  unused downstream. It is still produced, because `degibbs` and
  `rician_correct` attach it to the `.mif` header via `-import_pe_eddy`,
  matching the original.
- Each run has a **single** phase-encoding direction, so there is no
  blip-up/blip-down pair for a TOPUP-style correction either. Note the
  direction is not constant across the cohort (`i-` for three runs, `j` for
  two), which would matter if distortion correction were ever added.

### 2.7 Steps 9–10 moved behind `--downstream`

Matching how they are actually used: disabled in `user_config_steps1_8.sh`, run
separately afterwards. The four downstream bash scripts are ported into
`rules/downstream.smk`.

---

## 3. Environment and platform

### 3.1 pixi provides per-rule environments

Each rule points `conda:` at a pixi prefix (`.pixi/envs/<name>`). Snakemake
classifies a directory as `CondaEnvSpecType.DIR` → `is_externally_managed` →
`create_conda_envs()` skips it, so Snakemake never calls `conda env create`.

This matters because `CONDA_SUBDIR` is **process-wide**: `snakemake --use-conda`
builds every environment for one architecture. pixi sets it per environment,
which is what allows:

| env | arch | contents |
|---|---|---|
| `mrtrix` | `osx-64` (Rosetta) | MRtrix3 3.0.8 — no `osx-arm64` build exists |
| `ants` | `osx-64` (Rosetta) | ANTs 2.6 + MRtrix |
| `fedi` | **`osx-arm64`** | FEDI python stack |
| `fetalbet` | **`osx-arm64`** | PyTorch + MONAI — native, so **Metal/MPS works** |
| `shard` | **`osx-arm64`** | SHARD-recon, built from source |

Without the split, the segmentation environment would be `osx-64` and lose GPU
access: measured 3.08 s/volume on MPS vs 32.78 s/volume on CPU.

### 3.2 Dependency pins mirror `HAITCH/requirements.txt`

The FEDI scripts are written against a 2024-era stack and do not declare it.
Loose bounds produced four consecutive import failures:

| resolved | required | failure |
|---|---|---|
| python 3.12 | 3.11 | `distutils` removed from stdlib (`FEDI_shore`) |
| scipy 1.17.1 | 1.15.2 | `scipy.special.lpn` removed (`FEDI_shm`) |
| fury absent | 0.11.0 | `dipy.viz.window` not exposed (`shorerecon`, dead import) |
| dipy 1.12.1 | 1.9.0 | requires numpy ≥ 2 while numpy pinned < 2 |
| cvxpy absent | 1.6.0 | SHORE model raises at construction |

`cvxpy` is invisible to static analysis — dipy's `optional_package("cvxpy")`
takes a string. `fedi` and `shard` now pin the upstream versions exactly.

### 3.3 SHARD-recon built from source as a pixi task

`dwisliceoutliergmm` is required by `outlierdetection.py`, is not packaged on
any conda channel, and is an MRtrix3 *module*. `pixi run build-shard` compiles
MRtrix3 + the module (~30–60 min, once).

Version pins follow `arfentul/shard-recon:latest`, the authors' reference
image: MRtrix3 `03a8c7b05` (3.0.8-54) and shard-recon `9c734a4`. The
shard-recon README names MRtrix 3.0.5; that contradicts the authors' own
working build, so the container wins.

Two build details:

- MRtrix's `configure` probes for bare `clang++`/`g++`, and **deliberately
  ignores `$CXX` when it points into a conda prefix**. Both `export CXX=…` and
  `./configure -conda` are required; either alone fails silently.
- Configured `-nogui`, unlike the reference image, dropping the Qt5 + mesa
  chain. Every shard binary used here is command-line.

### 3.4 Windows

Not supported. `mrtrix3` and `ants` publish no `win-64` build on any channel,
and Snakemake refuses conda post-deploy scripts on Windows outright. Use WSL2
(which is `linux-64`) or a container.

---

## 4. Fetal-BET: container replaced by a conda environment

Reference B step 4 runs:

```bash
docker run --gpus all ... arfentul/fetalbet-model:first \
  python /app/src/codes/inference.py ...
```

a 6 GB `linux/amd64` CUDA image, unusable off NVIDIA hardware. Replaced by
`workflow/scripts/fetalbet_inference.py` in the `fetalbet` env.

**Same model, same weights, same pre/post-processing.** The changes:

1. **Device auto-detection** (cuda → mps → xpu → cpu). The original hardcodes
   CUDA-or-CPU.
2. **No `DataParallel`.** The shipped checkpoint was saved from a DataParallel
   model, so every key is prefixed `module.`; the original relies on its
   `--n_gpu` default of **2** to rebuild that wrapper, which only makes sense
   on a multi-GPU NVIDIA box. The port strips the prefix and loads a plain
   model — identical on every backend.
3. **float32 pinned on input.** MPS has no float64; `Spacingd` can upcast.
4. **Weights fetched as a single 137 MB registry layer** rather than pulling
   the 6 GB image. Plain HTTPS, digest-verified, no Docker daemon.
5. **Resumable.** Masks are written to a cache outside the declared output,
   because Snakemake deletes `directory()` outputs before re-running. An
   interrupted segmentation resumes instead of restarting from volume 0
   (observed resuming at 27/137 and 63/137).

### 4.1 Changed defaults — the only intentional numerical deviation

| | original | port |
|---|---|---|
| precision | fp32 | **fp16** |
| sliding-window overlap | 0.50 | **0.25** |

Measured on Apple M5 over six volumes of sub-FINDM075 ses-01, against the
fp32 / 0.50 reference:

| config | s/volume | speedup | Dice (raw) | Dice after step-5 union+dilate |
|---|---|---|---|---|
| fp32, 0.50 | 10.80 | 1.00× | reference | reference |
| fp16, 0.50 | 8.25 | 1.31× | 0.999907 | 0.999992 |
| fp16, 0.25 | 3.08 | **3.50×** | 0.991954 | 0.997088 |

**All configurations produced an identical step-5 crop bounding box**, which is
the only product of this step that propagates downstream.

`--seg-precision fp32 --seg-overlap 0.50` restores upstream behaviour exactly.
Caveat: validated on 6 volumes from one subject.

---

## 5. The one modified FEDI script

`_fedi_outlierdetection.py` — **12 lines added**, marked
`HAITCH-SNAKEBIDS PATCH`. Every other vendored script is byte-identical to
`HAITCH/src/` (verified by `diff`).

An optional `--grad` argument was added, and `gmm_weighting()` uses it in place
of `-fslgrad` when present. Reason: `dwisliceoutliergmm` rejects this dataset's
FSL bvec/bval pair —

```
[ERROR] Corrupt content in bvecs/bvals data (NaN bvec direction but non-zero value in bval)
```

— even though the table is valid (150 bvals; 14 zero-norm vectors sitting
exactly on the 14 b=0 volumes; no NaNs) and `mrinfo` from the *same* MRtrix
build imports it without complaint. Substituting dummy unit vectors for the b=0
directions does **not** help, so the trigger is still unidentified. Passing the
MRtrix-format table works.

The gradient scheme is unchanged: `grad.txt` is produced by
`mrinfo -export_grad_mrtrix` from that same bvec/bval pair. The authors
anticipated this — the line above the patched block reads
`# it would be better if we use grad instead if fsl bval bvec`.

---

## 6. `scripts/bidsify_haitch.py` — new

The source tree is not BIDS-valid, so pybids indexes nothing. Corrections:

| source | BIDS |
|---|---|
| `…/dwi/run-01/sub-X_ses-01_dwi_run-01.nii.gz` | `…/dwi/sub-X_ses-01_run-01_dwi.nii.gz` |
| extra `run-01/` directory level | removed |
| `_dwi_run-01` (suffix before entity) | `_run-01_dwi` |
| `.bvals` / `.bvecs` | `.bval` / `.bvec` |
| `_info.json` | `_dwi.json` |
| no `dataset_description.json` | written |

Symlinks by default (`--copy` available). Skips backup directories and
`Zone.Identifier` files. Gzips bare `.nii` — which incidentally fixes
sub-FINDM073, silently skipped by both references because their globs only
match `*.nii.gz`.

---

## 7. Bugs found in the reference implementations

Fixed in `HAITECH-Locally-Adapted-Version/` (7 files changed, +137/−51):

1. **`AF_SLF_tractography.sh` was missing its closing `done`.** The
   `while read RUN_DIR` loop is never closed, so bash cannot parse the file.
   Pre-existing at `HEAD` — the script could never have run.
2. **`docker run -v --rm`** in both segmentation branches. `-v` consumes
   `--rm` as its volume argument; Docker rejects it as a non-absolute mount
   path.
3. **BSD-incompatible `sed`.** The step-4 rename loop uses GNU basic-regex
   `\+`, which BSD/macOS sed reads as a literal plus. The substitution
   silently no-ops and produces
   `..._predicted_mask.nii.gz_mask.nii.gz`, breaking step 5. Switched to
   `sed -E`. The same pattern remains in `HAITCH/src/segment_fetalbrain.sh:121`
   (untouched).
4. **`rotated_bvecs3` hardcoded** — now derived from `SHORE_ITER_REG` with a
   guard.

Also added there: `haitch_params.sh`, centralising every hyperparameter that
was previously a literal scattered through the scripts.

Not fixed (bash 4+ only): `dMRI_HAITCH_Fixed.sh` uses `exec &>>`, which macOS's
bash 3.2 cannot parse at all. Fine on Linux; on macOS it needs `brew install bash`.

---

## 8. Port bugs found and fixed during validation

These were defects in **this port**, not in the references. Listed because each
is a place where the port initially diverged from the original.

1. **Unconstrained `{iter}` wildcard** — `iter-1` parsed as iteration `-1` and
   the DAG recursed to `desc-iter-233` before exhausting the stack.
2. **Iteration 0 declared an impossible output.** `outlierdetection.py` only
   emits GMM weights when `--spred` is given (line 617), so iteration 0 cannot
   produce them. Split into `shore_outliers_init` / `shore_outliers_gmm`.
3. **Orphaned iteration-0 prediction** — the previous iteration's `spred` was
   not passed to outlier detection, which is what makes the loop converge.
4. **`/dev/null` as an MRtrix output** — MRtrix picks its format from the file
   extension and rejects an extension-less path.
5. **Thread over-subscription** — `lowb_noisemap` declared no `threads:` while
   MRtrix grabbed every core; `segment_volumes` likewise. Note `resources: gpu=1`
   is inert unless the run also passes `--resources gpu=1`, which the wrapper
   now does.
6. **`bvec` fidelity (§9).**
7. **`AXSLICES` assumed rather than derived (§10).**

---

## 9. Gradient-table handling in step 8

Traced from `dMRI_HAITCH_Fixed.sh`:

```bash
BVECSTE="${BVECS}"                                            # original, never reassigned
BVECSTEIN=$BVECSTE
outlierdetection.py --bvec "$BVECSTE"                         # line 1766 — always ORIGINAL
shorerecon.py --bvec_in "$BVECSTEIN" --bvec_out "$BVECSTE"    # line 1809 — out always ORIGINAL
BVECSTEIN=$BVECSTE                                            # line 1816 — reset after the fit
  if iter ∈ ITER_REG:
    rotate_bvecs_ants.py --bvecs "$BVECSTE"                   # line 1834 — rotates FROM ORIGINAL
    BVECSTEIN=$BVECSTEROT                                     # line 1841
```

So `--bvec_in` runs `orig, orig, rot0, rot1, rot2, rot3`, while every other
consumer takes the original on every iteration. The port initially passed the
carried table to all four call sites. Corrected; three of the four now take the
original.

The consequential one is `rotate_bvecs_ants`: `--rdmri` is `RAWWORKING_DMRI`,
fixed before the loop, so each registration round independently registers the
original data and rotates the original bvecs. Feeding it a previously rotated
table would have compounded rotations across all four rounds.

---

## 10. `AXSLICES` and the GMM reorientation

The reason `outlierdetection.py` takes separate `--dmri`/`--dmrigmm`,
`--mask`/`--maskgmm`, `--spred`/`--spredgmm` arguments: the GMM variants are
**reoriented** copies. `dwisliceoutliergmm` slices along the image's third
axis, and whether the slice axis sits there depends on the stride layout, which
varies per acquisition:

| run | raw size | AXSLICES | action |
|---|---|---|---|
| FINDM073 ses-01 | 256 256 **33** | 2 | pass-through |
| FINDM075 ses-01 | 256 **33** 256 | 1 | `trans_axis1` |
| FINDM075 ses-02 | 256 **33** 256 | 1 | `trans_axis1` |
| FINDM081 ses-01 | 256 256 **33** | 2 | pass-through |
| FINDM081 ses-02 | 256 **32** 256 | 1 | `trans_axis1` |

The port originally assumed `AXSLICES==2` for all runs. The three
`AXSLICES=1` runs failed with

```
weights_4D[:,:,s,v] = weights_raw[s,v]
IndexError: index 32 is out of bounds for axis 2 with size 32
```

because `dwisliceoutliergmm` returned one row per *wrong* axis (70 rows for a
32-slice volume). The single `AXSLICES=2` run succeeded. Now derived from
`mrinfo -size` on the raw image exactly as the bash does at lines 137–149, with
the permutation matrices copied verbatim from lines 1719–1745.

Related: `shore_prepare` now passes `-stride "$STRIDES"` / `-stride
"$STRIDES3D"`, reproducing bash lines 1673/1677. Omitting them let `mrconvert`
choose its own layout and move the slice axis.

---

## 11. Configuration defaults that differ

| parameter | reference | port | reason |
|---|---|---|---|
| `--rician-method` | `LOWSNR` | `STANDARD` | see below |
| `--seg-precision` | fp32 | fp16 | §4.1 |
| `--seg-overlap` | 0.50 | 0.25 | §4.1 |

**Rician method is a data-dependent choice, not a blanket improvement.**

- **Multi-shell → `LOWSNR`.** High-b volumes have poor SNR and bias the noise
  estimate, so it is taken from the lowest non-zero shell. Correct for the
  acquisitions HAITCH was designed around, and upstream's default.
- **Single-shell → `STANDARD`.** With one non-zero shell there is no high-b
  contamination to avoid, and the "lowest shell" is nearly the whole dataset —
  so `LOWSNR` runs a second, near-duplicate `dwidenoise` pass (6–16 min per
  subject) to reproduce a noise map step 1 already emitted for free.

Measured on sub-FINDM075 ses-01 (1 b0 + 136 b=700, so the low-b subset is 99%
of the data):

```
noisemapfull mean 27.1111 | noisemaplowb mean 27.1530   (0.15% apart)
mean |difference| = 0.196 = 0.72% of the noise level
```

This cohort is single-shell, hence the default. **Set `--rician-method LOWSNR`
for any multi-shell cohort.** Caveat: measured only on the 99%-overlap session;
the three 14-b0 sessions have a 91% overlap and would differ somewhat more.

---

## 12. Runtime, measured

All figures below are parsed from `derivatives/.snakemake/log/*.snakemake.log`
(23 logs, Apple M5, 10 cores, `--cores 8 --resources gpu=1`). MRtrix and ANTs
run `osx-64` under Rosetta; segmentation runs native on MPS.

### Per-job cost

| rule | n | median | mean | max | total job-time |
|---|---:|---:|---:|---:|---:|
| `shore_fit` | 30 | 967 s | 998 s | 1399 s | **499 min** |
| `shore_register` | 20 | 414 s | 573 s | 1503 s | 191 min |
| `segment_volumes` | 5 | 607 s | 537 s | 635 s | 45 min |
| `denoise` | 5 | 445 s | 519 s | 975 s | 43 min |
| `degibbs` | 5 | 217 s | 188 s | 236 s | 16 min |
| `shore_outliers_gmm` | 25 | 27 s | 26 s | 38 s | 11 min |
| `split_volumes` | 5 | 51 s | 79 s | 196 s | 7 min |
| `lowb_noisemap` | 1 | 306 s | 306 s | 306 s | 5 min |
| everything else (14 rules) | 58 | < 20 s | | | 6 min |

Sum of job durations: **13.7 h**.

### Wall clock

Jobs run concurrently, so job-time is not elapsed time.

- **Total across all 23 invocations (including failed and restarted runs): 3.72 h.**
- The final complete run — 26 `shore_fit`, 24 `shore_outliers_gmm`,
  20 `shore_register`, 5 `shore_finalize` — took **2 h 33 min**.

So parallelism compressed 13.7 h of job-time into 3.7 h of wall clock, roughly
3.7×. Peak observed concurrency for `shore_fit` was **5 simultaneous jobs** —
bounded by the DAG (one chain per run, 5 runs) rather than by `--cores 8`,
since iterations within a run are strictly sequential.

### Implications

`shore_fit` dominates at 61% of total job-time. Because the 5 per-run chains
are independent but internally serial, **wall clock scales with iterations, not
with subjects**, until subject count exceeds available cores. A cohort of 20
runs would cost roughly the same wall clock as 5, given enough cores.

`--shore-epochs 3` would remove ~15 of the 30 `shore_fit` jobs and ~10
`shore_register` jobs, cutting the critical path by close to half — useful for
a first pass, at the cost of fewer motion-correction iterations.

Note `shore_fit` declares no `threads:`, so Snakemake budgets it as one core
while the underlying `shorerecon.py` uses more. That over-subscription is the
likely reason mean (998 s) exceeds the 905 s measured for a single job run in
isolation.

`pixi run snakehaitch` applies three defaults (see `scripts/run_snakehaitch.sh`):
`--use-conda`, `--resources gpu=1`, and `--rerun-triggers mtime`.

The last is a **development** default. Snakemake 8+ defaults to
`{code, input, mtime, params, software-env}`, so editing a rule invalidates
completed outputs — including hour-long denoise jobs. `mtime` alone means a
genuine code change will **not** trigger a re-run; for a final production run,
pass the full trigger set explicitly.

## 13. Known gaps

1. **Multi-echo data is not supported, and no configuration option enables it.**
   The port assumes `NUMBER_ECHOTIME == 1` throughout — implicitly, by never
   deriving it. The bash branches on echo count at roughly 40 points across
   steps 4, 5, 6, 7, 8 and 9, so this is missing code, not a missing switch.
   What would be required:

   | piece | status |
   |---|---|
   | `NUMBER_ECHOTIME` from the sidecar (bash 280) | not implemented |
   | TE de-interleaving, `TE = VIDX % NTE + 1` (bash 444/454, 580, 620) | not implemented |
   | step 6 distortion correction (bash 662–1510) | not ported |
   | step 7 multi-echo branch, consumes TOPUP output (bash 1581) | not ported |
   | per-TE gradients via `update_bvecs_bvals.py` (bash 1689) | helper not vendored |
   | `echo` entity in the `dwi` pybids component | absent |

   The dangerous one is de-interleaving: multi-echo volumes are interleaved
   along the 4th axis, and `split_volumes` does a flat `mrconvert -coord 3 $v`.
   On multi-echo input it would associate every volume with the wrong gradient
   direction **without raising an error**. If multi-echo support is ever
   needed, `split_volumes` should refuse to run when `EchoTime` is an array,
   rather than silently producing wrong output.

1. **Downstream stages unexercised** — the cohort has no T2w images, so
   `--downstream` has never run against real data.
2. **`--skip-steps`** is parsed but not enforced in the rule graph.
3. **`_fedi_dwiregistration.sh` / `_fedi_rotate_bvecs_ants.py` wrappers** are
   exercised only through the 20 `shore_register` jobs in this cohort; their
   argument mapping has not been independently checked against the bash the way
   §9 was.
4. **`dwisliceoutliergmm`'s rejection of the FSL gradient pair** (§5) is worked
   around, not explained.
5. **Numerical equivalence with the bash has not been demonstrated
   end-to-end.** Every deviation is individually reasoned and most are
   measured, but no side-by-side run of Reference B against this port on the
   same subject has been done. That is the outstanding validation.
