{ config, lib, pkgs, ... }:
let
  cfg = config.programs.driftwm;
in
{
  options.programs.driftwm = {
    enable = lib.mkEnableOption "the driftwm Wayland compositor";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.driftwm;
      description = "driftwm package used by graphical sessions.";
    };
  };

  config = lib.mkIf cfg.enable {
    runix.wayland.enable = true;
    runix.packages = [ cfg.package ];
  };
}
