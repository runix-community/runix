{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.i2c;
in
{
  options.hardware.i2c = {
    enable = lib.mkEnableOption "I2C userspace device access";
    group = lib.mkOption {
      type = lib.types.str;
      default = "i2c";
      description = "Group granted access to /dev/i2c-* devices.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.group config.runix.build.normalizedGroups;
        message = "hardware.i2c.group references an unknown group";
      }
    ];
    runix.groups = lib.mkIf (cfg.group == "i2c") { i2c.gid = lib.mkDefault 302; };
    runix.kernel.modules = [ "i2c-dev" ];
    runix.packages = [ pkgs.i2c-tools ];
    services.mdevd.rules = ''
      i2c-[0-9]+ 0:${toString config.runix.build.normalizedGroups.${cfg.group}.gid} 660
    '';
  };
}
