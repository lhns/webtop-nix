# Sourced inside the container by the store overlay tests: copies modules/store-overlay/webtop-nix-*
# to /wn-scripts. A copy, because restore-test.sh mounts an overlay on /nix/store.
if [ ! -d /wn-scripts ]; then
  mkdir /wn-scripts && cp /src/modules/store-overlay/webtop-nix-* /wn-scripts/
fi
