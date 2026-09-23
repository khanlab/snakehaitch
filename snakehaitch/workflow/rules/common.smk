# =============================================================================
#  Shared helpers, paths and parameter access
# =============================================================================

import os
import shutil
from pathlib import Path


# -----------------------------------------------------------------------------
# Software environments
# -----------------------------------------------------------------------------
# Rules resolve their environment through tool_env() rather than naming a YAML
# directly. Preferred form is a pixi-managed prefix (.pixi/envs/<name>).
#
# Why a prefix and not a YAML: Snakemake classifies a `conda:` value that is an
# existing directory as CondaEnvSpecType.DIR, which makes is_externally_managed
# True, which makes create_conda_envs() skip it (deployment/conda.py:566). So
# Snakemake never calls `conda env create` and never consults CONDA_SUBDIR --
# and CONDA_SUBDIR is process-wide, which is exactly why `--use-conda` could not
# give the segmentation env a different architecture from the MRtrix envs.
# pixi sets the platform per environment, so fetalbet stays native (keeping
# Metal/MPS on Apple silicon) while mrtrix/ants run osx-64 under Rosetta.
#
# Falls back to the checked-in YAML when no prefix exists, so a plain
# `snakemake --use-conda` still works for anyone not using pixi.

def _pixi_env_root():
    configured = config.get("pixi_env_dir")
    if configured:
        return Path(configured)
    # pixi exports PIXI_PROJECT_ROOT inside `pixi run`.
    root = os.environ.get("PIXI_PROJECT_ROOT")
    if root:
        return Path(root) / ".pixi" / "envs"
    # Last resort: workflow dir is <root>/snakehaitch-app/snakehaitch/workflow
    return Path(workflow.basedir).parents[2] / ".pixi" / "envs"


PIXI_ENVS = _pixi_env_root()


def tool_env(name):
    """Absolute pixi prefix if provisioned, else the fallback env YAML."""
    prefix = PIXI_ENVS / name
    if prefix.is_dir():
        return str(prefix.resolve())
    return f"../envs/{name}.yaml"


# -----------------------------------------------------------------------------
# Preflight: the compiled binaries
# -----------------------------------------------------------------------------
# `pixi run setup` provisions the shard PREFIX, but the binaries inside it come
# from a separate source build (`pixi run build-shard`). A prefix that exists
# but was never built therefore looks provisioned to tool_env() and fails only
# once motion correction starts -- roughly 30 minutes into a run, after
# denoising and segmentation have already been paid for.
#
# outlier_detection_wrapper.py calls mrinfo (to derive AXSLICES) before it ever
# calls dwisliceoutliergmm, so a half-built prefix surfaces as a bare
# FileNotFoundError on mrinfo rather than the documented
# "dwisliceoutliergmm: command not found". Check both.
#
# Only meaningful for a pixi prefix: under the YAML fallback Snakemake has not
# created the environment yet at DAG-build time, so there is nothing to inspect.

def _check_shard_binaries():
    prefix = PIXI_ENVS / "shard"
    if not prefix.is_dir():
        return  # YAML fallback; nothing built yet by definition
    missing = [b for b in ("mrinfo", "dwisliceoutliergmm")
               if not (prefix / "bin" / b).exists()]
    if missing:
        raise WorkflowError(
            "The shard environment at {} is provisioned but not built: {} "
            "missing from its bin/.\n"
            "Motion correction needs these. Run:\n\n"
            "    pixi run build-shard\n\n"
            "It compiles MRtrix3 and the SHARD-recon module from source "
            "(30-60 min, once per machine). Set SHARD_BUILD_JOBS to control "
            "parallelism.".format(prefix, ", ".join(missing))
        )


_check_shard_binaries()


# Root for all derivatives written by this app.
DERIV = Path(config["output_dir"])

# Hyperparameters that are not CLI-exposed.
P = config["snakehaitch"]


def hp(cli_key, *path, default=None):
    """Read a parameter, preferring the CLI value over the config[haitch] tree.

    Mirrors the precedence the old haitch_params.sh had (environment beats
    file), so `--seg-precision fp32` wins over anything set in snakebids.yml.
    """
    if cli_key is not None and config.get(cli_key) is not None:
        return config[cli_key]
    node = P
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return default
        node = node[key]
    return node


def step_enabled(name):
    """False when the user passed --skip-steps <name>."""
    return name not in (config.get("skip_steps") or [])


# -----------------------------------------------------------------------------
# Derivative path helpers
# -----------------------------------------------------------------------------
# One work directory per (subject, session, run), holding the intermediate
# .mif chain. Equivalent to the old
#   protocols/HAITCH/<sub>/<ses>/dwi_<run>/preprocessing
# but expressed with BIDS entities so downstream tools can index it.

def work(suffix, **extra):
    """Intermediate file inside the per-run working directory."""
    return bids(
        root=str(DERIV / "work"),
        datatype="dwi",
        suffix=suffix,
        **extra,
        **inputs["dwi"].wildcards,
    )


def deriv(suffix, **extra):
    """Published derivative, BIDS-named."""
    return bids(
        root=str(DERIV),
        datatype="dwi",
        suffix=suffix,
        **extra,
        **inputs["dwi"].wildcards,
    )


def qc(suffix, **extra):
    """Quality-control output."""
    return bids(
        root=str(DERIV / "qc"),
        datatype="dwi",
        suffix=suffix,
        **extra,
        **inputs["dwi"].wildcards,
    )


# -----------------------------------------------------------------------------
# Gradient table helpers
# -----------------------------------------------------------------------------
# The old pipeline required a separate prerequisite_files.sh pass to build
# *_grad_mrtrix.txt and refs/*_acqparams.txt before anything could run. Those
# are now ordinary rules (see preproc.smk :: make_grad_table / make_acqparams),
# so there is no manual pre-step.

def dwi_input(wildcards):
    """The source DWI NIfTI for this run."""
    return inputs["dwi"].filter(**wildcards).expand()[0]


def bval_input(wildcards):
    return re.sub(r"\.nii\.gz$", ".bval", dwi_input(wildcards))


def bvec_input(wildcards):
    return re.sub(r"\.nii\.gz$", ".bvec", dwi_input(wildcards))


def json_input(wildcards):
    return re.sub(r"\.nii\.gz$", ".json", dwi_input(wildcards))


import re  # noqa: E402  (used by the helpers above)
