{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.firefox;
in
{
  options.programs.firefox = {
    enable = lib.mkEnableOption "Firefox, as the web browser";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.firefox;
      defaultText = lib.literalExpression "pkgs.firefox";
      description = "Firefox package.";
    };
  };

  config = lib.mkIf cfg.enable {
    runix.packages = [ cfg.package ];
    # What programs open links with, unless another browser is preferred.
    runix.environmentVariables.BROWSER = lib.mkDefault "firefox";
  };
}
