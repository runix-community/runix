{ lib, pkgs, ... }:
{
  runix.packages = [
    (pkgs.callPackage ../pkgs/runix { })
    (pkgs.callPackage ../pkgs/runix-install { })
    pkgs.nix
    pkgs.cacert
  ];
  runix.groups.nixbld.gid = 30000;
  runix.users = builtins.listToAttrs (
    lib.genList (index: {
      name = "nixbld${toString (index + 1)}";
      value = {
        uid = 30001 + index;
        gid = 30000;
        home = "/var/empty";
        shell = "${pkgs.shadow}/bin/nologin";
        extraGroups = [ "nixbld" ];
      };
    }) 16
  );
  runix.environmentVariables = {
    NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    NIX_PATH = "nixpkgs=${pkgs.path}";
  };
  runix.preparationScripts = [
    ''
      mkdir -p /etc/nix /etc/ssl/certs /nix/var/nix/daemon-socket /nix/var/nix/profiles/per-user/root
      ln -sfn ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
      ln -sfn ${pkgs.writeText "runix-nix.conf" ''
        experimental-features = nix-command flakes
        build-users-group = nixbld
        trusted-users = root
      allowed-users = *
      sandbox = true
      nix-path = nixpkgs=${pkgs.path}
      ''} /etc/nix/nix.conf
    ''
  ];
  runix.services.nix-daemon = {
    command = "${pkgs.nix}/bin/nix-daemon";
    check = "test -S /nix/var/nix/daemon-socket/socket";
  };
}
