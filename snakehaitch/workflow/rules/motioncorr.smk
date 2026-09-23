# =============================================================================
#  STEP 8 : 3D-SHORE reconstruction + slice-weighted motion correction
# =============================================================================
#  Original: dMRI_HAITCH_Fixed.sh lines ~1617-1810 -- a single bash `for ITER`
#  loop running outlier detection, a weighted SHORE fit, and (on selected
#  iterations) volume-to-volume registration with bvec rotation.
#
#  Unrolled here into one rule per iteration, which buys resumability,
#  per-iteration provenance, and a derived (not hardcoded) final bvec index.
#
#  Chaining rules
#  --------------
#  Registration runs only on iterations in SHORE_ITER_REG. Iterations in
#  between reuse the most recent registered output. Rather than emit
#  pass-through copies, the input functions below resolve that lookup
#  statically -- SHORE_ITER_REG is known at parse time, so `prev_reg(i)` is a
#  plain max() over a list, not a recursive rule dependency.
#
#  With EPOCHS=6, ITER_REG=[1,2,3,4] the resolved chain is:
#      iter 0 -> init        iter 3 -> dwimc(iter2)
#      iter 1 -> init        iter 4 -> dwimc(iter3)
#      iter 2 -> dwimc(iter1) iter 5 -> dwimc(iter4)
# =============================================================================

SHORE_EPOCHS = int(config.get("shore_epochs") or 6)
SHORE_ITER_REG = sorted(int(i) for i in (config.get("shore_iter_reg") or [1, 2, 3, 4]))

if SHORE_ITER_REG and max(SHORE_ITER_REG) >= SHORE_EPOCHS:
    raise WorkflowError(
        f"--shore-iter-reg {SHORE_ITER_REG} references an iteration at or beyond "
        f"--shore-epochs {SHORE_EPOCHS}; registration iterations must be < epochs."
    )


# Constrain the iteration wildcard to non-negative integers. Without this,
# "iter-1" parses as iter="-1" and the DAG recurses until the stack blows.
wildcard_constraints:
    iter=r"\d+",


def prev_reg(i):
    """Most recent registration iteration strictly before i, or None."""
    prior = [r for r in SHORE_ITER_REG if r < i]
    return max(prior) if prior else None


def dwi_for_iter(wildcards):
    """The DWI volume set that iteration i operates on."""
    p = prev_reg(int(wildcards.iter))
    if p is None:
        return work("dwimc", desc="init", extension=".nii.gz")
    return work("dwimc", desc=f"iter{p}", extension=".nii.gz")


def bvec_for_iter(wildcards):
    """The CARRIED-IN table for iteration i -- the bash's BVECSTEIN.

    Traced from dMRI_HAITCH_Fixed.sh: BVECSTE holds the original bvecs and is
    never reassigned inside the loop. BVECSTEIN starts equal to it, is reset to
    it after every SHORE fit (line 1816), and is replaced by the rotated table
    only when that iteration ran registration (line 1841). With
    ITER_REG="1 2 3 4" that gives:
        iter 0,1 -> original   iter 2 -> rot0   iter 3 -> rot1
        iter 4   -> rot2       iter 5 -> rot3
    VALID ONLY for shorerecon's --bvec_in. Every other consumer in the loop
    takes the ORIGINAL table on every iteration.
    """
    p = prev_reg(int(wildcards.iter))
    if p is None:
        return bvec_input(wildcards)
    return work("bvec", desc=f"iter{p}", extension=".txt")


def weights_for_iter(wildcards):
    """Iteration 0 uses modified z-score weights; later iterations use GMM."""
    kind = "weightsmzscore" if int(wildcards.iter) == 0 else "weightsgmm"
    return work(kind, desc=f"iter{wildcards.iter}", extension=".txt")


def prev_spred(wildcards):
    """Previous iteration's SHORE prediction, consumed by outlier detection.

    The original passes `--spred spred$((ITER-1)).nii.gz`, which is what makes
    the loop converge: each pass scores slices against a progressively cleaner
    model. Iteration 0 has no prior prediction and the FEDI script handles its
    absence, so this returns {} there.
    """
    i = int(wildcards.iter)
    if i == 0:
        return {}
    return {"prev_spred": work("spred", desc=f"iter{i - 1}", extension=".nii.gz")}


rule shore_prepare:
    """Iteration-0 starting point: bias-corrected DWI and mask, matching grids.

    Named desc-init rather than desc-iter-1 so it cannot be confused for a
    negative iteration by the wildcard matcher.
    """
    input:
        dwi=rules.bias_correct.output.dwi,
        mask=rules.match_mask_to_dwi.output.mask,
        raw=dwi_input,
    output:
        dwi=work("dwimc", desc="init", extension=".nii.gz"),
        mask=work("mcmask", extension=".nii.gz"),
    conda:
        tool_env("mrtrix")
    shell:
        # The bash forces the raw input's stride layout onto the working
        # volumes (lines 1673/1677: -stride "$STRIDES" and "$STRIDES3D").
        # Without it mrconvert picks its own layout, which moves the slice
        # axis and breaks the GMM slice weighting downstream.
        r"""
        STRIDES=$(mrinfo -strides {input.raw} | awk '{{s="";for(i=1;i<=NF;i++){{v=$i;if(v>0)v="+"v;s=s (i>1?",":"") v}};print s}}')
        STRIDES3D=$(echo "$STRIDES" | cut -d, -f1-3)
        mrconvert {input.dwi}  {output.dwi}  -stride "$STRIDES"   -force -quiet
        mrconvert {input.mask} {output.mask} -stride "$STRIDES3D" -force -quiet
        """


#  Outlier detection is split in two because the underlying FEDI script
#  produces different files depending on whether a previous SHORE prediction
#  exists. outlierdetection.py line 617:
#
#      if args.fsliceweights_gmmodel is not None and fspred is not None:
#          gmm_weighting(...)
#      else:
#          print('Not doing FSL slice weights GMM model')
#
#  So the GMM weights only exist from iteration 1 onward. Iteration 0 has no
#  prior prediction and emits modified-z-score weights only -- which is exactly
#  what the original bash consumed at iteration 0. Declaring both outputs for
#  every iteration made iteration 0 fail on a file that cannot be produced.


rule shore_outliers_init:
    """Iteration 0: modified z-score + neighbour weights (no prior prediction)."""
    input:
        dwi=dwi_for_iter,
        bvec=bvec_input,          # BVECSTE, original -- bash line 1766
        mask=rules.shore_prepare.output.mask,
        bval=bval_input,
        # AXSLICES is derived from the RAW image's smallest dimension, exactly
        # as the bash does at step 0 (lines 137-149).
        raw=dwi_input,
    output:
        weights_mz=work("weightsmzscore", desc="iter{iter}", extension=".txt"),
    wildcard_constraints:
        iter="0",
    conda:
        tool_env("shard")
    script:
        "../scripts/outlier_detection_wrapper.py"


rule shore_outliers_gmm:
    """Iterations 1..N: adds the GMM slice weighting, scored against spred(i-1).

    This is the rule that needs `dwisliceoutliergmm` from SHARD-recon -- not
    part of stock MRtrix3, compiled by `pixi run build-shard`.
    """
    input:
        unpack(prev_spred),
        dwi=dwi_for_iter,
        bvec=bvec_input,          # BVECSTE, original -- bash line 1766
        mask=rules.shore_prepare.output.mask,
        bval=bval_input,
        raw=dwi_input,            # for AXSLICES -- bash lines 137-149
        # MRtrix-format table: dwisliceoutliergmm rejects the FSL bvec/bval pair
        # for this data (see the patch note in _fedi_outlierdetection.py).
        grad=rules.make_grad_table.output.grad,
    output:
        weights_mz=work("weightsmzscore", desc="iter{iter}", extension=".txt"),
        weights_gmm=work("weightsgmm", desc="iter{iter}", extension=".txt"),
    wildcard_constraints:
        iter="[1-9][0-9]*",
    conda:
        tool_env("shard")
    script:
        "../scripts/outlier_detection_wrapper.py"


rule shore_fit:
    """Weighted 3D-SHORE fit, predicting a motion- and artifact-free signal."""
    input:
        # bash line 1809: --bvec_in "$BVECSTEIN" --bvec_out "$BVECSTE"
        dwi=dwi_for_iter,
        bvec=bvec_for_iter,       # BVECSTEIN: carried, rotated from iter 2 on
        bvec_orig=bvec_input,     # BVECSTE:   original, every iteration
        bval=bval_input,
        mask=rules.shore_prepare.output.mask,
        weights=weights_for_iter,
    output:
        spred=work("spred", desc="iter{iter}", extension=".nii.gz"),
    conda:
        tool_env("fedi")
    script:
        "../scripts/shore_recon_wrapper.py"


rule shore_register:
    """Volume-to-volume registration to the SHORE prediction, + bvec rotation.

    Only instantiated for iterations listed in SHORE_ITER_REG; the wildcard
    constraint below prevents Snakemake trying to build it for any other index.
    """
    input:
        dwi=rules.shore_prepare.output.dwi,
        spred=work("spred", desc="iter{iter}", extension=".nii.gz"),
        # bash line 1834 rotates BVECSTE (the ORIGINAL) on every round, and
        # --rdmri is RAWWORKING_DMRI, fixed before the loop -- each round is
        # independent. A previously rotated table would compound rotations.
        bvec=bvec_input,
    output:
        dwi=work("dwimc", desc="iter{iter}", extension=".nii.gz"),
        bvec=work("bvec", desc="iter{iter}", extension=".txt"),
        xfmdir=directory(work("xfm", desc="iter{iter}", extension="")),
    wildcard_constraints:
        iter="|".join(str(i) for i in SHORE_ITER_REG) or r"(?!)",
    conda:
        tool_env("ants")
    script:
        "../scripts/dwi_registration_wrapper.py"


rule shore_finalize:
    """Publish the motion-corrected DWI and its rotated gradient table.

    The bvec index is derived from SHORE_ITER_REG, not hardcoded -- this is the
    `rotated_bvecs3` desynchronisation bug from the bash version.
    """
    input:
        spred=work("spred", desc=f"iter{SHORE_EPOCHS - 1}", extension=".nii.gz"),
        bvec=(
            work("bvec", desc=f"iter{max(SHORE_ITER_REG)}", extension=".txt")
            if SHORE_ITER_REG
            else bvec_input
        ),
        bval=bval_input,
        mask=rules.shore_prepare.output.mask,
    output:
        dwi=deriv("dwi", desc="preproc", extension=".nii.gz"),
        bvec=deriv("dwi", desc="preproc", extension=".bvec"),
        bval=deriv("dwi", desc="preproc", extension=".bval"),
        mask=deriv("mask", desc="brain", extension=".nii.gz"),
    conda:
        tool_env("mrtrix")
    shell:
        "cp {input.spred} {output.dwi} && "
        "cp {input.bvec} {output.bvec} && "
        "cp {input.bval} {output.bval} && "
        "cp {input.mask} {output.mask}"
