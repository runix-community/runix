final: prev:
let
  pipewireNoSystemd =
    (prev.pipewire.override {
      enableSystemd = false;
      udev = final.udev;
      elogind = final.elogind;
    }).overrideAttrs
      (old: {
        # mdevd/libudev-zero has no udev-specific SOUND_INITIALIZED property.
        patches = (old.patches or [ ]) ++ [ ./pipewire-mdevd.patch ];
      });
  wireplumberNoSystemd =
    (prev.wireplumber.override {
      pipewire = pipewireNoSystemd;
    }).overrideAttrs
      (old: {
        # Keep logind support through libelogind, not libsystemd.
        buildInputs = prev.lib.filter (input: input != prev.systemdLibs) old.buildInputs ++ [
          final.elogind
        ];
        mesonFlags =
          prev.lib.filter (
            flag: flag != "-Dsystemd-system-service=true" && flag != "-Delogind=disabled"
          ) old.mesonFlags
          ++ [
            "-Dsystemd=disabled"
            "-Delogind=enabled"
            "-Dsystemd-system-service=false"
            "-Dsystemd-user-service=false"
          ];
      });
  flatpakNoSystemd = prev.flatpak.override { withSystemd = false; };
in
{
  libinput = prev.libinput.override { udev = final.udev; };

  pipewire = pipewireNoSystemd;
  wireplumber = wireplumberNoSystemd;
  polkit = prev.polkit.override {
    useSystemd = false;
    elogind = final.elogind;
  };

  seatd = prev.seatd.override { systemdSupport = false; };

  flatpak = flatpakNoSystemd;
  xdg-desktop-portal = prev.xdg-desktop-portal.override {
    enableSystemd = false;
    flatpak = flatpakNoSystemd;
    pipewire = pipewireNoSystemd;
  };
  xdg-desktop-portal-gtk = prev.xdg-desktop-portal-gtk.override {
    xdg-desktop-portal = final.xdg-desktop-portal;
  };

  hyprland = prev.hyprland.override {
    libinput = final.libinput;
    withSystemd = false;
  };

  niri = prev.niri.override {
    eudev = final.udev;
    libinput = final.libinput;
    pipewire = pipewireNoSystemd;
    withSystemd = false;
  };

  labwc = prev.labwc.override {
    enableSystemd = false;
    libinput = final.libinput;
  };

  weston = prev.weston.override {
    libinput = final.libinput;
    seatd = final.seatd;
  };
}
