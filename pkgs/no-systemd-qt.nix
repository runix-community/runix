final: prev: {
  qt6Packages = prev.qt6Packages.overrideScope (
    _: qtPrev: {
      qtbase = qtPrev.qtbase.override {
        systemdSupport = false;
        udev = final.udev;
      };
    }
  );
}
