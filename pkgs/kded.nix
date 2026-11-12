# kded6 that keeps a SIGTERM taken during its startup: its handler's quit() does nothing before the
# event loop runs, so a session stopped in its first seconds left kded6 to its 5 s stop timeout and
# SIGKILL. Grafted like KGuiAddons (pkgs/kguiaddons.nix), no rebuilds.
{ kdePackages }:

kdePackages.kded.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./kded/kded-sigterm-during-startup.patch ];
})
