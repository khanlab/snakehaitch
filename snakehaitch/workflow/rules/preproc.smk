# =============================================================================
#  STEPS 1-3 : denoise -> Gibbs ringing -> Rician bias correction
# =============================================================================
#  Original: dMRI_HAITCH_Fixed.sh lines ~319-410
#
#  One behavioural fix relative to the original: STEP1 there ran
#      mrconvert $INPUT -set_property comments "FEDI Pipeline" $INPUT -force
#  which rewrote the *raw input file in place*. Snakemake treats inputs as
#  immutable, so that is dropped; the provenance comment is attached to the
#  first derivative instead.
# =============================================================================


rule make_grad_table:
    """MRtrix gradient table from the BIDS .bval/.bvec pair.

    Replaces prerequisite_files.sh :: generate_grad_mrtrix.
    """
    input:
        dwi=dwi_input,
        bval=bval_input,
        bvec=bvec_input,
    output:
        grad=work("grad", extension=".txt"),
    conda:
        tool_env("mrtrix")
    shell:
        "mrinfo {input.dwi} -fslgrad {input.bvec} {input.bval} "
        "-export_grad_mrtrix {output.grad}"


rule make_acqparams:
    """FSL-style acqparams line from the BIDS sidecar.

    Replaces prerequisite_files.sh :: generate_acqp. Unlike the original this
    hard-fails on a missing field rather than silently substituting a default.
    """
    input:
        json=json_input,
    output:
        acqp=work("acqparams", extension=".txt"),
    conda:
        tool_env("fedi")
    script:
        "../scripts/make_acqparams.py"


rule make_grad5cls:
    """5-column gradient table + eddy index file (PROJNAME=BCH path)."""
    input:
        grad=rules.make_grad_table.output.grad,
    output:
        grad5=work("grad5cls", extension=".txt"),
        index=work("eddyindex", extension=".txt"),
    conda:
        tool_env("fedi")
    shell:
        "python {workflow.basedir}/scripts/_fedi_create_grad5cls_index.py "
        "{input.grad} {output.grad5} {output.index}"


rule denoise:
    """STEP 1 -- MP-PCA/GSVS denoising."""
    input:
        dwi=dwi_input,
    output:
        dwi=work("dwide", extension=".mif"),
        noise=work("noisemapfull", extension=".mif"),
        residuals=work("denoiseresiduals", extension=".mif"),
    params:
        estimator=lambda w: hp("denoise_estimator", "denoise", "estimator",
                               default="Exp2"),
    threads: lambda w: hp(None, "denoise", "nthreads", default=8)
    conda:
        tool_env("mrtrix")
    shell:
        "dwidenoise -noise {output.noise} -estimator {params.estimator} "
        "-nthreads {threads} {input.dwi} {output.dwi} && "
        "mrcalc {input.dwi} {output.dwi} -subtract {output.residuals}"


rule degibbs:
    """STEP 2 -- Gibbs ringing removal (Kellner et al. 2016)."""
    input:
        dwi=rules.denoise.output.dwi,
        grad5=rules.make_grad5cls.output.grad5,
        index=rules.make_grad5cls.output.index,
        acqp=rules.make_acqparams.output.acqp,
    output:
        dwi=work("dwigb", extension=".mif"),
    conda:
        tool_env("mrtrix")
    shell:
        "mrdegibbs {input.dwi} - | "
        "mrconvert - -grad {input.grad5} "
        "-import_pe_eddy {input.acqp} {input.index} {output.dwi}"


rule lowb_noisemap:
    """Noise map from the lowest non-zero shell, for RICIAN_WAY=LOWSNR.

    Only the -noise map is wanted here; the denoised image itself is a
    by-product. It cannot be discarded to /dev/null -- MRtrix picks its output
    format from the file extension and rejects an extension-less path:

        dwidenoise: [ERROR] unknown format for image "/dev/null"

    so it is written to a real .mif that Snakemake deletes via temp().
    """
    input:
        dwi=dwi_input,
        grad5=rules.make_grad5cls.output.grad5,
        bval=bval_input,
    output:
        noise=work("noisemaplowb", extension=".mif"),
        discard=temp(work("lowbdenoised", extension=".mif")),
    params:
        estimator=lambda w: hp("denoise_estimator", "denoise", "estimator",
                               default="Exp2"),
    # Must declare threads AND pass -nthreads. Without the declaration Snakemake
    # assumes 1 and schedules --cores jobs in parallel, while MRtrix with no
    # -nthreads grabs every core -- so N jobs each take all cores and thrash.
    threads: lambda w: hp(None, "denoise", "nthreads", default=8)
    conda:
        tool_env("mrtrix")
    shell:
        r"""
        LOWB=$(tr ' ' '\n' < {input.bval} | awk 'NF && $1>0 {{print $1}}' | sort -n | head -1)
        dwiextract -grad {input.grad5} -shell $LOWB {input.dwi} - | \
          dwidenoise -noise {output.noise} -estimator {params.estimator} \
                     -nthreads {threads} - {output.discard}
        """


rule rician_correct:
    """STEP 3 -- Rician bias correction (Ades-Aron et al. 2019)."""
    input:
        dwi=rules.degibbs.output.dwi,
        noise=lambda w: (
            rules.lowb_noisemap.output.noise
            if hp("rician_method", default="LOWSNR") == "LOWSNR"
            else rules.denoise.output.noise
        ),
        grad5=rules.make_grad5cls.output.grad5,
        index=rules.make_grad5cls.output.index,
        acqp=rules.make_acqparams.output.acqp,
    output:
        dwi=work("dwirc", extension=".mif"),
    conda:
        tool_env("mrtrix")
    shell:
        "mrcalc {input.noise} -finite {input.noise} 0 -if - | "
        "mrcalc {input.dwi} 2 -pow - 2 -pow -sub -abs -sqrt - | "
        "mrcalc - -finite - 0 -if - | "
        "mrconvert - -grad {input.grad5} "
        "-import_pe_eddy {input.acqp} {input.index} {output.dwi}"
