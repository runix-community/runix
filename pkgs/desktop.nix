{ pkgs }:
let
  udev = pkgs.libudev-zero;

  libinput = pkgs.libinput.override {
    inherit udev;
    wacomSupport = false;
  };

  aquamarine = (pkgs.aquamarine.override {
    inherit libinput udev;
  }).overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./aquamarine-libudev-zero.patch ];
  });

  pipewire =
    (pkgs.pipewire.override {
      enableSystemd = false;
      inherit udev;
    }).overrideAttrs
      (old: {
        patches = (old.patches or [ ]) ++ [ ./pipewire-mdevd.patch ];
      });

  weston = (pkgs.weston.override { inherit libinput; }).overrideAttrs (old: {
    mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dsystemd=false" ];
  });

  sddmUnwrapped = pkgs.kdePackages.sddm.unwrapped.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      "-DENABLE_JOURNALD=OFF"
      "-DNO_SYSTEMD=ON"
      "-DUSE_ELOGIND=OFF"
    ];
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/daemon/SeatManager.cpp \
        --replace-fail \
          'if (DaemonApp::instance()->testing() || !Logind::isAvailable()) {' \
          'if (true) {'
    '';
  });

  sddm = pkgs.kdePackages.sddm.override { sddm-unwrapped = sddmUnwrapped; };
in
{
  inherit libinput pipewire sddm weston;

  wireplumber = pkgs.wireplumber.override { inherit pipewire; };

  hyprland = pkgs.hyprland.override {
    inherit aquamarine libinput;
    withSystemd = false;
  };

  labwc = pkgs.labwc.override (
    old:
    let
      wlrootsAttr = pkgs.lib.head (pkgs.lib.filter (pkgs.lib.hasPrefix "wlroots") (builtins.attrNames old));
    in
    {
      inherit libinput;
      ${wlrootsAttr} = old.${wlrootsAttr}.override { inherit libinput; };
      enableSystemd = false;
    }
  );

  niri = pkgs.niri.override {
    eudev = udev;
    inherit libinput pipewire;
    withSystemd = false;
  };
}
