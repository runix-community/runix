final: prev: {
  dbus = prev.dbus.override {
    enableSystemd = false;
  };

  networkmanager = prev.networkmanager.override {
    withSystemd = false;
    udev = final.udev;
  };

  # BlueZ infers systemd support from its udev provider.
  bluez = prev.bluez.override {
    udev = final.udev;
  };

  upower = prev.upower.override {
    withSystemd = false;
    udev = final.udev;
  };

  docker = prev.docker.override {
    withSystemd = false;
  };

  # An empty unit directory bypasses Meson's systemd dependency lookup.
  power-profiles-daemon = prev.power-profiles-daemon.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./power-profiles-daemon-no-systemd-unit.patch ];
    buildInputs = final.lib.filter (input: input != prev.systemd) old.buildInputs;
    mesonFlags =
      final.lib.filter (flag: !final.lib.hasPrefix "-Dsystemdsystemunitdir=" flag) old.mesonFlags
      ++ [ "-Dsystemdsystemunitdir=" ];
  });

  # Libvirt uses login1 over D-Bus, provided here by elogind.
  libvirt = (prev.libvirt.override { systemd = final.elogind; }).overrideAttrs (old: {
    mesonFlags =
      final.lib.filter (
        flag: !(final.lib.hasPrefix "-Dinit_script=" flag || final.lib.hasPrefix "-Dlogin_shell=" flag)
      ) old.mesonFlags
      ++ [
        "-Dinit_script=none"
        "-Dlogin_shell=disabled"
      ];
  });
}
