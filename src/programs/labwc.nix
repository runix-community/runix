{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.labwc;
in
{
  options.programs.labwc = {
    enable = lib.mkEnableOption "the Labwc Wayland compositor";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../pkgs/window-managers/labwc.nix { };
      description = "Labwc package.";
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Arguments passed to Labwc by its graphical session.";
    };
  };

  config.runix.packages = lib.optional cfg.enable cfg.package;
}
