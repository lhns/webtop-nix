# Nix with `nix profile` backends (profile-backends.patch, ADR 0006): its settings are client-side,
# the daemon (same binary) never reads them.
# path-input-fingerprint.patch: a locked `path:` input (the image's registry entries, so the users'
# nixpkgs) has no fetcher cache entry, so every evaluation of the home flake dumps all of nixpkgs to
# the store again. Drop it once upstream's PathInputScheme has a getFingerprint.
# daemon-eof-wait.patch (nix-store, so the daemon too; NixOS/nix#2176): a builder whose last process
# closes its output before exiting (coreutils does at exit) is SIGKILLed on the log EOF and fails with
# signal 9. The worker now waits for its exit (pidfd) up to `builder-exit-timeout`, other builds running.
{ nixVersions }:

(nixVersions.nixComponents_2_34.overrideScope (final: prev: {
  nix-cli = prev.nix-cli.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./profile-backends.patch ];
  });
  nix-fetchers = prev.nix-fetchers.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./path-input-fingerprint.patch ];
  });
  nix-store = prev.nix-store.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./daemon-eof-wait.patch ];
  });
  # The unit and functional test gate would rebuild and rerun everything against the patched CLI.
  nix-everything = prev.nix-everything.overrideAttrs { doCheck = false; };
})).nix-everything
