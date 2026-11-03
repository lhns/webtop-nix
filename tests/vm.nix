# Boots the module and checks that Selkies answers. Needs KVM to run; evaluates without.
{ pkgs, self }:

let
  userDirs = pkgs.writeText "user-dirs.dirs" ''
    XDG_DOWNLOAD_DIR="$HOME/Inbox"
  '';
  # One setting the user may change and one they may not.
  userSettings = pkgs.writeText "selkies.env" ''
    # comment
    SELKIES_FRAMERATE=33
    SELKIES_FILE_TRANSFERS=none
  '';
in
pkgs.testers.runNixOSTest {
  name = "webtop";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    # Overrides the module's SELKIES_USE_BROWSER_CURSORS=true; the "-" makes a missing file harmless.
    services.webtop.environmentFiles = [ "-/etc/webtop-test.env" ];
    environment.etc."webtop-test.env".text = "SELKIES_USE_BROWSER_CURSORS=false
";
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("selkies.service", "user")
    machine.wait_for_open_port(8082)
    machine.succeed("curl -sf http://localhost:8082/ | grep -qi '<html'")
    machine.wait_for_unit("webtop-session.service")

    # A gray screen is KWin up but not compositing (no render device); the session unit still looks healthy.
    ${import ./wait-compositing.nix}

    # Uploads and downloads, runtime settings. The XDG download dir is a custom one, so the
    # upload directory is not hard-coded; the user's settings file mixes an allowed and a refused key.
    user = lambda cmd: machine.succeed(f"runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 {cmd}")
    machine.succeed("install -D -o user -m644 ${userDirs} /home/user/.config/user-dirs.dirs")
    machine.succeed("install -D -o user -m644 ${userSettings} /home/user/.config/webtop/selkies.env")
    machine.succeed("install -D -o user -m644 ${userDirs} /home/user/Documents/doc.txt")
    machine.succeed("chown -R user: /home/user")
    user("systemctl --user restart selkies.service")
    machine.wait_for_open_port(8082)

    pid = user("systemctl --user show -p MainPID --value selkies.service").strip()
    env = machine.succeed(f"xargs -0 -n1 < /proc/{pid}/environ")
    assert "SELKIES_USE_BROWSER_CURSORS=false" in env, "environmentFiles entry did not override the default"
    assert "SELKIES_FRAMERATE=33" in env, "allowlisted user setting not applied"
    assert "SELKIES_FILE_TRANSFERS=upload,download" in env, "non-allowlisted user setting was applied"
    assert "SELKIES_UPLOAD_PATH=/home/user/Inbox" in env, "upload path is not the XDG download dir"

    machine.succeed(
        "curl -sf -X POST -H 'X-Upload-Path: hello.txt' --data-binary 'hi there' http://localhost:8082/api/upload"
    )
    assert machine.succeed("cat /home/user/Inbox/hello.txt") == "hi there"
    machine.fail("test -e /home/user/hello.txt")
    machine.fail("test -e /home/user/Desktop/hello.txt")

    # Downloads are served from the whole home.
    assert machine.succeed("curl -sf http://localhost:8082/api/files/Documents/doc.txt").strip() == 'XDG_DOWNLOAD_DIR="$HOME/Inbox"'
    machine.succeed("curl -sfL http://localhost:8082/api/files/ -o /tmp/files.html && grep -q Documents /tmp/files.html")
  '';
}
