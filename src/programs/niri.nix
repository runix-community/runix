{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.niri;
  defaultPackage = (import ../../pkgs/desktop.nix { inherit pkgs; }).niri;
in
{
  options.programs.niri = {
    enable = lib.mkEnableOption "the Niri scrollable-tiling Wayland compositor";
    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "Niri package.";
    };
  };

  config.runix.packages = lib.optional cfg.enable cfg.package;
}
