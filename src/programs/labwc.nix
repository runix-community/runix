{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.labwc;
  defaultPackage = (import ../../pkgs/desktop.nix { inherit pkgs; }).labwc;
in
{
  options.programs.labwc = {
    enable = lib.mkEnableOption "the Labwc Wayland compositor";
    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
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
