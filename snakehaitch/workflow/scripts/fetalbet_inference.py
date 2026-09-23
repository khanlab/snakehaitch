#!/usr/bin/env python3
"""
Device-agnostic Fetal-BET inference.

Drop-in replacement for /app/src/codes/inference.py from arfentul/fetalbet-model:first.
Same model, same weights, same pre/post-processing -- but runs on CUDA, Apple MPS,
Intel XPU, or CPU instead of requiring an NVIDIA GPU.

Differences from the original:
  1. Device auto-detection (cuda -> mps -> xpu -> cpu), overridable with --device.
  2. No torch.nn.DataParallel. The shipped checkpoint was saved from a DataParallel
     model, so every key is prefixed "module.". The original relies on the
     --n_gpu default of 2 to rebuild that wrapper, which only makes sense on a
     multi-GPU NVIDIA box. We strip the prefix instead and load a plain model,
     which behaves identically on every backend.
  3. float32 is enforced on the input. MPS has no float64 support, and MONAI's
     Spacingd can emit float64, which would hard-fail on Apple silicon.
  4. Defaults are fp16 / overlap 0.25 rather than fp32 / 0.50 -- see below.

Defaults differ from upstream for speed. Measured on Apple M5 (MPS) over six
volumes of sub-FINDM075 ses-01, against the fp32 / overlap-0.50 reference:

    config              s/volume   speedup   Dice(raw)   Dice(after union+dilate)
    fp32, overlap 0.50     10.80     1.00x   reference   reference
    fp16, overlap 0.50      8.25     1.31x    0.999907   0.999992
    fp16, overlap 0.25      3.08     3.50x    0.991954   0.997088

All configurations produced an identical step-5 crop bounding box, which is the
only product of this step that propagates downstream. Pass --precision fp32
--overlap 0.50 to reproduce upstream output exactly.
"""

import argparse
import os
from glob import glob

import numpy as np
import torch
import monai.transforms as tr
from monai.data import DataLoader, Dataset, decollate_batch
from monai.inferers import SliceInferer
from monai.networks.nets import AttentionUnet
from monai.transforms import MapTransform, SaveImaged
from monai.utils import set_determinism
from tqdm import tqdm


def pick_device(requested=None):
    """Resolve a torch device, preferring the fastest available accelerator."""
    if requested and requested != "auto":
        return torch.device(requested)
    if torch.cuda.is_available():
        return torch.device("cuda")
    if getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
        return torch.device("mps")
    if hasattr(torch, "xpu") and torch.xpu.is_available():
        return torch.device("xpu")
    return torch.device("cpu")


class SliceWiseNormalizeIntensityd(MapTransform):
    """Unchanged from the original: per-slice z-scoring over non-zero voxels."""

    def __init__(self, keys, subtrahend=0.0, divisor=None, nonzero=True):
        super().__init__(keys)
        self.subtrahend = subtrahend
        self.divisor = divisor
        self.nonzero = nonzero

    def __call__(self, data):
        d = dict(data)
        for key in self.keys:
            image = d[key]
            for i in range(image.shape[-1]):
                slice_ = image[..., i]
                if self.nonzero:
                    mask = slice_ > 0
                    if np.any(mask):
                        if self.subtrahend is None:
                            slice_[mask] = slice_[mask] - slice_[mask].mean()
                        else:
                            slice_[mask] = slice_[mask] - self.subtrahend
                        if self.divisor is None:
                            slice_[mask] /= slice_[mask].std()
                        else:
                            slice_[mask] /= self.divisor
                else:
                    if self.subtrahend is None:
                        slice_ = slice_ - slice_.mean()
                    else:
                        slice_ = slice_ - self.subtrahend
                    if self.divisor is None:
                        slice_ /= slice_.std()
                    else:
                        slice_ /= self.divisor
                image[..., i] = slice_
            d[key] = image
        return d


def mask_path_for(image_path, save_path):
    """Where SaveImaged will write this volume's mask.

    Mirrors MONAI's naming: output_postfix="predicted_mask",
    separate_folder=False -> <save_path>/<stem>_predicted_mask.nii.gz
    """
    stem = os.path.basename(image_path)
    for ext in (".nii.gz", ".nii"):
        if stem.endswith(ext):
            stem = stem[: -len(ext)]
            break
    return os.path.join(save_path, f"{stem}_predicted_mask.nii.gz")


def build_transforms():
    return [
        tr.LoadImaged(keys=["image"]),
        tr.EnsureChannelFirstd(keys=["image"]),
        tr.Spacingd(keys="image", pixdim=(1.0, 1.0, -1.0), mode="bilinear", padding_mode="zeros"),
        # MPS cannot handle float64; Spacingd may upcast, so pin the dtype here.
        tr.EnsureTyped(keys=["image"], dtype=torch.float32),
        SliceWiseNormalizeIntensityd(keys=["image"], subtrahend=0.0, divisor=None, nonzero=True),
    ]


def load_state_dict_portable(model, path, device):
    """Load the checkpoint whether or not it carries a DataParallel 'module.' prefix."""
    state = torch.load(path, map_location=device)
    if isinstance(state, dict) and "state_dict" in state:
        state = state["state_dict"]
    stripped = {k[len("module."):] if k.startswith("module.") else k: v for k, v in state.items()}
    missing, unexpected = model.load_state_dict(stripped, strict=False)
    if missing or unexpected:
        raise RuntimeError(f"checkpoint mismatch: missing={missing[:5]} unexpected={unexpected[:5]}")
    return model


AMP_DTYPES = {"fp32": None, "fp16": torch.float16, "bf16": torch.bfloat16}


def inference(args):
    device = pick_device(args.device)
    amp_dtype = AMP_DTYPES[args.precision]
    print(f"[device] {device}  [precision] {args.precision}  [overlap] {args.overlap}")

    model = AttentionUnet(
        spatial_dims=2,
        in_channels=1,
        out_channels=2,
        channels=(64, 128, 256, 512, 1024),
        strides=(2, 2, 2, 2),
        kernel_size=3,
        up_kernel_size=3,
        dropout=0.15,
    )
    load_state_dict_portable(model, args.saved_model_path, device)
    model.to(device)
    if args.channels_last:
        model = model.to(memory_format=torch.channels_last)
    model.eval()
    if args.compile:
        model = torch.compile(model)

    transforms_list = build_transforms()
    images = sorted(glob(os.path.join(args.data_path, "*.nii.gz")))
    if not images:
        raise SystemExit(f"no *.nii.gz found in {args.data_path}")

    # Resume support. Snakemake cannot resume a directory() output -- an
    # interrupted run restarts from volume 0 and throws away everything already
    # computed. Since one mask is written per input volume, skipping volumes
    # that already have one makes the step restartable: a run killed at 27/137
    # picks up at 27 instead of redoing ~3 minutes of GPU work.
    os.makedirs(args.save_path, exist_ok=True)
    if args.resume:
        pending = [p for p in images if not os.path.exists(mask_path_for(p, args.save_path))]
        done = len(images) - len(pending)
        if done:
            print(f"[resume] {done}/{len(images)} already segmented, skipping")
        images = pending
        if not images:
            print("[done] all volumes already segmented")
            return
    print(f"[input] {len(images)} volume(s) to process from {args.data_path}")

    dataloader = DataLoader(
        Dataset(data=[{"image": p} for p in images], transform=tr.Compose(transforms_list)),
        batch_size=1,
        num_workers=0,
    )

    inferer = SliceInferer(
        roi_size=(256, 256), spatial_dim=2, sw_batch_size=args.sw_batch_size,
        overlap=args.overlap, progress=False,
    )

    def forward(x):
        """Model call with optional autocast; always returns fp32 for post-processing."""
        if args.channels_last:
            x = x.contiguous(memory_format=torch.channels_last)
        if amp_dtype is None:
            return model(x)
        with torch.autocast(device_type=device.type, dtype=amp_dtype):
            return model(x).float()

    post_transforms = tr.Compose([
        tr.Invertd(
            keys="pred",
            transform=tr.Compose(transforms_list),
            orig_keys="image",
            meta_keys="pred_meta_dict",
            orig_meta_keys="image_meta_dict",
            meta_key_postfix="meta_dict",
            nearest_interp=False,
            to_tensor=True,
        ),
        tr.Activationsd(keys="pred", softmax=True),
        tr.AsDiscreted(keys="pred", argmax=True, to_onehot=None),
        SaveImaged(
            keys="pred",
            meta_keys="pred_meta_dict",
            output_dir=args.save_path,
            print_log=False,
            separate_folder=False,
            output_postfix="predicted_mask",
            resample=False,
        ),
    ])

    with torch.no_grad():
        for batch in tqdm(dataloader, desc=f"Inference ({device.type})"):
            batch["image"] = batch["image"].to(device)
            pred = inferer(batch["image"], forward)
            # Post-processing (Invertd) runs on CPU; MPS tensors must come back first.
            batch["pred"] = pred.to("cpu")
            batch["image"] = batch["image"].to("cpu")
            for item in decollate_batch(batch):
                post_transforms(item)

    print(f"[done] masks written to {args.save_path}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--device", type=str, default="auto",
                   help="auto | cuda | mps | xpu | cpu (default: auto)")
    p.add_argument("--sw_batch_size", type=int, default=4, help="slices per forward pass")
    p.add_argument("--precision", choices=list(AMP_DTYPES), default="fp16",
                   help="autocast precision (default: fp16; use fp32 for bit-exact upstream output)")
    p.add_argument("--overlap", type=float, default=0.25,
                   help="sliding-window overlap (default: 0.25; upstream Fetal-BET uses 0.50)")
    p.add_argument("--channels-last", action="store_true", dest="channels_last")
    p.add_argument("--no-resume", action="store_false", dest="resume",
                   help="re-segment volumes even if a mask already exists")
    p.add_argument("--compile", action="store_true", help="wrap model in torch.compile")
    p.add_argument("--deterministic", type=int, default=1)
    p.add_argument("--saved_model_path", type=str, required=True)
    p.add_argument("--data_path", type=str, required=True)
    p.add_argument("--save_path", type=str, required=True)
    # Accepted and ignored, so existing HAITCH call sites keep working.
    p.add_argument("--n_gpu", type=int, default=None, help=argparse.SUPPRESS)
    args = p.parse_args()

    set_determinism(seed=12345 if args.deterministic else None)
    inference(args)
