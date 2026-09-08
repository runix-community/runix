{ config, lib, ... }:
let
  cfg = config.hardware.uinput;
in
{
  options.hardware.uinput = {
    enable = lib.mkEnableOption "userspace virtual input devices";
    group = lib.mkOption {
      type = lib.types.str;
      default = "uinput";
      description = "Group granted access to /dev/uinput.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.group config.runix.build.normalizedGroups;
        message = "hardware.uinput.group references an unknown group";
      }
    ];
    runix.groups = lib.mkIf (cfg.group == "uinput") { uinput.gid = lib.mkDefault 304; };
    runix.kernel.modules = [ "uinput" ];
    services.mdevd.rules = ''
      uinput 0:${toString config.runix.build.normalizedGroups.${cfg.group}.gid} 660
    '';
  };
}
