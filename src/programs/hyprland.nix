{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.hyprland;
  defaultPackage = pkgs.callPackage ../../pkgs/window-managers/hyprland.nix { };
in
{
  options.programs.hyprland = {
    enable = lib.mkEnableOption "the Hyprland Wayland compositor";
    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "Hyprland package used by graphical sessions.";
    };
    xwayland = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether Xwayland is available to Hyprland sessions.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.xwayland;
        description = "Xwayland package.";
      };
    };
  };

  config.runix.packages =
    lib.optional cfg.enable cfg.package
    ++ lib.optional (cfg.enable && cfg.xwayland.enable) cfg.xwayland.package;
}
