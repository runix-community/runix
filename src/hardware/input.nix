{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.input;
  desktopPackages = import ../../pkgs/desktop.nix { inherit pkgs; };
in
{
  options.hardware.input = {
    enable = lib.mkEnableOption "libinput and input device access";
    package = lib.mkOption {
      type = lib.types.package;
      default = desktopPackages.libinput;
      description = "Input stack package.";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = "input";
      description = "Group granted access to input event devices.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.group config.runix.build.normalizedGroups;
        message = "hardware.input.group references an unknown group";
      }
    ];
    runix.groups = lib.mkIf (cfg.group == "input") { input.gid = lib.mkDefault 174; };
    runix.packages = [ cfg.package ];
    services.mdevd.rules = ''
      SUBSYSTEM=input;.* 0:${toString config.runix.build.normalizedGroups.${cfg.group}.gid} 660
    '';
  };
}
