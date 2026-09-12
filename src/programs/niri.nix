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

  config = lib.mkIf cfg.enable {
    runix.wayland.enable = true;
    runix.packages = [ cfg.package ];
  };
}
