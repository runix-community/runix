{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.bluetooth;
  configFile = pkgs.writeText "runix-bluetooth-main.conf" ''
    [General]
    Experimental=${if cfg.experimental then "true" else "false"}
    ${cfg.extraConfig}
  '';
in
{
  options.hardware.bluetooth = {
    enable = lib.mkEnableOption "Bluetooth hardware and bluetoothd";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.bluez;
      description = "BlueZ package.";
    };
    experimental = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether BlueZ experimental interfaces are enabled.";
    };
    kernelModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "bluetooth"
        "btusb"
      ];
      description = "Bluetooth kernel modules loaded after mounting root.";
    };
    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Additional entries for bluetooth/main.conf.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.runix.systemServices.dbus.enable;
        message = "hardware.bluetooth requires runix.systemServices.dbus";
      }
      {
        assertion = config.services.mdevd.enable;
        message = "hardware.bluetooth requires services.mdevd";
      }
    ];
    runix.kernel.modules = cfg.kernelModules;
    runix.packages = [
      cfg.package
      pkgs.util-linux
    ];
    runix.systemServices.dbusPackages = [ cfg.package ];
    runix.preparationScripts = [
      ''
        mkdir -p /etc/bluetooth /var/lib/bluetooth
        ln -sfn ${configFile} /etc/bluetooth/main.conf
      ''
    ];
    runix.services.bluetoothd = {
      command = "${cfg.package}/libexec/bluetooth/bluetoothd --nodetach --configfile /etc/bluetooth/main.conf";
      after = [
        "dbus"
        "mdevd-coldplug"
      ];
    };
  };
}
