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
}
