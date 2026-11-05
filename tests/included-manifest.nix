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
  for n in webtop-app-screen nix-software-center; do
    jq -e --arg n "$n" 'any(.packages[]; .pname == $n)' $m >/dev/null || fail "$n is not in the manifest"
  done

  q() { sqlite3 -batch "$db" "$1"; }
  entries=$(jq '.packages | length' $m)
  names=$(jq -r '[.packages[].pname] | unique | .[]' $m)
  matched=0; unmatched=""; ties=""; picks=""
  for n in $names; do
    attrs=$(q "SELECT attribute FROM pkgs WHERE pname = '$n' AND instr(attribute, ':') = 0 ORDER BY 1")
    [ -n "$attrs" ] || { unmatched="$unmatched $n"; continue; }
    matched=$((matched + 1))
    exact=$(echo "$attrs" | awk -F. -v n="$n" '$NF == n')
    if [ -n "$exact" ]; then pick=$exact; else pick=$attrs; fi
    [ "$(echo "$attrs" | wc -l)" = 1 ] || ties="$ties
    $n: candidates [$(echo $attrs)] -> [$(echo $pick)]"
    picks="$picks $n=$(echo $pick | tr ' ' ',')"
  done
  echo "manifest: $entries entries, $(echo "$names" | wc -w) distinct pnames, $matched matched by pname, $(echo $unmatched | wc -w) unmatched"
  echo "unmatched:$unmatched"
  echo "ties:$ties"
  echo "picks:$picks"

  touch $out
''
