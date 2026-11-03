"""Markdown layer table of a built nix2container image, compared with a published one.

Usage: layer-report.py IMAGE_JSON GROUPS_JSON [--previous REF] [--pushed REF@DIGEST]

nix2container layers are uncompressed, so their digests are the diff_ids; a layer is new when
the previous image's config lacks its diff_id. --pushed adds the compressed sizes and the bytes
a node holding --previous would pull. REF: registry/repo:tag or @digest; an index resolves to the
built image's architecture. REGISTRY_AUTH=user:token for a private repository.
"""
import argparse
import base64
import json
import os
import urllib.request

MiB = 1 << 20
ACCEPT = ",".join([
    "application/vnd.oci.image.index.v1+json", "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json"])


class Registry:
    def __init__(self, ref):
        host, rest = ref.split("/", 1)
        self.host = host
        if "@" in rest:
            self.repo, self.ref = rest.split("@", 1)
        else:
            self.repo, self.ref = rest.rsplit(":", 1)
        url = f"https://{host}/token?scope=repository:{self.repo}:pull"
        req = urllib.request.Request(url)
        if os.environ.get("REGISTRY_AUTH"):
            req.add_header("Authorization", "Basic " + base64.b64encode(os.environ["REGISTRY_AUTH"].encode()).decode())
        self.token = json.load(urllib.request.urlopen(req))["token"]

    def get(self, kind, ref, accept=ACCEPT):
        req = urllib.request.Request(f"https://{self.host}/v2/{self.repo}/{kind}/{ref}",
                                     headers={"Authorization": f"Bearer {self.token}", "Accept": accept})
        return json.load(urllib.request.urlopen(req))

    def manifest(self, arch):
        m = self.get("manifests", self.ref)
        if "manifests" in m:
            d = next(x["digest"] for x in m["manifests"] if x.get("platform", {}).get("architecture") == arch)
            m = self.get("manifests", d)
        return m

    def diff_ids(self, manifest):
        return self.get("blobs", manifest["config"]["digest"], "*/*")["rootfs"]["diff_ids"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("groups")
    ap.add_argument("--previous")
    ap.add_argument("--pushed")
    args = ap.parse_args()
    with open(args.image) as f:
        image = json.load(f)
    with open(args.groups) as f:
        names = json.load(f) + ["top (DB, rootfs)"]
    layers = image["layers"]
    arch = image["arch"]

    prev_ids, prev_blobs = set(), set()
    if args.previous:
        try:
            r = Registry(args.previous)
            m = r.manifest(arch)
            prev_ids = set(r.diff_ids(m))
            prev_blobs = {l["digest"] for l in m["layers"]}
        except Exception as e:  # first publish, or the tag is gone
            print(f"previous image {args.previous} not readable ({e}); every layer counts as new\n")
    pushed = None
    if args.pushed:
        r = Registry(args.pushed)
        pushed = r.manifest(arch)["layers"]

    head = "| # | layer | paths | MiB | diff_id | new |"
    sep = "| ---: | --- | ---: | ---: | --- | --- |"
    if pushed:
        head += " compressed MiB |"
        sep += " ---: |"
    out = [head, sep]
    new_bytes = 0
    for i, l in enumerate(layers):
        new = l["digest"] not in prev_ids
        new_bytes += l["size"] if new else 0
        row = (f"| {i} | {names[i] if i < len(names) else '?'} | {len(l.get('paths') or [])} | "
               f"{l['size'] / MiB:.0f} | `{l['digest'][7:19]}` | {'yes' if new else ''} |")
        if pushed:
            row += f" {pushed[i]['size'] / MiB:.0f} |"
        out.append(row)
    total = sum(l["size"] for l in layers)
    out.append("")
    out.append(f"{arch}: {len(layers)} layers, {total / MiB:.0f} MiB uncompressed; "
               f"new against {args.previous or 'nothing'}: {new_bytes / MiB:.0f} MiB uncompressed.")
    if pushed:
        ctotal = sum(l["size"] for l in pushed)
        pull = sum(l["size"] for l in pushed if l["digest"] not in prev_blobs)
        out.append(f"Pushed {ctotal / MiB:.0f} MiB compressed; a node with the previous image pulls {pull / MiB:.0f} MiB.")
    print("\n".join(out))


if __name__ == "__main__":
    main()
