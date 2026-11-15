# runix.lib.mkProgram: a programs.<name> module for any package, so your own
# programs (or a flake's, as runixModules) work like the built-in ones.
#
#   runix.lib.mkProgram {
#     name = "foot";                    # programs.foot
#     description = "the foot terminal";
#     package = pkgs: pkgs.foot;        # the default package
#   }
#
# With `session = true` the program is a Wayland compositor: enabling it sets
# up Runix's Wayland stack, and its share/wayland-sessions entries are offered
# at the login screen (runix.desktop accepts it as the desktop's compositor).
# `extraConfig` adds settings of your own, given the program's options:
#
#   extraConfig = cfg: { runix.environmentVariables.TERMINAL = "foot"; };
{
  name,
  package,
  description ? name,
  session ? false,
  extraConfig ? (cfg: { }),
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.${name};
in
{
  options.programs.${name} = {
    enable = lib.mkEnableOption description;
    package = lib.mkOption {
      type = lib.types.package;
      default = package pkgs;
      defaultText = lib.literalMD "the package given to runix.lib.mkProgram";
      description = "The ${name} package.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      { runix.packages = [ cfg.package ]; }
      (lib.mkIf session {
        runix.wayland.enable = true;
        runix.wayland.sessionPackages = [ cfg.package ];
      })
      (extraConfig cfg)
    ]
  );
}
