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
    # Mirrors chosen at run time by runix-mirrors; ignored while missing.
    + lib.optionalString mirrors.enable "!include /run/nix/mirrors.conf\n"
  );

  mirrors = config.nix.mirrors;
  # The tool with this system's settings, for the service, the installer and
  # by hand alike.
  mirrorsTool = pkgs.writeShellScriptBin "runix-mirrors" ''
    ${lib.toShellVars mirrorsSettings}
    export ${lib.concatStringsSep " " (lib.attrNames mirrorsSettings)}
    exec ${pkgs.callPackage ../pkgs/runix-mirrors { }}/bin/runix-mirrors "$@"
  '';
  mirrorsSettings = {
    RUNIX_MIRRORS = lib.concatStringsSep " " mirrors.candidates;
    RUNIX_SUBSTITUTERS = lib.concatStringsSep " " otherSubstituters;
    RUNIX_MIN_SPEED = toString mirrors.minimumSpeed;
    RUNIX_INTERVAL = toString mirrors.interval;
    # Store paths sure to be on cache.nixos.org, to measure real downloads.
    RUNIX_SAMPLES = "${pkgs.nix} ${pkgs.coreutils} ${pkgs.glibc}";
  }
  // lib.optionalAttrs (config.nix.proxy != null) { RUNIX_PROXY = config.nix.proxy; };
  # What runix-mirrors keeps next to the mirrors, which replace cache.nixos.org.
  otherSubstituters = lib.filter (url: url != "https://cache.nixos.org") (
    lib.toList (config.nix.settings.substituters or [ ])
    ++ lib.toList (config.nix.settings.extra-substituters or [ ])
  );
in
{
  options.nix.mirrors = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        For networks where cache.nixos.org is censored, as in Russia. The
        live installer turns this on, and so does the installed system when
        installing needed a mirror. Tests cache.nixos.org at boot and every few hours. When it is blocked
        or slower than minimumSpeed, Nix uses the fastest working mirror
        instead. Mirrors are contacted only then, and every download is still
        checked against cache.nixos.org's signing key. See `runix-mirrors status`.
      '';
    };
    candidates = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "https://nixos-cache-proxy.cofob.dev"
        "https://cache.nixos.kz"
        "https://ncproxy.vizqq.cc"
      ];
      # mirror.yandex.ru/nixos answers the speed test but times out on real
      # installs, so it is left out.
      description = "Mirrors of cache.nixos.org to try, in no particular order.";
    };
    minimumSpeed = lib.mkOption {
      type = lib.types.ints.positive;
      default = 262144;
      description = "Download speed from cache.nixos.org, in bytes per second, below which mirrors are tried.";
    };
    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 21600;
      description = "Seconds between tests.";
    };
  };

  options.nix.proxy = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "http://192.168.1.10:8080";
    description = ''
      HTTP proxy for Nix's downloads. Without it, the runix.proxy=URL kernel
      parameter is used, which also works on the live installer.
    '';
  };

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
    # Store files reach the disk before Nix registers them: a power cut can
    # no longer leave empty .drv files or links that make the store unusable.
    fsync-store-paths = lib.mkDefault true;
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
    mirrorsTool
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
    # Through runix-mirrors only to pick up the proxy.
    command = "${mirrorsTool}/bin/runix-mirrors exec ${pkgs.nix}/bin/nix-daemon";
    check = "test -S /nix/var/nix/daemon-socket/socket";
  };
  config.runix.services.nix-mirrors = lib.mkIf mirrors.enable {
    command = "${mirrorsTool}/bin/runix-mirrors watch";
  };
}
