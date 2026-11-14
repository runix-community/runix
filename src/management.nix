{
  config,
  lib,
  pkgs,
  ...
}:
let
  nixPath = lib.concatStringsSep ":" config.runix.nixPath;
in
{
  options.runix.nixPath = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ "nixpkgs=${pkgs.path}" ];
    defaultText = lib.literalExpression ''[ "nixpkgs=''${pkgs.path}" ]'';
    description = ''
      Entries for NIX_PATH and the nix-path setting. The default keeps the
      system's nixpkgs source, about 190 MiB, so `<nixpkgs>` works offline.
    '';
  };

  config.runix.packages = [
    (pkgs.callPackage ../pkgs/runix { })
    (pkgs.callPackage ../pkgs/runix-install { })
    pkgs.nix
    pkgs.cacert
  ];
  config.runix.groups.nixbld.gid = 30000;
  config.runix.users = builtins.listToAttrs (
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
  config.runix.environmentVariables = {
    NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  }
  // lib.optionalAttrs (nixPath != "") { NIX_PATH = nixPath; };
  config.runix.preparationScripts = [
    ''
      mkdir -p /etc/nix /etc/ssl/certs /nix/var/nix/daemon-socket /nix/var/nix/profiles/per-user/root
      ln -sfn ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
      ln -sfn ${pkgs.writeText "runix-nix.conf" ''
        experimental-features = nix-command flakes
        build-users-group = nixbld
        trusted-users = root
        allowed-users = *
        sandbox = true
        nix-path = ${nixPath}
      ''} /etc/nix/nix.conf
    ''
  ];
  config.runix.services.nix-daemon = {
    command = "${pkgs.nix}/bin/nix-daemon";
    check = "test -S /nix/var/nix/daemon-socket/socket";
  };
}
