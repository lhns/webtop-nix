# 0005 — Image builder with a layer split from the closure

- Status: Accepted
- Date: 2026-11-03

## Context

The desktop ships as a NixOS container image of several GB. nix2container's popularity layering
(`maxLayers`) gives the first layers one small base library each and puts everything else, the Nix
DB included, in one last layer that changes on every build, so every update was a full pull.
Consumers (kube-webtop-workspaces) build their own image from their own NixOS configuration.

## Decision

- This flake owns the image builder (`lib.buildImage`, `image/`) and publishes a standalone,
  `docker run`-able image (`ghcr.io/lhns/webtop-nix`).
- Layers are an explicit split of the image's own closure, computed at build time
  (`split-layers.py`, nix2container `layersFile`): groups anchored on the system's packages, in a
  fixed order from stable (base, toolkits, data, KDE) to volatile (webtop packages, the KWin graft,
  the consumer's own groups, config); the Nix DB and the root files are the small top layer. Large
  groups are chunked by a hash of the path, so a path joining or leaving moves only its chunk.
- Images share the logic, not layers: no `FROM`, no byte-identical layers across images. Each
  image's layers hold only its own closure; reuse is between versions of one image. The standalone
  image's closure is the reference that decides which paths count as the stack: a consumer's own
  paths go to its own groups instead of reshuffling the stack's.
- Layers are pushed zstd-compressed at a fixed level with nix2container's pinned skopeo, which
  gives the same blob for the same layer on every run.
- This flake owns the nixpkgs pin; consumers follow it.

## Consequences

- An update that leaves nixpkgs alone pulls only the layers it changed; a nixpkgs bump changes
  every store path and stays a full pull.
- The group anchors and their order are part of this repo's interface: changing them changes every
  consumer's layer digests once.
- The config group has a size ceiling: a large path no group anchors fails the build instead of
  landing in the per-build layer.
- A skopeo or compression-level change re-uploads and re-pulls every layer once.
