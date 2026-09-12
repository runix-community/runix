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

  sessionCommand = pkgs.writeShellScript "runix-hyprland-session" ''
    export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/run/current-system/sw/sbin
    export XDG_CURRENT_DESKTOP=Hyprland
    export XDG_SESSION_DESKTOP=Hyprland
    export XDG_SESSION_TYPE=wayland
    export XDG_DATA_DIRS=/run/current-system/sw/share
    export NIXOS_OZONE_WL=1
    ${pkgs.dbus}/bin/dbus-run-session -- ${pkgs.runtimeShell} -c ${lib.escapeShellArg ''
      ${lib.optionalString config.services.pipewire.enable ''
        ${config.runix.build.pipewireSession} &
        audio_supervisor=$!
        trap 'kill -TERM "$audio_supervisor" 2>/dev/null || true; wait "$audio_supervisor" 2>/dev/null || true' EXIT INT TERM
      ''}
      ${programs.hyprland.package}/bin/Hyprland
    ''}
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

  sddmConfig = pkgs.writeText "runix-sddm.conf" ''
    [General]
    DisplayServer=wayland
    HaltCommand=/run/current-system/bin/poweroff
    RebootCommand=/run/current-system/bin/reboot

    [Theme]
    Current=${cfg.sddm.theme}
    ThemeDir=/run/current-system/sw/share/sddm/themes

    [Users]
    MaximumUid=60000
    HideShells=/bin/false

    [Wayland]
    SessionDir=${sessionPackage}/share/wayland-sessions
    CompositorCommand=${pkgs.weston}/bin/weston --shell=kiosk
  '';

  pamLogin = pkgs.writeText "runix-pam-login" ''
    auth required ${pam}/lib/security/pam_unix.so
    account required ${pam}/lib/security/pam_unix.so
    password required ${pam}/lib/security/pam_unix.so
    session required ${pam}/lib/security/pam_unix.so
    session required ${pkgs.elogind}/lib/security/pam_elogind.so
  '';

  pamGreeter = pkgs.writeText "runix-pam-sddm-greeter" ''
    auth required ${pam}/lib/security/pam_permit.so
    account required ${pam}/lib/security/pam_permit.so
    password required ${pam}/lib/security/pam_deny.so
    session required ${pam}/lib/security/pam_permit.so
  '';

  portalPackages = [
    cfg.portals.hyprlandPackage
    cfg.portals.gtkPackage
    pkgs.xdg-desktop-portal
  ];
in
{
  options.runix.desktop = {
    enable = lib.mkEnableOption "the Runix Hyprland desktop stack";

    sddm = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.kdePackages.sddm;
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
        description = "Whether to install Hyprland and GTK desktop portals.";
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
        assertion = programs.hyprland.enable;
        message = "runix.desktop requires programs.hyprland";
      }
    ];

    runix.groups = {
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
    };
    runix.users = {
      sddm = {
        uid = 175;
        gid = 175;
        home = "/var/lib/sddm";
        shell = "/bin/false";
      };
    };

    hardware.graphics.enable = lib.mkDefault true;
    hardware.input.enable = lib.mkDefault true;
    runix.packages = [
      cfg.sddm.package
      pkgs.dbus
      pkgs.weston
      pkgs.xkeyboard_config
      sessionPackage
    ]
    ++ lib.optionals cfg.portals.enable portalPackages;

    runix.environmentVariables = {
      NIXOS_OZONE_WL = "1";
      XKB_CONFIG_ROOT = "${pkgs.xkeyboard_config}/share/X11/xkb";
      XDG_DATA_DIRS = "/run/current-system/sw/share";
    };
    runix.systemServices.dbusPackages = [
      cfg.sddm.package
    ]
    ++ lib.optional programs.flatpak.enable programs.flatpak.package;
    runix.preparationScripts = [
      ''
        mkdir -p /etc/pam.d /etc/sddm.conf.d /var/lib/flatpak /var/lib/sddm
        ln -sfn ${pamLogin} /etc/pam.d/login
        ln -sfn ${pamLogin} /etc/pam.d/sddm
        ln -sfn ${pamGreeter} /etc/pam.d/sddm-greeter
        ln -sfn ${sddmConfig} /etc/sddm.conf.d/00-runix.conf
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

    runix.services = {
      sddm = {
        command = "${cfg.sddm.package}/bin/sddm --config /etc/sddm.conf.d/00-runix.conf";
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
