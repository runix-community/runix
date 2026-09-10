{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.systemServices.networkManager;
  networkManager = pkgs.networkmanager.override {
    udev = pkgs.libudev-zero;
    withSystemd = false;
  };
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
      networkManager
      pkgs.wpa_supplicant
    ];
    runix.packages = [
      networkManager
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
      command = "${networkManager}/bin/NetworkManager --no-daemon";
      after = [
        "dbus"
        "mdevd-coldplug"
      ];
      check = "${networkManager}/bin/nmcli general status >/dev/null";
    };
  };
}
