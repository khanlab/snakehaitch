# =============================================================================
#  DOWNSTREAM : atlas -> T2w -> DWI label propagation, ROIs, AF/SLF tracking
# =============================================================================
#  Ports the four post-motion-correction bash scripts. These run only when
#  --downstream is passed; `rule all` does not request them otherwise.
#
#    Atlas_to_T2w_and_regional_propogation.sh  -> atlas_to_t2w
#    Registraiton_refinment_and_labels_to_DWI.sh -> labels_to_dwi
#    ROI_Extract.sh                             -> extract_roi
#    AF_SLF_tractography.sh                     -> tckgen_bundle / tract_density
#
#  Requires, per subject: a T2w image (pybids component `t2w`) and a
#  gestational-age-matched atlas pair supplied via --atlas-dir.
# =============================================================================

BUNDLES = config["snakehaitch"]["bundles"]
LABELS = config["snakehaitch"]["labels"]

ATLAS_DIR = config.get("atlas_dir")


def _have_t2w():
    try:
        return len(inputs["t2w"]) > 0
    except (KeyError, TypeError):
        return False


def subject_t2w(wildcards):
    """The subject's T2w, with an actionable error instead of a bare KeyError."""
    if not _have_t2w():
        raise WorkflowError(
            "--downstream needs a T2w image per subject, but the BIDS dataset "
            "contains none (looked for datatype=anat, suffix=T2w).\n"
            "Add the structural scans to the dataset, or drop --downstream to "
            "run preprocessing only."
        )
    matches = inputs["t2w"].filter(
        subject=wildcards.subject, session=wildcards.session
    ).expand()
    if not matches:
        raise WorkflowError(
            f"no T2w found for sub-{wildcards.subject} ses-{wildcards.session}"
        )
    return matches[0]


def _atlas(pattern, what):
    """Resolve the gestational-age-matched atlas supplied via --atlas-dir."""
    if not ATLAS_DIR:
        raise WorkflowError(
            "--downstream requires --atlas-dir pointing at a directory holding "
            "the age-matched atlas pair, named t2w_GA<weeks>_atlas.nii.gz and "
            "t2w_GA<weeks>_regional.nii.gz"
        )
    hits = sorted(Path(ATLAS_DIR).glob(pattern))
    if not hits:
        raise WorkflowError(f"no {what} matching {pattern!r} in {ATLAS_DIR}")
    if len(hits) > 1:
        raise WorkflowError(
            f"{len(hits)} files match {pattern!r} in {ATLAS_DIR}; expected one: "
            + ", ".join(h.name for h in hits)
        )
    return str(hits[0])


def atlas_image(wildcards):
    return _atlas("t2w_GA*_atlas.nii.gz", "atlas image")


def atlas_labels(wildcards):
    return _atlas("t2w_GA*_regional.nii.gz", "atlas parcellation")


rule mean_b0:
    """Mean b0 from the motion-corrected data; the registration moving image."""
    input:
        dwi=rules.shore_finalize.output.dwi,
        bval=rules.shore_finalize.output.bval,
        bvec=rules.shore_finalize.output.bvec,
    output:
        b0=work("meanb0", extension=".nii.gz"),
    conda:
        tool_env("mrtrix")
    shell:
        "dwiextract -fslgrad {input.bvec} {input.bval} -bzero {input.dwi} - | "
        "mrmath - mean {output.b0} -axis 3 -force -quiet"


rule atlas_to_t2w:
    """Nonlinear atlas -> subject T2w, then propagate the parcellation."""
    input:
        t2w=subject_t2w,
        atlas=lambda w: atlas_image(w),
        regional=lambda w: atlas_labels(w),
    output:
        labels=work("regional", space="T2w", extension=".nii.gz"),
        warp=work("atlas2t2w", extension="1Warp.nii.gz"),
        affine=work("atlas2t2w", extension="0GenericAffine.mat"),
    conda:
        tool_env("ants")
    shell:
        r"""
        prefix=$(dirname {output.labels})/atlas2t2w_
        antsRegistrationSyNQuick.sh -d 3 -f {input.t2w} -m {input.atlas} \
            -o "$prefix" -t s
        antsApplyTransforms -d 3 -i {input.regional} -r {input.t2w} \
            -o {output.labels} -n NearestNeighbor \
            -t "${{prefix}}1Warp.nii.gz" -t "${{prefix}}0GenericAffine.mat"
        cp "${{prefix}}1Warp.nii.gz" {output.warp}
        cp "${{prefix}}0GenericAffine.mat" {output.affine}
        """


rule labels_to_dwi:
    """Refine b0 -> T2w, then pull the labels back into native DWI space.

    Labels move to the data; the diffusion data is never resampled.
    """
    input:
        t2w=subject_t2w,
        b0=rules.mean_b0.output.b0,
        labels=rules.atlas_to_t2w.output.labels,
    output:
        labels=work("regional", space="DWI", extension=".nii.gz"),
    conda:
        tool_env("ants")
    shell:
        r"""
        prefix=$(dirname {output.labels})/b0_to_T2w_
        antsRegistrationSyNQuick.sh -d 3 -f {input.t2w} -m {input.b0} \
            -o "$prefix" -t s
        antsApplyTransforms -d 3 -i {input.labels} -r {input.b0} \
            -o {output.labels} -n NearestNeighbor \
            -t ["${{prefix}}0GenericAffine.mat",1] \
            -t "${{prefix}}1InverseWarp.nii.gz"
        """


rule extract_roi:
    """Binarise one atlas label into an ROI mask."""
    input:
        labels=rules.labels_to_dwi.output.labels,
    output:
        roi=work("roi", label="{label}", extension=".nii.gz"),
    params:
        label_id=lambda w: LABELS[w.label],
    conda:
        tool_env("mrtrix")
    shell:
        "mrcalc {input.labels} {params.label_id} -eq {output.roi} -force -quiet"


rule response_and_fod:
    """Response function + FOD estimation on the motion-corrected data."""
    input:
        dwi=rules.shore_finalize.output.dwi,
        bval=rules.shore_finalize.output.bval,
        bvec=rules.shore_finalize.output.bvec,
        mask=rules.shore_finalize.output.mask,
    output:
        wm=work("responsewm", extension=".txt"),
        csf=work("responsecsf", extension=".txt"),
        fod=work("wmfod", extension=".mif"),
    conda:
        tool_env("mrtrix")
    shell:
        r"""
        gm=$(dirname {output.wm})/response_gm.txt
        dwi2response dhollander -fslgrad {input.bvec} {input.bval} \
            -mask {input.mask} {input.dwi} \
            {output.wm} "$gm" {output.csf} -force
        dwi2fod msmt_csd -fslgrad {input.bvec} {input.bval} {input.dwi} \
            {output.wm} {output.fod} {output.csf} $(dirname {output.wm})/csffod.mif \
            -mask {input.mask} -force
        """


rule tckgen_bundle:
    """ROI-to-ROI tracking for one bundle (AF_L/AF_R/SLF_L/SLF_R)."""
    input:
        fod=rules.response_and_fod.output.fod,
        mask=rules.shore_finalize.output.mask,
        seed=lambda w: work("roi", label=BUNDLES[w.bundle]["seed"],
                            extension=".nii.gz"),
        include=lambda w: work("roi", label=BUNDLES[w.bundle]["include"],
                               extension=".nii.gz"),
    output:
        tck=deriv("tractography", label="{bundle}", extension=".tck"),
    params:
        seeds=P["tractography"]["max_seeds"],
        select=lambda w: hp("tract_select", default=5000),
        cutoff=lambda w: hp("tract_cutoff", default=0.05),
        minlen=P["tractography"]["minlength"],
        maxlen=P["tractography"]["maxlength"],
    conda:
        tool_env("mrtrix")
    shell:
        "tckgen {input.fod} {output.tck} -algorithm iFOD2"
        " -seed_image {input.seed} -include {input.include} -mask {input.mask}"
        " -seeds {params.seeds} -select {params.select} -cutoff {params.cutoff}"
        " -minlength {params.minlen} -maxlength {params.maxlen} -force"


rule tract_density:
    """Streamline density map and its thresholded binary mask."""
    input:
        tck=rules.tckgen_bundle.output.tck,
        template=rules.mean_b0.output.b0,
    output:
        density=deriv("density", label="{bundle}", extension=".nii.gz"),
        mask=deriv("density", label="{bundle}", desc="thresholded",
                   extension=".nii.gz"),
    params:
        thresh=P["tractography"]["density_threshold"],
    conda:
        tool_env("mrtrix")
    shell:
        "tckmap {input.tck} {output.density} -template {input.template} "
        "-precise -force && "
        "mrcalc {output.density} {params.thresh} -ge {output.mask} -force"
