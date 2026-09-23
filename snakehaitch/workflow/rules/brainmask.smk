# =============================================================================
#  STEP 4 : fetal brain extraction (Fetal-BET / AttentionUnet)
# =============================================================================
#  Original: dMRI_HAITCH_Fixed.sh lines ~413-522, which ran
#    docker run --gpus all ... arfentul/fetalbet-model:first
#  i.e. a 6 GB linux/amd64 CUDA image, unusable off NVIDIA hardware.
#
#  Here that container is replaced by a conda env (envs/fetalbet.yaml) plus the
#  portable inference script. Same AttentionUnet, same AttUNet.pth weights,
#  same pre/post-processing -- but it resolves a device at runtime
#  (cuda -> mps -> xpu -> cpu), so it runs on Linux, macOS and WSL2 alike.
#
#  The weights are the only part of the image we still need (127 MB). They are
#  pulled straight from the registry as a single layer rather than by pulling
#  the whole 6 GB image; see scripts/fetch_fetalbet_weights.py.
# =============================================================================


rule fetch_fetalbet_weights:
    """Download AttUNet.pth out of the published image layer (127 MB, once)."""
    output:
        # NOT protected(): a protected output is made read-only, so any rerun
        # (e.g. --rerun-incomplete after an interrupted run) dies with
        # ProtectedOutputException instead of simply reusing the cached file.
        # The download is digest-verified, so caching is already safe.
        weights=str(DERIV / "resources" / "AttUNet.pth"),
    params:
        digest=P["fetalbet"]["weights_layer_digest"],
        member=P["fetalbet"]["weights_member"],
    localrule: True
    conda:
        tool_env("fetalbet")
    script:
        "../scripts/fetch_fetalbet_weights.py"


checkpoint split_volumes:
    """Split the 4D DWI into per-volume 3D files for the segmenter.

    Replaces the `mrconvert -coord 3 $VIDX` loop. A checkpoint because the
    volume count is data-dependent (137 or 150 across your subjects).
    """
    input:
        dwi=rules.rician_correct.output.dwi,
    output:
        voldir=temp(directory(work("volumes", extension=""))),
    conda:
        tool_env("mrtrix")
    shell:
        r"""
        mkdir -p {output.voldir}
        N=$(mrinfo -size {input.dwi} -quiet | awk '{{print $4}}')
        for ((v=0; v<N; v++)); do
            mrconvert -coord 3 $v {input.dwi} \
                "{output.voldir}/working_TE1_v${{v}}.nii.gz" -quiet -force
        done
        """


rule segment_volumes:
    """Run Fetal-BET over every 3D volume, emitting one mask each.

    Resource accounting matters here. This is not a pure-GPU job: per volume it
    also does LoadImaged, a Spacingd resample to 399x399, per-slice
    normalisation, and an Invertd inverse-resample -- all on CPU. Measured on
    this dataset, segmentation ran at 3.08 s/volume alone but 7.05 s/volume
    while dwidenoise saturated the cores, because those CPU stages starved and
    the GPU idled between batches.

    `threads` reserves part of the core budget so Snakemake stops over-committing
    the machine. `gpu=1` keeps two segmentation jobs from contending for one
    accelerator -- but note it is only enforced when the run also passes
    `--resources gpu=1`; a rule-declared resource with no matching command-line
    budget is silently ignored by the scheduler.
    """
    input:
        voldir=rules.split_volumes.output.voldir,
        weights=rules.fetch_fetalbet_weights.output.weights,
    output:
        maskdir=temp(directory(work("masks", extension=""))),
    params:
        device=lambda w: hp("seg_device", default="auto"),
        precision=lambda w: hp("seg_precision", default="fp16"),
        overlap=lambda w: hp("seg_overlap", default=0.25),
        batch=lambda w: hp("seg_batch", default=4),
        # Persistent cache, deliberately NOT a declared output. Snakemake
        # removes directory() outputs before re-running a job ("Removing output
        # files of failed job ... since they might be corrupted"), so masks
        # written straight to output.maskdir are destroyed on every retry and
        # the 3 s/volume GPU work is redone from zero. Writing to a cache the
        # workflow does not manage lets the inference script skip volumes that
        # already have a mask; the declared output is then materialised from
        # the cache with hardlinks (same filesystem, so no extra space).
        cachedir=work("maskcache", extension=""),
    threads: 4
    resources:
        gpu=1,
    conda:
        tool_env("fetalbet")
    shell:
        "python {workflow.basedir}/scripts/fetalbet_inference.py"
        " --data_path {input.voldir}"
        " --save_path {params.cachedir}"
        " --saved_model_path {input.weights}"
        " --device {params.device}"
        " --precision {params.precision}"
        " --overlap {params.overlap}"
        " --sw_batch_size {params.batch}"
        " && mkdir -p {output.maskdir}"
        " && ln -f {params.cachedir}/*_mask.nii.gz {output.maskdir}/"


rule segmentation_qc:
    """Per-volume mask volume plot, to catch segmentation outliers."""
    input:
        voldir=rules.split_volumes.output.voldir,
        maskdir=rules.segment_volumes.output.maskdir,
    output:
        plot=qc("segmentation", extension=".png"),
    conda:
        tool_env("fedi")
    script:
        "../scripts/segmentation_qc.py"
