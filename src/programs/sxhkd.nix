{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.sxhkd;
in
{
  options.programs.sxhkd = {
    enable = lib.mkEnableOption "the sxhkd X hotkey daemon";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../pkgs/window-managers/sxhkd.nix { };
      description = "sxhkd package.";
    };
  };

  config.runix.packages = lib.optional cfg.enable cfg.package;
}
