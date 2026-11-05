# The software center's manifest of the image's apps: valid JSON, lists the module's own packages,
# and matches the catalogue by pname the way the app does (nix-software-center, system_manifest.rs).
# The log has the match counts.
{ pkgs, sys, pkgdb }:

let
  manifest = sys.config.environment.etc."nsc/system-manifest.json".source;
in
pkgs.runCommand "included-manifest-check" { nativeBuildInputs = [ pkgs.jq pkgs.sqlite ]; } ''
  m=${manifest}
  db=${pkgdb}/nixpkgs.db
  fail() { echo "FAIL: $*" >&2; exit 1; }

  jq -e '.version == 1 and (.packages | length) > 0' $m >/dev/null || fail "not a manifest"
  jq -e 'all(.packages[]; (.pname | type == "string" and length > 0) and (.version | type == "string") and (.path | type == "string" and startswith("/nix/store/")))' $m >/dev/null \
    || fail "malformed entry"
  for n in webtop-app-screen nix-software-center dolphin; do
    jq -e --arg n "$n" 'any(.packages[]; .pname == $n)' $m >/dev/null || fail "$n is not in the manifest"
  done

  smoke=${pkgs.nix-software-center}/libexec/nix-software-center/nsc-backend-smoke
  $smoke --system-manifest $m --pkgdb $db | tee report.txt
  grep -q '^match: dolphin .* -> \[kdePackages.dolphin\]$' report.txt || fail "dolphin"

  touch $out
''
