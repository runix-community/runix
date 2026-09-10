{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.systemServices.dhcpcd;
in
{
  options.runix.systemServices.dhcpcd.enable = lib.mkEnableOption "dhcpcd network configuration";

  config = lib.mkIf cfg.enable {
    runix.packages = [ pkgs.dhcpcd ];
    runix.preparationScripts = [
      ''
        mkdir -p /run/dhcpcd /var/lib/dhcpcd
        rm -f /etc/resolv.conf
        touch /etc/resolv.conf
      ''
    ];
    runix.services.dhcpcd.command = "${pkgs.dhcpcd}/bin/dhcpcd --nobackground";
  };
}
