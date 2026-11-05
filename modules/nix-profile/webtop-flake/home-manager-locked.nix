# home-manager under the apply lock (ADR 0009); `real` is the home-manager package.
{ pkgs, real }:
pkgs.writeShellApplication {
  name = "home-manager";
  runtimeInputs = [ pkgs.util-linux ];
  text = "WEBTOP_HM_REAL=${real}/bin/home-manager\n" + builtins.readFile ./home-manager-locked.sh;
}
