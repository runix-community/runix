{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.hyprland;
  defaultPackage = (import ../../pkgs/desktop.nix { inherit pkgs; }).hyprland;
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

  config = lib.mkIf cfg.enable {
    runix.wayland.enable = true;
    runix.packages = [ cfg.package ] ++ lib.optional cfg.xwayland.enable cfg.xwayland.package;
  };
}
