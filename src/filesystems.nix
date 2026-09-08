{
  config,
  lib,
  pkgs,
  ...
}:
let
  fileSystemType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        device = lib.mkOption {
          type = lib.types.str;
          description = "Block device, dataset, or special mount source.";
        };
        fsType = lib.mkOption {
          type = lib.types.str;
          description = "Filesystem type passed to mount.";
        };
        options = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "defaults" ];
          description = "Mount options.";
        };
        neededForBoot = lib.mkOption {
          type = lib.types.bool;
          default = name == "/" || name == "/nix";
          description = "Whether this filesystem must be mounted by the initrd.";
        };
      };
    }
  );
  byDepth =
    left: right:
    let
      leftLength = builtins.stringLength left.mountPoint;
      rightLength = builtins.stringLength right.mountPoint;
    in
    leftLength < rightLength || (leftLength == rightLength && left.mountPoint < right.mountPoint);
  fileSystems = lib.mapAttrsToList (
    mountPoint: value: value // { inherit mountPoint; }
  ) config.fileSystems;
  sortedFileSystems = lib.sort byDepth fileSystems;
  fstab = pkgs.writeText "runix-fstab" (
    lib.concatMapStringsSep "\n" (
      fileSystem:
      "${fileSystem.device} ${fileSystem.mountPoint} ${fileSystem.fsType} "
      + "${lib.concatStringsSep "," fileSystem.options} 0 ${
        if fileSystem.mountPoint == "/" then "1" else "2"
      }"
    ) sortedFileSystems
    + "\n"
  );
in
{
  options.fileSystems = lib.mkOption {
    type = lib.types.attrsOf fileSystemType;
    default = { };
    example = {
      "/" = {
        device = "/dev/disk/by-uuid/ROOT-UUID";
        fsType = "ext4";
      };
    };
    description = "Filesystems mounted by the initrd or during system activation.";
  };

  config = {
    assertions = [
      {
        assertion = builtins.all (fileSystem: lib.hasPrefix "/" fileSystem.mountPoint) sortedFileSystems;
        message = "all fileSystems attribute names must be absolute mount points";
      }
      {
        assertion = !builtins.hasAttr "/nix" config.fileSystems || config.fileSystems."/nix".neededForBoot;
        message = "fileSystems.\"/nix\" must set neededForBoot = true";
      }
    ];
    runix.build = {
      earlyFileSystems = builtins.filter (fileSystem: fileSystem.neededForBoot) sortedFileSystems;
      inherit fstab;
    };
  };
}
