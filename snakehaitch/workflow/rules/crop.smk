# =============================================================================
#  STEP 5 : union mask -> dilate -> crop -> skull-strip
# =============================================================================
#  Original: dMRI_HAITCH_Fixed.sh lines ~526-616
#
#  This is the step that absorbs per-volume segmentation failures: every mask
#  is reduced to its largest connected component, all masks are unioned, and
#  the union is dilated before it defines the crop box. That is why the
#  fp16 / overlap-0.25 segmentation settings are safe -- their differences do
#  not survive to the crop box.
# =============================================================================


rule union_mask:
    """Largest-component filter each volume mask, then union them."""
    input:
        maskdir=rules.segment_volumes.output.maskdir,
    output:
        mask=temp(work("unionmask", extension=".mif")),
    conda:
        tool_env("mrtrix")
    shell:
        r"""
        first=$(ls {input.maskdir}/*_mask.nii.gz | sort | head -1)
        mrconvert "$first" {output.mask} -force -quiet
        for m in {input.maskdir}/*_mask.nii.gz ; do
            maskfilter -largest "$m" connect - -quiet | \
              mrcalc {output.mask} - -max {output.mask} -force -quiet
        done
        """


rule dilate_union_mask:
    """Dilate the union mask; this defines the crop box for everything after."""
    input:
        mask=rules.union_mask.output.mask,
    output:
        mask=temp(work("unionmaskdilated", extension=".mif")),
    params:
        npass=lambda w: hp("mask_dilate_npass", default=3),
    conda:
        tool_env("mrtrix")
    shell:
        "maskfilter -largest {input.mask} connect - -quiet | "
        "maskfilter -npass {params.npass} - dilate {output.mask} -quiet"


rule crop_dwi:
    """Crop the 4D DWI and the mask to the dilated union box.

    The original then forced even dimensions on each axis; that is folded in
    here rather than repeated as three near-identical mrconvert calls.
    """
    input:
        dwi=rules.rician_correct.output.dwi,
        mask=rules.dilate_union_mask.output.mask,
    output:
        dwi=temp(work("dwicrop", extension=".mif")),
        mask=temp(work("maskcrop", extension=".nii.gz")),
    conda:
        tool_env("mrtrix")
    shell:
        r"""
        mrgrid -all_axes {input.dwi} crop -mask {input.mask} {output.dwi} -force -quiet
        mrgrid -all_axes {input.mask} crop -mask {input.mask} {output.mask} -force -quiet
        # force even dimensions on x/y/z
        for f in {output.dwi} {output.mask} ; do
            for ax in 0 1 2 ; do
                n=$(mrinfo -size "$f" -quiet | awk -v a=$((ax+1)) '{{print $a}}')
                if [ $((n % 2)) -ne 0 ] ; then
                    mrconvert -coord $ax 0:$((n-2)) "$f" "$f" -force -quiet
                fi
            done
        done
        """
