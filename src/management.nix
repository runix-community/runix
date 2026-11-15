{
  config,
  lib,
  pkgs,
  ...
}:
let
  nixPath = lib.concatStringsSep ":" config.runix.nixPath;

  # nix.conf syntax: lists are space separated, booleans are true/false.
  render =
    value:
    if lib.isList value then
      lib.concatMapStringsSep " " render value
    else if lib.isBool value then
      lib.boolToString value
    else
      toString value;
  nixConf = pkgs.writeText "runix-nix.conf" (
    lib.concatStrings (
      lib.mapAttrsToList (name: value: "${name} = ${render value}\n") config.nix.settings
    )
  );
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

  options.nix.settings = lib.mkOption {
    type =
      let
        atom = lib.types.oneOf [
          lib.types.bool
          lib.types.int
          lib.types.str
        ];
      in
      lib.types.attrsOf (lib.types.either atom (lib.types.listOf atom));
    default = { };
    example = lib.literalExpression ''
      {
        extra-substituters = [ "https://cache.example.org" ];
        extra-trusted-public-keys = [ "cache.example.org-1:..." ];
        trusted-users = [ "alice" ];
        auto-optimise-store = true;
      }
    '';
    description = ''
      Settings written to /etc/nix/nix.conf. Lists add to the defaults, which
      trust cache.nixos.org and the Runix cache; use lib.mkForce to replace
      one. See `man nix.conf` for every setting.
    '';
  };

  config.nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    build-users-group = lib.mkDefault "nixbld";
    trusted-users = [ "root" ];
    allowed-users = [ "*" ];
    sandbox = lib.mkDefault true;
    # Setting substituters replaces Nix's built-in default, so it is listed.
    substituters = [
      "https://cache.nixos.org"
      "https://runix-community.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "runix-community.cachix.org-1:sENfG2mPWobsz1MKahUs+HOGfVt2L3OvG5oHHD5/coE="
    ];
  }
  // lib.optionalAttrs (nixPath != "") { nix-path = lib.mkDefault nixPath; };

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
      ln -sfn ${nixConf} /etc/nix/nix.conf
    ''
  ];
  config.runix.services.nix-daemon = {
    command = "${pkgs.nix}/bin/nix-daemon";
    check = "test -S /nix/var/nix/daemon-socket/socket";
  };
}
