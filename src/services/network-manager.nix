{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.systemServices.networkManager;
  networkManagerConfig = pkgs.writeText "runix-NetworkManager.conf" ''
    [main]
    plugins=keyfile
    rc-manager=symlink

    [device]
    wifi.scan-rand-mac-address=yes
  '';
in
{
  options.runix.systemServices.networkManager.enable = lib.mkEnableOption "NetworkManager";
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.runix.systemServices.dbus.enable;
        message = "runix.systemServices.networkManager requires runix.systemServices.dbus";
      }
      {
        assertion = !config.runix.systemServices.dhcpcd.enable;
        message = "NetworkManager and dhcpcd cannot manage interfaces at the same time";
      }
    ];
    runix.groups.networkmanager.gid = 57;
    runix.kernel.modules = [ "ctr" ];
    runix.systemServices.dbusPackages = [
      pkgs.networkmanager
      pkgs.wpa_supplicant
    ];
    runix.packages = [
      pkgs.networkmanager
      pkgs.wpa_supplicant
    ];
    runix.preparationScripts = [
      ''
        mkdir -p /etc/NetworkManager /run/NetworkManager /var/lib/NetworkManager
        ln -sfn ${networkManagerConfig} /etc/NetworkManager/NetworkManager.conf
        ln -sfn /run/NetworkManager/resolv.conf /etc/resolv.conf
      ''
    ];
    runix.services.networkmanager = {
      command = "${pkgs.networkmanager}/bin/NetworkManager --no-daemon";
      after = [
        "dbus"
        "mdevd-coldplug"
      ];
      check = "${pkgs.networkmanager}/bin/nmcli general status >/dev/null";
    };
  };
}
