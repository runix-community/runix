final: prev: {
  # Replace nixpkgs' systemd-backed libudev provider.
  udev = prev.libudev-zero;

  # Avoid elogind's default eudev dependency.
  elogind = prev.elogind.override {
    eudev = final.udev;
  };

  libusb1 = prev.libusb1.override {
    udev = final.udev;
  };

  cups = prev.cups.override {
    enableSystemd = false;
    libusb1 = final.libusb1;
  };

  python3Packages = prev.python3Packages.overrideScope (
    _: pyPrev: {
      pyudev = pyPrev.pyudev.override {
        udev = final.udev;
      };
    }
  );

  # libgudev's tests link umockdev, which is built against systemd's libudev
  # and carries versioned symbols (udev_*@LIBUDEV_183) that libudev-zero
  # does not provide; drop the tests.
  libgudev = prev.libgudev.overrideAttrs (old: {
    doCheck = false;
  });

  # The D-Bus-backed collection test is flaky on shared CI runners.
  libsecret = prev.libsecret.overrideAttrs (old: {
    doCheck = false;
  });

  # libudev-zero has no udev_queue API; build without udev sync/rules.
  lvm2 = prev.lvm2.override {
    udevSupport = false;
  };
}
