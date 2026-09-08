{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix;
  zfs = cfg.zfs;
  root =
    config.fileSystems."/" or {
      device = "";
      fsType = "";
    };
  pools = if zfs.maintenance.pools == [ ] then [ zfs.rootPool ] else zfs.maintenance.pools;
  poolArgs = lib.escapeShellArgs pools;

  periodicService = name: interval: command: {
    script = ''
      while ${pkgs.coreutils}/bin/sleep ${toString interval}; do
        ${command}
      done
    '';
  };
in
{
  options.runix.zfs = {
    enable = lib.mkEnableOption "ZFS root support";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.zfs;
      description = "ZFS userspace tools package; custom kernel package sets may provide a combined package.";
    };
    modulePackage = lib.mkOption {
      type = lib.types.package;
      default = cfg.kernel.packageSet.${zfs.package.kernelModuleAttribute};
      description = "ZFS kernel module package matching runix.kernel.package.";
    };
    hostId = lib.mkOption {
      type = lib.types.strMatching "[0-9a-fA-F]{8}";
      description = "Eight hexadecimal digit ZFS host ID.";
    };
    devNodes = lib.mkOption {
      type = lib.types.strMatching "/.*";
      default = "/dev";
      description = "Device directory searched while importing ZFS pools.";
    };
    forceImportRoot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to force import the root pool after an unclean export.";
    };
    rootPool = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = builtins.head (lib.splitString "/" root.device);
      description = "Pool name derived from the root dataset.";
    };
    maintenance = {
      pools = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Pools maintained periodically; an empty list selects the root pool.";
      };
      scrub = {
        enable = lib.mkEnableOption "periodic ZFS scrubs";
        intervalSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 30 * 24 * 60 * 60;
          description = "Seconds between ZFS scrub starts.";
        };
      };
      trim = {
        enable = lib.mkEnableOption "periodic ZFS TRIM";
        intervalSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 7 * 24 * 60 * 60;
          description = "Seconds between ZFS TRIM requests.";
        };
      };
    };
  };

  config = lib.mkIf zfs.enable {
    assertions = [
      {
        assertion = builtins.hasAttr "/" config.fileSystems;
        message = "runix.zfs.enable requires fileSystems.\"/\" because a dataset cannot be inferred from fstab before pool import";
      }
      {
        assertion = root.fsType == "zfs";
        message = "runix.zfs.enable requires fileSystems.\"/\".fsType = \"zfs\"";
      }
      {
        assertion = lib.hasInfix "/" root.device;
        message = "fileSystems.\"/\".device must be a ZFS dataset such as rpool/root";
      }
      {
        assertion = zfs.modulePackage.version == zfs.package.version;
        message = "runix ZFS userspace and kernel module package versions must match";
      }
    ];

    runix.kernel = {
      parameters = lib.mkBefore [ "nohibernate" ];
      modulePackages = [ zfs.modulePackage ];
    };
    runix.initrd = {
      modules = [ "zfs" ];
    };
    runix.packages = [ zfs.package ];
    runix.preparationScripts = [
      ''
        ${zfs.package}/bin/zgenhostid -f ${lib.escapeShellArg zfs.hostId}
      ''
    ];
    runix.shutdownScripts = [
      ''
        ${zfs.package}/bin/zpool sync ${poolArgs} || true
      ''
    ];
    runix.services = lib.mkMerge [
      {
        zed.command = "${zfs.package}/bin/zed -F";
      }
      (lib.mkIf zfs.maintenance.scrub.enable {
        zfs-scrub = periodicService "scrub" zfs.maintenance.scrub.intervalSeconds ''
          for pool in ${poolArgs}; do
            ${zfs.package}/bin/zpool scrub "$pool" || true
          done
        '';
      })
      (lib.mkIf zfs.maintenance.trim.enable {
        zfs-trim = periodicService "trim" zfs.maintenance.trim.intervalSeconds ''
          for pool in ${poolArgs}; do
            ${zfs.package}/bin/zpool trim "$pool" || true
          done
        '';
      })
    ];
  };
}
