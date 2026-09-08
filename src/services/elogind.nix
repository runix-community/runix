{
  config,
  lib,
  pkgs,
  ...
}:
let
  logindConfig = pkgs.writeText "runix-logind.conf" ''
    [Login]
  '';
in
{
  options.runix.systemServices.elogind.enable = lib.mkEnableOption "elogind session management";

  config = lib.mkIf config.runix.systemServices.elogind.enable {
    assertions = [
      {
        assertion = config.runix.systemServices.dbus.enable;
        message = "runix.systemServices.elogind requires runix.systemServices.dbus";
      }
      {
        assertion = config.services.mdevd.enable;
        message = "runix.systemServices.elogind requires services.mdevd";
      }
    ];
    runix.packages = [ pkgs.elogind ];
    runix.systemServices.dbusPackages = [ pkgs.elogind ];
    runix.preparationScripts = [
      ''
        mkdir -p /etc/elogind /run/elogind /run/user /var/lib/elogind
        ln -sfn ${logindConfig} /etc/elogind/logind.conf
      ''
    ];
    runix.services.elogind = {
      command = "${pkgs.elogind}/libexec/elogind";
      after = [
        "dbus"
        "mdevd-coldplug"
      ];
      check = ''
        ${pkgs.dbus}/bin/dbus-send --system --type=method_call --print-reply \
          --dest=org.freedesktop.login1 /org/freedesktop/login1 \
          org.freedesktop.login1.Manager.ListSessions >/dev/null
      '';
    };
  };
}
