{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.systemServices.yggdrasil;
  configFile = pkgs.writeText "runix-yggdrasil.conf" cfg.config;
in
{
  options.runix.systemServices.yggdrasil = {
    enable = lib.mkEnableOption "Yggdrasil networking";
    config = lib.mkOption {
      type = lib.types.lines;
      default = "{}";
      description = "Yggdrasil configuration in HJSON format.";
    };
  };
  config = lib.mkIf cfg.enable {
    runix.packages = [ pkgs.yggdrasil ];
    runix.preparationScripts = [ "ln -sfn ${configFile} /etc/yggdrasil.conf" ];
    runix.services.yggdrasil.command = "${pkgs.yggdrasil}/bin/yggdrasil -useconffile /etc/yggdrasil.conf";
  };
}
