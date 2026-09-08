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
    ];
    runix.systemServices.dbusPackages = [ pkgs.networkmanager ];
    runix.packages = [ pkgs.networkmanager ];
    runix.preparationScripts = [
      ''
        mkdir -p /etc/NetworkManager /var/lib/NetworkManager
        ln -sfn ${networkManagerConfig} /etc/NetworkManager/NetworkManager.conf
      ''
    ];
    runix.services.networkmanager = {
      command = "${pkgs.networkmanager}/bin/NetworkManager --no-daemon";
      after = [ "dbus" ];
      check = "${pkgs.networkmanager}/bin/nmcli general status >/dev/null";
    };
  };
}
