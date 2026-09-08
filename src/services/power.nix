{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.runix.systemServices = {
    powerProfiles.enable = lib.mkEnableOption "power-profiles-daemon";
    upower.enable = lib.mkEnableOption "UPower";
  };

  config = lib.mkMerge [
    (lib.mkIf config.runix.systemServices.powerProfiles.enable {
      assertions = [
        {
          assertion = config.runix.systemServices.dbus.enable;
          message = "runix.systemServices.powerProfiles requires runix.systemServices.dbus";
        }
      ];
      runix.systemServices.dbusPackages = [ pkgs.power-profiles-daemon ];
      runix.packages = [ pkgs.power-profiles-daemon ];
      runix.services.power-profiles-daemon = {
        command = "${pkgs.power-profiles-daemon}/libexec/power-profiles-daemon";
        after = [ "dbus" ];
      };
    })

    (lib.mkIf config.runix.systemServices.upower.enable {
      assertions = [
        {
          assertion = config.runix.systemServices.dbus.enable;
          message = "runix.systemServices.upower requires runix.systemServices.dbus";
        }
      ];
      runix.groups.upower.gid = 87;
      runix.users.upower = {
        uid = 87;
        gid = 87;
        home = "/var/lib/upower";
        shell = "/bin/false";
      };
      runix.systemServices.dbusPackages = [ pkgs.upower ];
      runix.packages = [ pkgs.upower ];
      runix.preparationScripts = [ "mkdir -p /var/lib/upower" ];
      runix.services.upower = {
        command = "${pkgs.upower}/libexec/upowerd";
        after = [ "dbus" ];
      };
    })
  ];
}
