# Sourced inside the container by the store overlay tests: copies modules/store-overlay/webtop-nix-*
# to /wn-scripts (a copy, because restore-test.sh mounts an overlay on /nix/store) and stubs
# webtop-restore-progress in /stubs, which webtop-nix-restore.sh calls and takes its NIX_CONFIG from.
if [ ! -d /wn-scripts ]; then
  mkdir /wn-scripts && cp /src/modules/store-overlay/webtop-nix-* /wn-scripts/
fi
mkdir -p /stubs
printf '#!/bin/sh
[ "$1" != nixconfig ] || printf %%s "${NIX_CONFIG:-}"
' > /stubs/webtop-restore-progress
chmod +x /stubs/webtop-restore-progress
