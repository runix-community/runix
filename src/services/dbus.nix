{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.systemServices;
  dbusConfig = pkgs.makeDBusConf.override {
    dbus = pkgs.dbus;
    suidHelper = "/run/wrappers/bin/dbus-daemon-launch-helper";
    serviceDirectories = [ pkgs.dbus ] ++ cfg.dbusPackages;
  };
  sessionConfig = pkgs.runCommand "runix-dbus-session.conf" { } ''
    ${pkgs.gnused}/bin/sed '\|<include ignore_missing="yes">/etc/dbus-1/session.conf</include>|d' \
      ${pkgs.dbus}/share/dbus-1/session.conf > "$out"
  '';
in
{
  options.runix.systemServices = {
    dbus.enable = lib.mkEnableOption "the system D-Bus daemon";
    dbusPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      internal = true;
      description = "Packages contributing D-Bus policy and activation files.";
    };
  };

  config = lib.mkIf cfg.dbus.enable {
    runix.groups.messagebus.gid = 18;
    runix.users.messagebus = {
      uid = 18;
      gid = 18;
      home = "/run/dbus";
      shell = "/bin/false";
    };
    runix.packages = [ pkgs.dbus ] ++ cfg.dbusPackages;
    runix.preparationScripts = [
      ''
        if [ -L /run/dbus ]; then
          rm -f /run/dbus
        fi
        mkdir -p /etc/dbus-1/system.d /run/dbus /run/wrappers/bin /usr/share/dbus-1/system-services /var/lib/dbus
        if [ ! -s /var/lib/dbus/machine-id ]; then
          ${pkgs.dbus}/bin/dbus-uuidgen > /var/lib/dbus/machine-id
        fi
        ln -sfn /var/lib/dbus/machine-id /etc/machine-id
        ln -sfn ${dbusConfig}/system.conf /etc/dbus-1/system.conf
        ln -sfn ${sessionConfig} /etc/dbus-1/session.conf
        ${pkgs.coreutils}/bin/install -m4750 -o root -g messagebus \
          ${pkgs.dbus}/libexec/dbus-daemon-launch-helper \
          /run/wrappers/bin/dbus-daemon-launch-helper
        for package in ${lib.escapeShellArgs cfg.dbusPackages}; do
          for policy in "$package"/share/dbus-1/system.d/*; do
            [ -e "$policy" ] || continue
            ln -sfn "$policy" "/etc/dbus-1/system.d/''${policy##*/}"
          done
          for service in "$package"/share/dbus-1/system-services/*; do
            [ -e "$service" ] || continue
            ln -sfn "$service" "/usr/share/dbus-1/system-services/''${service##*/}"
          done
        done
      ''
    ];
    runix.services.dbus = {
      command = "${pkgs.dbus}/bin/dbus-daemon --config-file=${dbusConfig}/system.conf --nofork --nopidfile";
      check = ''
        ${pkgs.dbus}/bin/dbus-send --system --type=method_call --print-reply \
          --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames >/dev/null
      '';
    };
  };
}
