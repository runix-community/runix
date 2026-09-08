{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.niri;
in
{
  options.programs.niri = {
    enable = lib.mkEnableOption "the Niri scrollable-tiling Wayland compositor";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../pkgs/window-managers/niri.nix { };
      description = "Niri package.";
    };
  };

  config.runix.packages = lib.optional cfg.enable cfg.package;
}
