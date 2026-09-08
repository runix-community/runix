{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.runix.systemServices.libvirt.enable = lib.mkEnableOption "the libvirt daemon";
  config = lib.mkIf config.runix.systemServices.libvirt.enable {
    runix.packages = [
      pkgs.dnsmasq
      pkgs.libvirt
      pkgs.qemu
    ];
    runix.preparationScripts = [ "mkdir -p /run/libvirt /var/cache/libvirt /var/lib/libvirt" ];
    runix.services.libvirtd.command = "${pkgs.libvirt}/bin/libvirtd --verbose";
  };
}
