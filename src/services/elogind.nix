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
  pamLogin = pkgs.writeText "runix-pam-login" ''
    auth required ${pkgs.linux-pam}/lib/security/pam_unix.so
    account required ${pkgs.linux-pam}/lib/security/pam_unix.so
    password required ${pkgs.linux-pam}/lib/security/pam_unix.so
    session required ${pkgs.linux-pam}/lib/security/pam_unix.so
    session optional ${pkgs.elogind}/lib/security/pam_elogind.so
  '';
  dbusPolicy = pkgs.runCommand "runix-elogind-dbus-policy" { } ''
    mkdir -p $out/share/dbus-1/system.d
    cp ${pkgs.elogind}/share/dbus-1/system.d/* $out/share/dbus-1/system.d/
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
    runix.systemServices.dbusPackages = [ dbusPolicy ];
    runix.preparationScripts = [
      ''
        mkdir -p /etc/elogind /etc/pam.d /run/elogind /run/user /var/lib/elogind
        ln -sfn ${logindConfig} /etc/elogind/logind.conf
        ln -sfn ${pamLogin} /etc/pam.d/login
      ''
    ];
    runix.services.elogind = {
      command = "${pkgs.elogind}/libexec/elogind";
      environment = {
        DBUS_SYSTEM_BUS_ADDRESS = "unix:path=/run/dbus/system_bus_socket";
        SYSTEMD_LOG_TARGET = "null";
      };
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
