final: prev: {
  kdePackages = prev.kdePackages.overrideScope (
    kfinal: kprev: {
      qtbase = kprev.qtbase.override {
        systemdSupport = false;
        udev = final.udev;
      };

      sddm-unwrapped = kprev.sddm-unwrapped.overrideAttrs (old: {
        buildInputs = prev.lib.filter (input: input != prev.systemd) old.buildInputs ++ [ final.elogind ];
        cmakeFlags = prev.lib.filter (flag: !prev.lib.hasPrefix "-DSYSTEMD_" flag) old.cmakeFlags ++ [
          "-DNO_SYSTEMD=ON"
          "-DUSE_ELOGIND=ON"
          "-DENABLE_JOURNALD=OFF"
        ];
      });

      sddm = kprev.sddm.override {
        sddm-unwrapped = kfinal.sddm-unwrapped;
      };
    }
  );
}
