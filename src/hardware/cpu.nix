{
  config,
  lib,
  pkgs,
  ...
}:
let
  amd = config.hardware.cpu.amd;
  intel = config.hardware.cpu.intel;
in
{
  options.hardware.cpu = {
    amd = {
      updateMicrocode = lib.mkEnableOption "AMD CPU microcode updates";
      microcodePackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.microcode-amd;
        description = "Package providing amd-ucode.img.";
      };
    };
    intel = {
      updateMicrocode = lib.mkEnableOption "Intel CPU microcode updates";
      microcodePackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.microcode-intel;
        description = "Package providing intel-ucode.img.";
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = !(amd.updateMicrocode && intel.updateMicrocode);
        message = "Only one of hardware.cpu.amd.updateMicrocode and hardware.cpu.intel.updateMicrocode may be enabled";
      }
    ];
    runix.initrd.prepend =
      lib.optional amd.updateMicrocode "${amd.microcodePackage}/amd-ucode.img"
      ++ lib.optional intel.updateMicrocode "${intel.microcodePackage}/intel-ucode.img";
  };
}
