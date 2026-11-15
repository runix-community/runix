{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.systemServices.elogind;
  logindConfig = pkgs.writeText "runix-logind.conf" (
    "[Login]\n" + lib.concatStrings (lib.mapAttrsToList (name: value: "${name}=${toString value}\n") cfg.settings)
  );
  hooksDirectory = "/etc/elogind/system-sleep";
  # elogind reads sleep hooks only from directories inside its own store path.
  # When there are hooks, a build whose hook directory points at /etc instead.
  package =
    if cfg.sleepHooks == { } then
      pkgs.elogind
    else
      pkgs.elogind.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          rm -rf "$out/libexec/system-sleep"
          ln -s ${hooksDirectory} "$out/libexec/system-sleep"
        '';
      });
  hooks = pkgs.linkFarm "runix-elogind-sleep-hooks" (
    lib.mapAttrsToList (name: script: {
      inherit name;
      path = pkgs.writeShellScript "runix-sleep-${name}" script;
    }) cfg.sleepHooks
  );
  pamLogin = pkgs.writeText "runix-pam-login" ''
    auth required ${pkgs.linux-pam}/lib/security/pam_unix.so
    account required ${pkgs.linux-pam}/lib/security/pam_unix.so
    password required ${pkgs.linux-pam}/lib/security/pam_unix.so
    session required ${pkgs.linux-pam}/lib/security/pam_env.so conffile=/etc/security/pam_env.conf readenv=0
    session required ${pkgs.linux-pam}/lib/security/pam_unix.so
    session optional ${package}/lib/security/pam_elogind.so
  '';
  dbusPolicy = pkgs.runCommand "runix-elogind-dbus-policy" { } ''
    mkdir -p $out/share/dbus-1/system.d
    cp ${package}/share/dbus-1/system.d/* $out/share/dbus-1/system.d/
  '';
in
{
  options.runix.systemServices.elogind = {
    enable = lib.mkEnableOption "elogind session management";
    settings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [ lib.types.str lib.types.int lib.types.bool ]);
      default = { };
      example = {
        HandleLidSwitch = "suspend";
        HandleLidSwitchExternalPower = "ignore";
        HandlePowerKey = "poweroff";
        IdleAction = "suspend";
        IdleActionSec = "30min";
      };
      description = "The [Login] section of logind.conf: what the lid, power key and idle do. See `man logind.conf`.";
    };
    sleepHooks = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      example = {
        wifi = ''
          case "$1" in
            pre) rfkill block wifi ;;
            post) rfkill unblock wifi ;;
          esac
        '';
      };
      description = ''
        Scripts elogind runs around suspend and hibernation, with "pre" or
        "post" as $1 and the kind of sleep (suspend, hibernate, hybrid-sleep,
        suspend-then-hibernate) as $2.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
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
    runix.packages = [ package ];
    runix.systemServices.dbusPackages = [ dbusPolicy ];
    runix.preparationScripts = [
      ''
        mkdir -p /etc/elogind /etc/pam.d /run/elogind /run/user /var/lib/elogind
        ln -sfn ${logindConfig} /etc/elogind/logind.conf
        ln -sfn ${pamLogin} /etc/pam.d/login
        ${if cfg.sleepHooks == { } then "if [ -L ${hooksDirectory} ]; then rm -f ${hooksDirectory}; fi" else "ln -sfn ${hooks} ${hooksDirectory}"}
      ''
    ];
    runix.services.elogind = {
      command = "${package}/libexec/elogind";
      environment = {
        DBUS_SYSTEM_BUS_ADDRESS = "unix:path=/run/dbus/system_bus_socket";
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
