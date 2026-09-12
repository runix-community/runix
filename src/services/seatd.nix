{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.systemServices.seatd;
in
{
  options.runix.systemServices.seatd = {
    enable = lib.mkEnableOption "seatd device access broker";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.seatd;
      description = "seatd package.";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = "video";
      description = "Group allowed to access the seatd socket.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.group config.runix.build.normalizedGroups;
        message = "runix.systemServices.seatd.group references an unknown group";
      }
    ];
    runix.packages = [ cfg.package ];
    runix.services.seatd = {
      command = "${cfg.package}/bin/seatd -g ${lib.escapeShellArg cfg.group}";
      after = [ "mdevd-coldplug" ];
      check = "test -S /run/seatd.sock";
    };
  };
}
