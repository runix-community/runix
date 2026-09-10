{
  libudev-zero,
  networkmanager,
}:
(networkmanager.override {
  udev = libudev-zero;
  withSystemd = false;
}).overrideAttrs (old: {
  mesonFlags = old.mesonFlags ++ [ "-Dsystemdsystemgeneratordir=no" ];
})
