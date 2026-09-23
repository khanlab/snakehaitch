#!/usr/bin/env python3
"""Fetch the Fetal-BET AttUNet weights without pulling the 6 GB image.

arfentul/fetalbet-model:first is a linux/amd64 CUDA image; only one of its ten
layers (137 MB) carries /app/src/model/AttUNet.pth. This pulls that single
layer straight from the Docker registry and extracts the checkpoint, which is
the only artefact the conda-based segmentation rule still needs.

No Docker daemon is required -- this is plain HTTPS against the registry API,
so it works identically on Linux, macOS and Windows.
"""

import hashlib
import io
import json
import os
import tarfile
import urllib.request

REPO = "arfentul/fetalbet-model"
AUTH = "https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"
BLOB = "https://registry-1.docker.io/v2/{repo}/blobs/{digest}"


def get_token(repo):
    with urllib.request.urlopen(AUTH.format(repo=repo)) as resp:
        return json.load(resp)["token"]


def fetch_blob(repo, digest, token):
    req = urllib.request.Request(
        BLOB.format(repo=repo, digest=digest),
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req) as resp:
        return resp.read()


def main(digest, member, out_path):
    token = get_token(REPO)
    print(f"[fetch] layer {digest[:19]}... from {REPO}")
    blob = fetch_blob(REPO, digest, token)

    # The registry addresses layers by the digest of the compressed blob;
    # verify before trusting the contents.
    actual = "sha256:" + hashlib.sha256(blob).hexdigest()
    if actual != digest:
        raise SystemExit(f"digest mismatch: expected {digest}, got {actual}")
    print(f"[fetch] {len(blob) / 1e6:.1f} MB, digest verified")

    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        try:
            src = tar.extractfile(member)
        except KeyError:
            raise SystemExit(f"{member} not found in layer")
        if src is None:
            raise SystemExit(f"{member} is not a regular file")
        os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
        with open(out_path, "wb") as dst:
            while chunk := src.read(1 << 20):
                dst.write(chunk)

    print(f"[fetch] wrote {out_path} ({os.path.getsize(out_path) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main(
        snakemake.params.digest,  # noqa: F821
        snakemake.params.member,  # noqa: F821
        str(snakemake.output.weights),  # noqa: F821
    )
