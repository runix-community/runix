{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.bspwm;
in
{
  options.programs.bspwm = {
    enable = lib.mkEnableOption "the bspwm X11 window manager";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../pkgs/window-managers/bspwm.nix { };
      description = "bspwm package.";
    };
  };

  config.runix.packages = lib.optional cfg.enable cfg.package;
}
