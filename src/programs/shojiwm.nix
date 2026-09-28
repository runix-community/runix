{ config, lib, pkgs, ... }:
let
  cfg = config.programs.shojiwm;
in
{
  options.programs.shojiwm = {
    enable = lib.mkEnableOption "the ShojiWM Wayland compositor";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.shojiwm;
      description = "ShojiWM package used by graphical sessions.";
    };
  };

  config = lib.mkIf cfg.enable {
    runix.wayland.enable = true;
    runix.packages = [ cfg.package ];
  };
}
