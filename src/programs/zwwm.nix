{ config, lib, pkgs, ... }:
let
  cfg = config.programs.zwwm;
in
{
  options.programs.zwwm = {
    enable = lib.mkEnableOption "the zwwm Wayland compositor";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.zwwm;
      description = "zwwm package used by graphical sessions.";
    };
  };

  config = lib.mkIf cfg.enable {
    runix.wayland.enable = true;
    runix.packages = [ cfg.package ];
  };
}
