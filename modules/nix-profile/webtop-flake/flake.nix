# The image's own flake (registry entry `webtop`): modules for the user's home-manager flake.
{
  outputs = _: {
    # webtop.homeModules.packages ./packages.json
    homeModules.packages = import ./packages.nix;
    # Imported by `packages` already; for a home that does not use it.
    homeModules.ssoLogout = ./sso-logout.nix;
    homeModules.timeLocale = ./time-locale.nix;
  };
}
