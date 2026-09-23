# =============================================================================
#  STEP 7 : B1 field bias correction (N4 via ANTs)
# =============================================================================
#  Original: dMRI_HAITCH_Fixed.sh lines ~1492-1613, single-echo branch.
#
#  Only the Using_B0 path is implemented -- "Individually" and "using_mask"
#  are upstream stubs that print "To be implemented" and do nothing.
#
#  STEP 6 (distortion correction) has no rule: with one echo time and one
#  phase-encoding direction the original short-circuits to a no-op.
# =============================================================================


rule match_mask_to_dwi:
    """Put mask and DWI on the same grid; ANTs requires identical geometry."""
    input:
        mask=rules.crop_dwi.output.mask,
        dwi=rules.crop_dwi.output.dwi,
    output:
        mask=temp(work("biasmask", extension=".nii.gz")),
    conda:
        tool_env("mrtrix")
    shell:
        "mrtransform {input.mask} -template {input.dwi} -interp nearest "
        "{output.mask} -force -quiet"


rule bias_correct:
    """N4 bias field estimation and removal, driven off the b0."""
    input:
        dwi=rules.crop_dwi.output.dwi,
        mask=rules.match_mask_to_dwi.output.mask,
    output:
        dwi=temp(work("dwibc", extension=".mif")),
        field=temp(work("biasfield", extension=".mif")),
    conda:
        tool_env("ants")
    shell:
        "dwibiascorrect ants -mask {input.mask} -bias {output.field} "
        "{input.dwi} {output.dwi} -force"
