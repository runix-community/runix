{ config, lib, ... }:
let
  cfg = config.hardware.intelGraphics;
in
{
  options.hardware.intelGraphics = {
    enable = lib.mkEnableOption "Intel GPU kernel and userspace support";
    earlyModesetting = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether i915 is loaded in the initrd.";
    };
    kernelParameters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional Intel GPU kernel command-line parameters.";
    };
  };

  config = lib.mkIf cfg.enable {
    hardware = {
      enableRedistributableFirmware = lib.mkDefault true;
      graphics = {
        enable = lib.mkDefault true;
        kernelModules = [ "i915" ];
        initrd.enable = lib.mkDefault cfg.earlyModesetting;
      };
    };
    runix.kernel.parameters = cfg.kernelParameters;
  };
}
