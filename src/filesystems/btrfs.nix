{
  config,
  lib,
  ...
}:
let
  cfg = config.runix;
  enabled = builtins.any (fileSystem: fileSystem.fsType == "btrfs") cfg.build.earlyFileSystems;
in
{
  config.runix.initrd = lib.mkIf enabled {
    loadModules = [ "btrfs" ];
    modules = [
      "crc32c"
    ]
    ++ lib.optionals (lib.versionAtLeast cfg.kernel.package.version "5.5") [
      # These canonical module names vary; use the algorithm names requested by Btrfs.
      "xxhash64"
      "sha256"
      "blake2b-256"
    ];
  };
}
