# KGuiAddons whose Wayland clipboard thread stops waiting for its lock once interrupted: a Plasma
# session stopped in its first seconds left plasmashell deadlocked on exit, so every stop of the
# session took plasmashell's 40 s stop timeout. Grafted like KWin (pkgs/kwin.nix), no rebuilds.
{ kdePackages }:

kdePackages.kguiaddons.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./kguiaddons/kguiaddons-clipboard-thread-interruptible-lock.patch ];
})
