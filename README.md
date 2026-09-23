# SnakeHAITCH

Fetal dMRI preprocessing and motion correction — [HAITCH](https://github.com/IntelligentImaging/HAITCH)
packaged as a [Snakebids](https://snakebids.readthedocs.io) BIDS app, driven by
[pixi](https://pixi.sh).

```bash
pixi run snakehaitch <bids_dir> <output_dir> participant --cores 8
```

| | |
|---|---|
| **What each stage does** | [PIPELINE.md](PIPELINE.md) |
| **How it differs from upstream HAITCH** | [CHANGES.md](CHANGES.md) |

---

## Status

**Tested on macOS** (Apple silicon, M5). Steps 1–8 run end to end on a 5-run
fetal cohort.

**Expected to work on Linux** but not yet run there. The environments are
locked for `linux-64` and nothing in the workflow is macOS-specific — on Linux
MRtrix and ANTs actually run *native* rather than under Rosetta, and
segmentation picks up CUDA instead of Metal. Treat the first Linux run as a
validation exercise.

**Windows is not supported.** MRtrix3 and ANTs publish no `win-64` build. Use
WSL2.

### What is and is not validated

| | |
|---|---|
| Steps 1–8 (denoise → motion correction) | tested, 5 runs |
| **Downstream (`--downstream`)** | **ported, not validated** — see below |
| Single-echo data | required |
| Multi-echo data | **not supported**, fails silently |
| Single-shell / multi-shell | both expected to work; only single-shell tested |

> **The downstream stages are not validated.** Atlas → T2w registration,
> label propagation to DWI, ROI extraction and AF/SLF tractography are all
> implemented, but they depend on the DWI being co-registered to the subject's
> T2w — and in fetal imaging that alignment is typically a manually initiated
> step, not something the pipeline can reliably do unattended. Fetal head pose
> is arbitrary and varies between the structural and diffusion acquisitions,
> so the automatic registration usually needs a manual initialisation before
> it will converge.
>
> Both references acknowledge this by shipping a `REGSTRAT=manual` path, where
> you produce the alignment matrix in Slicer or ITK-SNAP and the script imports
> it. **Only the `ants` strategy is ported here** — which is the locally
> adapted fork's default, but it means a case needing manual initialisation is
> not yet catered for.
>
> Treat `--downstream` as a scaffold around that manual step rather than a
> turnkey stage. Everything up to and including `shore_finalize` runs
> unattended and has been exercised on real data.

---

## Requirements

| | |
|---|---|
| OS | macOS or Linux |
| pixi | the only prerequisite: `curl -fsSL https://pixi.sh/install.sh \| bash` |
| Disk | ~55 GB per 5-run cohort; intermediates dominate |
| GPU | optional — CUDA on Linux, Metal/MPS on Apple silicon, else CPU |

MRtrix3, ANTs, PyTorch, the FEDI stack and SHARD-recon are all installed by
pixi. You do not need conda, Docker, or an existing MRtrix install.

**Input must be single-echo DWI in valid BIDS.** Multi-echo data produces wrong
output without erroring — see [CHANGES.md §13](CHANGES.md).

---

## Setup

Once per machine.

```bash
cd snakehaitch-app

pixi install          # driver environment
pixi run setup        # per-rule tool environments
pixi run build-shard  # compiles SHARD-recon -- 30-60 min, once
```

`build-shard` compiles MRtrix3 from source. It is unavoidable:
`dwisliceoutliergmm` is required by motion correction and is not packaged on
any conda channel. Use `SHARD_BUILD_JOBS=8 pixi run build-shard` to control
parallelism.

### Convert data to BIDS

The app requires valid BIDS. If your data is in the raw HAITCH layout:

```bash
pixi run bidsify ../data ../bids     # symlinks; add --copy for a standalone tree
```

This fixes directory nesting, entity order, sidecar extensions, and writes
`dataset_description.json`. Use `--dry-run` to preview.

---

## Running

```bash
# everything
pixi run snakehaitch ../bids ../derivatives participant --cores 8

# one subject
pixi run snakehaitch ../bids ../derivatives participant --cores 8 \
    --participant-label FINDM075

# check the plan first
pixi run dryrun
```

`pixi run snakehaitch` supplies `--use-conda`, `--resources gpu=1` and
`--rerun-triggers mtime` unless you override them.
[PIPELINE.md](PIPELINE.md#execution-model) explains why each matters —
particularly `--rerun-triggers mtime`, which is a development default.

### Common options

| flag | default | change it when |
|---|---|---|
| `--rician-method` | `STANDARD` | **your data is multi-shell** → `LOWSNR` |
| `--shore-epochs` | 6 | a faster first pass → `3` |
| `--seg-device` | `auto` | forcing `cpu` / `cuda` / `mps` |
| `--downstream` | off | you have T2w + an atlas (untested) |
| `--no-archive-work` | off | you do not want `work/` zipped |

`pixi run snakehaitch --help` lists everything.
[PIPELINE.md](PIPELINE.md#parameter-reference) has the full table and the
reasoning behind each default.

---

## Outputs

```
<output_dir>/
├── sub-<X>/ses-<Y>/dwi/
│   ├── ..._desc-preproc_dwi.nii.gz    motion-corrected DWI
│   ├── ..._desc-preproc_dwi.bvec      rotated gradients
│   ├── ..._desc-preproc_dwi.bval
│   └── ..._desc-brain_mask.nii.gz     brain mask
├── qc/..._segmentation.png            per-volume mask QC
├── work/                              intermediates (large)
└── work.zip                           archive, written on success
```

Check `qc/*_segmentation.png` first. Mask volume dropping and component counts
rising at high b-value is expected — step 5 takes a union across volumes for
exactly that reason.

`work/` is zipped on success but **not deleted** — Snakemake needs it to
resume. To remove it: `pixi run archive <output_dir>/work --remove`.

---

## Runtime

~2.5 h wall clock for 5 runs on 8 cores, steps 1–8. Motion correction
dominates. Wall clock scales with iteration count rather than subject count.
[PIPELINE.md](PIPELINE.md#runtime) has the per-rule measurements.

---

## Troubleshooting

| symptom | cause |
|---|---|
| `dwisliceoutliergmm: command not found` | `pixi run build-shard` not run |
| `Nothing to be done` | everything up to date; use `--forcerun <rule>` |
| `Directory cannot be locked` | a run is active, or one was killed — `--unlock` |
| `IncompleteFilesException` | interrupted mid-write — `--rerun-incomplete` |
| edited a rule, nothing re-ran | expected under `--rerun-triggers mtime` |
| pixi warns about `[system-requirements]` | harmless; see [CHANGES.md §3](CHANGES.md) |

---

## Layout

Self-contained — this folder has no dependency on anything outside it.

```
pixi.toml pixi.lock      environments + tasks
pyproject.toml           the installable package
scripts/                 bidsify, setup, build-shard, run wrapper, archive
snakehaitch/
  config/snakebids.yml   pybids inputs + every tunable parameter
  workflow/              Snakefile, rules/, envs/, scripts/
```

Data lives wherever you point the CLI; it is not part of the app.

## License and credits

**GPL-3.0** — see [LICENSE](LICENSE). This is a derivative of
[HAITCH](https://github.com/IntelligentImaging/HAITCH) (GPL-3.0) and vendors
nine of its FEDI helper scripts, so it inherits that license.

Ports HAITCH (Snoussi et al., IMAGINE / Computational Radiology Laboratory,
Boston Children's Hospital) and the
[locally adapted fork](https://github.com/Andy1Yang1/HAITECH-Locally-Adapted-Version).
Uses [SHARD-recon](https://github.com/dchristiaens/shard-recon) (Christiaens et
al., NeuroImage 2020) and Fetal-BET.

[NOTICE](NOTICE) lists every vendored file and its provenance;
[CHANGES.md](CHANGES.md) documents the one patched script.
