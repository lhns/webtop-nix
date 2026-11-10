# Sleep (freezing the session) and the session save of a container (README, "Sleep and session save").
# Go, because the freeze's retry and thaw-on-failure logic is where a shell rewrite would regress (ADR 0012).
{ buildGoModule }:

buildGoModule {
  pname = "webtop-power";
  version = "0.1.0";
  src = ./.;
  # Update with go.sum (the CI nix job fails on a stale hash).
  vendorHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  env.CGO_ENABLED = 0;
  ldflags = [ "-s" "-w" ];
  meta.mainProgram = "webtop-power";
}
