# The image with an admin's NixOS module, system.nix beside this file, in its system (ADR 0020,
# README "System module"):
#   docker build -t my-webtop image/system
# IMAGE and BUILDER must come from one build of the image (its tag and <tag>-builder); the installer
# refuses any other pair. The build needs the network (cache.nixos.org).
ARG IMAGE=ghcr.io/lhns/webtop-nix:main
ARG BUILDER=${IMAGE}-builder

FROM ${BUILDER} AS build
COPY system.nix /system.nix
RUN ["/webtop-builder/bin/webtop-system-build", "/system.nix"]

# The result: the image's layers and one more with the new store paths, the Nix DB, /sbin/init and the stamp.
FROM ${IMAGE}
RUN --mount=type=bind,from=build,source=/webtop-system,target=/webtop-system ["/webtop-system/bin/sh", "/webtop-system/install"]
