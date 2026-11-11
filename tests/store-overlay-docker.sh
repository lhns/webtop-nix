#!/bin/sh
# Runs the store overlay tests in privileged nixos/nix containers (overlay mounts) against the scripts in
# modules/store-overlay:
#   restore-test.sh  webtop-nix-restore.sh after an image update
#   partial-test.sh  webtop-nix-lower / webtop-nix-partial (the overlay kept across an image update)
# Needs docker and jq.
#
# Usage: store-overlay-docker.sh [restore|partial]...
set -e
cd "$(dirname "$0")/.."
rev=$(jq -r '.nodes[.nodes.root.inputs.nixpkgs].locked.rev' flake.lock)
for t in ${*:-restore partial}; do
  echo "::group::$t"
  docker run --rm --privileged -e NIXPKGS_REV="$rev" -v "$PWD:/src:ro" nixos/nix:2.34.9 "/src/tests/store-overlay-$t-test.sh"
  echo "::endgroup::"
done
