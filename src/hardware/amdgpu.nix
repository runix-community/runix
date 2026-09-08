{ config, lib, ... }:
let
  cfg = config.hardware.amdgpu;
in
{
  options.hardware.amdgpu = {
    enable = lib.mkEnableOption "AMD GPU kernel and userspace support";
    earlyModesetting = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether amdgpu is loaded in the initrd.";
    };
    kernelParameters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional AMD GPU kernel command-line parameters.";
    };
  };

  config = lib.mkIf cfg.enable {
    hardware = {
      enableRedistributableFirmware = lib.mkDefault true;
      graphics = {
        enable = lib.mkDefault true;
        kernelModules = [ "amdgpu" ];
        initrd.enable = lib.mkDefault cfg.earlyModesetting;
      };
    };
    runix.kernel.parameters = cfg.kernelParameters;
  };
}
