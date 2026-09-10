{
  config,
  lib,
  ...
}:
let
  modules = [
    "vfat"
    "nls_cp437"
    "nls_iso8859-1"
  ];
  enabled = builtins.any (fileSystem: fileSystem.fsType == "vfat") (
    lib.attrValues config.fileSystems
  );
  neededForBoot = builtins.any (fileSystem: fileSystem.fsType == "vfat") (
    config.runix.build.earlyFileSystems
  );
in
{
  config = lib.mkIf enabled {
    runix.kernel.modules = modules;
    runix.initrd = lib.mkIf neededForBoot {
      inherit modules;
      loadModules = modules;
    };
  };
}
