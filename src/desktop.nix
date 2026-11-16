{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.desktop;
  programs = config.programs;
  pam = pkgs.linux-pam;
  desktopPackages = import ../pkgs/desktop.nix { inherit pkgs; };
  hiddenUsers = lib.filter (lib.hasPrefix "nixbld") (builtins.attrNames config.runix.users);

  sessionCommand = pkgs.writeShellScript "runix-hyprland-session" ''
    export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/run/current-system/sw/sbin
    export XDG_CURRENT_DESKTOP=Hyprland
    export XDG_SESSION_DESKTOP=Hyprland
    export XDG_SESSION_TYPE=wayland
    export XDG_DATA_DIRS=/run/current-system/sw/share
    export NIXOS_OZONE_WL=1
    exec ${programs.hyprland.package}/bin/start-hyprland
  '';

  # Runs every graphical session: one session bus for it, and the user's
  # audio (PipeWire, WirePlumber, the Pulse server) for as long as it lasts.
  sessionWrapper = pkgs.writeShellScript "runix-session" ''
    if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
      exec ${pkgs.dbus}/bin/dbus-run-session -- "$0" "$@"
    fi
    ${lib.optionalString config.services.pipewire.enable ''
      ${config.runix.build.pipewireSession} &
      audio=$!
      trap 'kill -TERM "$audio" 2>/dev/null || true; wait "$audio" 2>/dev/null || true' EXIT INT TERM
    ''}
    "$@"
  '';

  sessionPackage = pkgs.runCommand "runix-hyprland-session-data" { } ''
    mkdir -p "$out/share/wayland-sessions"
    cat > "$out/share/wayland-sessions/runix-hyprland.desktop" <<EOF
    [Desktop Entry]
    Name=Hyprland
    Comment=Hyprland Wayland compositor
    Exec=${sessionCommand}
    Type=Application
    DesktopNames=Hyprland
    EOF
  '';

  waylandSessions = pkgs.buildEnv {
    name = "runix-wayland-sessions";
    paths = lib.optional programs.hyprland.enable sessionPackage
      ++ lib.concatMap (name: lib.optional programs.${name}.enable programs.${name}.package) [
        "labwc"
        "niri"
        "zwwm"
        "shojiwm"
        "driftwm"
      ]
      ++ config.runix.wayland.sessionPackages;
    pathsToLink = [ "/share/wayland-sessions" ];
  };

  # The sessions every login screen offers, each started through the wrapper.
  # Linked at /run/current-system/sessions.
  wrappedSessions = pkgs.runCommand "runix-sessions" { } ''
    mkdir -p "$out/share/wayland-sessions"
    for file in ${waylandSessions}/share/wayland-sessions/*.desktop; do
      [ -e "$file" ] || continue
      ${pkgs.gnused}/bin/sed "s|^Exec=|Exec=${sessionWrapper} |" "$file" \
        > "$out/share/wayland-sessions/''${file##*/}"
    done
  '';

  sddmConfig = pkgs.writeText "runix-sddm.conf" ''
    [General]
    DisplayServer=wayland
    GreeterEnvironment=XDG_RUNTIME_DIR=/run/sddm,XCURSOR_PATH=/run/current-system/sw/share/icons,XCURSOR_SIZE=24,XCURSOR_THEME=Adwaita
    HaltCommand=/run/current-system/bin/poweroff
    RebootCommand=/run/current-system/bin/reboot

    [Theme]
    Current=${cfg.sddm.theme}
    ThemeDir=/run/current-system/sw/share/sddm/themes

    [Users]
    MaximumUid=60000
    HideUsers=${lib.concatStringsSep "," hiddenUsers}
    HideShells=/bin/false

    [Wayland]
    SessionDir=${wrappedSessions}/share/wayland-sessions
    CompositorCommand=${pkgs.coreutils}/bin/env XDG_RUNTIME_DIR=/run/sddm ${desktopPackages.weston}/bin/weston --shell=kiosk
  '';

  pamLogin = pkgs.writeText "runix-pam-login" ''
    auth required ${pam}/lib/security/pam_unix.so
    account required ${pam}/lib/security/pam_unix.so
    password required ${pam}/lib/security/pam_unix.so
    session required ${pam}/lib/security/pam_env.so conffile=/etc/security/pam_env.conf readenv=0
    session required ${pam}/lib/security/pam_unix.so
    session optional ${pkgs.elogind}/lib/security/pam_elogind.so
  '';

  pamGreeter = pkgs.writeText "runix-pam-sddm-greeter" ''
    auth required ${pam}/lib/security/pam_permit.so
    account required ${pam}/lib/security/pam_permit.so
    password required ${pam}/lib/security/pam_deny.so
    session required ${pam}/lib/security/pam_permit.so
  '';

  portalPackages = lib.optional programs.hyprland.enable cfg.portals.hyprlandPackage ++ [
    cfg.portals.gtkPackage
    pkgs.xdg-desktop-portal
  ];
in
{
  options.runix.desktop = {
    enable = lib.mkEnableOption "the Runix Wayland desktop stack";

    sddm = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether SDDM is the login screen. Turn it off for another one, such as blxshell's greeter; then SDDM is not built at all.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = desktopPackages.sddm;
        description = "SDDM package.";
      };
      theme = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "SDDM theme name.";
      };
    };

    portals = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to install desktop portals for enabled Wayland sessions.";
      };
      hyprlandPackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.xdg-desktop-portal-hyprland;
        description = "Hyprland portal package.";
      };
      gtkPackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.xdg-desktop-portal-gtk;
        description = "GTK portal package.";
      };
    };

  };

  config = lib.mkIf cfg.enable {
    runix.build.sessions = wrappedSessions;
    # The document portal (file pickers in Flatpak and portal apps) mounts a
    # FUSE file system; nothing autoloads fuse.
    runix.kernel.modules = [ "fuse" ];
    assertions = [
      {
        assertion = config.runix.systemServices.dbus.enable;
        message = "runix.desktop requires runix.systemServices.dbus";
      }
      {
        assertion = config.services.mdevd.enable;
        message = "runix.desktop requires services.mdevd";
      }
      {
        assertion = config.runix.systemServices.polkit.enable;
        message = "runix.desktop requires runix.systemServices.polkit";
      }
      {
        assertion = config.runix.systemServices.elogind.enable;
        message = "runix.desktop requires runix.systemServices.elogind";
      }
      {
        assertion =
          config.runix.wayland.sessionPackages != [ ]
          || lib.any (name: programs.${name}.enable) [
            "hyprland"
            "labwc"
            "niri"
            "zwwm"
            "shojiwm"
            "driftwm"
          ];
        message = "runix.desktop requires at least one enabled Wayland compositor";
      }
    ];

    runix.groups = lib.mkIf cfg.sddm.enable {
      sddm.gid = 175;
    };
    programs.hyprland.enable = lib.mkDefault true;
    services = {
      mdevd.enable = lib.mkDefault true;
      pipewire = {
        enable = lib.mkDefault true;
        pulse.enable = lib.mkDefault true;
        wireplumber.enable = lib.mkDefault true;
      };
    };
    runix.systemServices = {
      dbus.enable = lib.mkDefault true;
      elogind.enable = lib.mkDefault true;
      polkit.enable = lib.mkDefault true;
      seatd.enable = lib.mkDefault true;
      # Battery state, and power saver / balanced / performance profiles,
      # which desktop shells such as blxshell show and switch.
      upower.enable = lib.mkDefault true;
      powerProfiles.enable = lib.mkDefault true;
    };
    runix.users = lib.mkIf cfg.sddm.enable {
      sddm = {
        uid = 175;
        gid = 175;
        home = "/var/lib/sddm";
        shell = "/bin/false";
        extraGroups = [
          "video"
          "input"
          "render"
        ];
      };
    };

    hardware.graphics.enable = lib.mkDefault true;
    hardware.input.enable = lib.mkDefault true;
    runix.packages = [
      pkgs.adwaita-icon-theme
      pkgs.dbus
      pkgs.xkeyboard_config
    ]
    # Weston only runs SDDM's greeter.
    ++ lib.optionals cfg.sddm.enable [
      cfg.sddm.package
      desktopPackages.weston
    ]
    ++ lib.optional programs.hyprland.enable sessionPackage
    ++ lib.optionals cfg.portals.enable portalPackages;

    runix.environmentVariables = {
      NIXOS_OZONE_WL = "1";
      XKB_CONFIG_ROOT = "${pkgs.xkeyboard_config}/share/X11/xkb";
      XDG_DATA_DIRS = "/run/current-system/sw/share";
    };
    runix.systemServices.dbusPackages = lib.optional cfg.sddm.enable cfg.sddm.package
    ++ lib.optional programs.flatpak.enable programs.flatpak.package;
    runix.preparationScripts = [
      ''
        mkdir -p /etc/pam.d /var/lib/flatpak
        ln -sfn ${pamLogin} /etc/pam.d/login
        ${lib.optionalString cfg.sddm.enable ''
          mkdir -p /etc/sddm.conf.d /var/lib/sddm
          ${pkgs.coreutils}/bin/install -d -m 0700 -o sddm -g sddm /run/sddm
          ln -sfn ${pamLogin} /etc/pam.d/sddm
          ln -sfn ${pamGreeter} /etc/pam.d/sddm-greeter
          ln -sfn ${sddmConfig} /etc/sddm.conf.d/00-runix.conf
        ''}
      ''
    ];

    runix.activationScripts = [
      ''
        if ! ${pkgs.util-linux}/bin/mountpoint -q /sys/fs/cgroup; then
          mkdir -p /sys/fs/cgroup
          ${pkgs.util-linux}/bin/mount -t cgroup2 cgroup2 /sys/fs/cgroup
        fi
      ''
    ];

    runix.services = lib.mkIf cfg.sddm.enable {
      sddm = {
        command = "${cfg.sddm.package}/bin/sddm --config /etc/sddm.conf.d/00-runix.conf";
        environment.XDG_RUNTIME_DIR = "/run/sddm";
        after = [
          "dbus"
          "elogind"
          "polkit"
          "seatd"
          "mdevd-coldplug"
        ];
      };
    };
  };
}
