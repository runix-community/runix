{ pkgs }:
let
  udev = pkgs.libudev-zero;

  libinput = pkgs.libinput.override {
    inherit udev;
    wacomSupport = false;
  };

  aquamarine = pkgs.aquamarine.override {
    inherit libinput udev;
  };

  pipewire =
    (pkgs.pipewire.override {
      enableSystemd = false;
      inherit udev;
    }).overrideAttrs
      (old: {
        patches = (old.patches or [ ]) ++ [ ./pipewire-mdevd.patch ];
      });
in
{
  inherit libinput pipewire;

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
