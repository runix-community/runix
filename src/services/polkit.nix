{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.runix.systemServices.polkit.enable = lib.mkEnableOption "PolicyKit authorization";
  config = lib.mkIf config.runix.systemServices.polkit.enable {
    assertions = [
      {
        assertion = config.runix.systemServices.dbus.enable;
        message = "runix.systemServices.polkit requires runix.systemServices.dbus";
      }
      {
        assertion = config.runix.systemServices.elogind.enable;
        message = "runix.systemServices.polkit requires runix.systemServices.elogind";
      }
    ];
    runix.groups.polkitd.gid = 27;
    runix.users.polkitd = {
      uid = 27;
      gid = 27;
      home = "/var/lib/polkit-1";
      shell = "/bin/false";
    };
    runix.systemServices.dbusPackages = [ pkgs.polkit.out ];
    runix.packages = [ pkgs.polkit ];
    runix.preparationScripts = [ "mkdir -p /etc/polkit-1/rules.d /var/lib/polkit-1" ];
    runix.services.polkit = {
      command = "${pkgs.polkit.out}/lib/polkit-1/polkitd --no-debug";
      after = [ "elogind" ];
    };
  };
}
