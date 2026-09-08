{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.flatpak;
in
{
  options.programs.flatpak = {
    enable = lib.mkEnableOption "Flatpak";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.flatpak;
      description = "Flatpak package.";
    };
  };

  config.runix.packages = lib.optional cfg.enable cfg.package;
}
