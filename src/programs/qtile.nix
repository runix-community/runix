{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.qtile;
in
{
  options.programs.qtile = {
    enable = lib.mkEnableOption "the Qtile X11 window manager";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../pkgs/window-managers/qtile.nix { };
      description = "Qtile package.";
    };
  };

  config.runix.packages = lib.optional cfg.enable cfg.package;
}
