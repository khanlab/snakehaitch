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

**Tested on Linux** (x86_64, CPU only). Steps 1–8 run end to end on one
subject, two sessions (sub-FINDM074). MRtrix and ANTs run native, and
`build-shard` compiles with the self-contained conda toolchain (~9 min on 10
cores). Not yet exercised on Linux: CUDA segmentation, multi-shell data, and
`--downstream`.

The first Linux run exposed bugs that were latent on macOS and have since been
fixed:

- `cmd | head -1` under `set -o pipefail` (Snakemake's default shell mode)
  intermittently failed with exit 141 when `head` closed the pipe before the
  producer finished. Timing-dependent — it never triggered on local APFS, but
  did reliably on NFS. All such pipes are removed.
- N4 rejected the bias mask as "not in the same physical space" for one
  session: NIfTI stores the transform in float32, so the mask origin drifted
  ~1e-5 mm from the DWI's. The mask is now kept as `.mif`.
- Segmentation ignored its thread reservation on CPU — torch sized its pool
  from the core count. Now controlled by `--seg-threads`.

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
| pixi | `curl -fsSL https://pixi.sh/install.sh \| bash` |
| macOS only | Xcode Command Line Tools (`xcode-select --install`), needed by `build-shard` — see below |
| Disk | final outputs are small; intermediates dominate peak usage and are deleted as the run proceeds (`--notemp` keeps them, ~49 GB per 5-run cohort) |
| GPU | optional — CUDA on Linux (untested), Metal/MPS on Apple silicon, else CPU. On CPU, segmentation ran at ~18 s/volume with `--seg-threads 24` |

MRtrix3, ANTs, PyTorch, the FEDI stack and SHARD-recon are all installed by
pixi. You do not need conda, Docker, an existing MRtrix install, or even
`git` — `build-shard` clones with conda's own git, not the host's.

The one genuine host dependency is the **macOS SDK**. Conda's C++ compiler
invokes `-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` and no
SDK ships inside the environment, so `pixi run build-shard` needs Xcode
Command Line Tools. Linux has no equivalent gap: `sysroot_linux-64` is in
`pixi.lock`, so the toolchain is self-contained there.

**Input must be single-echo DWI in valid BIDS.** Multi-echo data produces wrong
output without erroring — see [CHANGES.md §13](CHANGES.md).

---

## Setup

Once per machine.

```bash
cd snakehaitch-app

pixi install          # driver environment
pixi run setup        # per-rule tool environments
pixi run build-shard  # compiles SHARD-recon (5-10 min, once)
```

`build-shard` compiles MRtrix3 from source. It is unavoidable:
`dwisliceoutliergmm` is required by motion correction and is not packaged on
any conda channel. Use `SHARD_BUILD_JOBS=8 pixi run build-shard` to control
parallelism.

> **Once per checkout, not once per machine.** The build installs into this
> project's `.pixi/envs/shard`. A second clone gets its own empty `shard`
> environment from `pixi run setup`, and `setup` alone is not enough — it
> provisions the compiler toolchain, not the binaries. The workflow checks for
> them before building its DAG and stops immediately if they are absent.

### Convert data to BIDS

The app requires valid BIDS. If your data is in the raw HAITCH layout:

```bash
pixi run bidsify ../data ../bids     # symlinks; add --copy for a standalone tree
```

This fixes directory nesting, entity order, sidecar extensions, and writes
`dataset_description.json`. Use `--dry-run` to preview.

If your data is raw dcm2niix output in scanner-series folders
(`sub-X/ses-N/DTI/*.nii` plus a reverse-PE `ses-N/DTI_b0/`), use the other
converter:

```bash
python scripts/bidsify_dcm2niix.py ../data ../bids --dry-run
python scripts/bidsify_dcm2niix.py ../data ../bids
```

It zero-pads sessions (`ses-1` → `ses-01`) and files the reverse-PE b0 series
under `fmap/` as `_epi` with `IntendedFor`, so the pipeline does not mistake it
for a second DWI run. Copied files get fresh timestamps, because source files
transferred from another machine can carry future mtimes that Snakemake
rejects as clock skew.

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
| `--seg-threads` | 4 | segmenting on CPU → your core count (capped at `--cores`) |
| `--downstream` | off | you have T2w + an atlas (untested) |
| `--notemp` | off | you want the intermediates kept (Snakemake's own flag) |
| `--no-archive-work` | off | with `--notemp`, keep `work/` but skip the zip |

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
└── work.zip                           only with --notemp; work/ kept beside it
```

Check `qc/*_segmentation.png` first. Mask volume dropping and component counts
rising at high b-value is expected — step 5 takes a union across volumes for
exactly that reason.

**There is no `work/` after a normal run.** Every intermediate is declared
`temp()`, so Snakemake deletes each one as soon as no remaining job needs it,
and the hook sweeps whatever is left. A finished run leaves only `sub-*/` and
`qc/`.

Pass Snakemake's own **`--notemp`** to keep them. Then `work/` survives and is
zipped to `work.zip` in store mode (the zip is verified against a snapshot
taken before zipping; `--no-archive-work` skips it).

**Interrupting a run is still safe.** `temp()` only deletes a file once no
pending job needs it, and the end-of-run sweep does not fire on failure, so a
stopped run resumes from where it stopped rather than from the beginning. Add
`--rerun-incomplete` if you killed it mid-write.

Use `--notemp` when you expect to **re-run a stage that already succeeded**
with different parameters — that is the case where the missing intermediates
force a cascade back to denoising. See
[PIPELINE.md](PIPELINE.md#intermediates-and-the-work-archive) for measurements.

---

## Runtime

~2.5 h wall clock for 5 runs on 8 cores, steps 1–8. Motion correction
dominates. Wall clock scales with iteration count rather than subject count.
[PIPELINE.md](PIPELINE.md#runtime) has the per-rule measurements.

---

## Troubleshooting

| symptom | cause |
|---|---|
| `shard environment ... provisioned but not built` | `pixi run build-shard` not run in *this* checkout |
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
