{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.hardware = {
    enableRedistributableFirmware = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to include the standard redistributable Linux firmware collection.";
    };
    firmware = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Additional firmware packages included in the initrd and exposed to the device manager.";
    };
  };

  config.runix.kernel.firmwarePackages =
    lib.optional config.hardware.enableRedistributableFirmware pkgs.linux-firmware
    ++ config.hardware.firmware;
}
