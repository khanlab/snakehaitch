#!/usr/bin/env bash
# Entry point behind `pixi run snakehaitch`.
#
# Adds two defaults that you almost always want, without preventing you from
# overriding either.
#
# --rerun-triggers mtime
#   Snakemake 8+ defaults to {code, input, mtime, params, software-env}. That
#   means editing a rule's shell command, changing a param, or touching the
#   conda environment invalidates completed outputs and re-runs them --
#   including hour-long denoise jobs. Restricting the trigger set to `mtime`
#   means only genuinely newer inputs cause a re-run.
#
#   Trade-off: with `mtime` alone, a real change to a rule's code will NOT
#   re-run it. That is what you want while iterating on the workflow; for a
#   final production run, pass an explicit --rerun-triggers to restore the
#   strict behaviour, e.g.
#       pixi run snakehaitch ... --rerun-triggers code input mtime params software-env
#
# --use-conda
#   Every rule declares a conda: prefix, so without this nothing resolves.
#   It also matters for change detection: Snakemake only folds the conda
#   environment into its software_stack_hash when CONDA deployment is active
#   (persistence/__init__.py::_software_stack_hash), so running with it
#   sometimes and without it other times makes the hash flip-flop and triggers
#   spurious "Software environment definition has changed" re-runs.
set -euo pipefail

args=("$@")

has_flag() {
    local needle="$1"
    for a in "${args[@]}"; do
        [[ "$a" == "$needle" || "$a" == "${needle}="* ]] && return 0
    done
    return 1
}

has_flag --rerun-triggers || args+=(--rerun-triggers mtime)
has_flag --use-conda      || args+=(--use-conda)

# --resources gpu=1
#   segment_volumes declares `resources: gpu=1`, but Snakemake silently ignores
#   a resource that the command line never budgets -- the declaration alone does
#   nothing. Without this, two segmentation jobs run concurrently on the single
#   accelerator and throughput drops (measured: 4.74 s/vol solo -> 7.22 s/vol
#   with two overlapping).
#
#   Only injected when --resources is absent entirely. If you pass your own
#   --resources, include gpu=1 yourself or segmentation will parallelise again.
has_flag --resources || args+=(--resources gpu=1)

exec snakehaitch "${args[@]}"
