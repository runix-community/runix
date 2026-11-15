# What every installed Runix has, as the installer writes it; the profiles add
# a desktop. Host and user names barely change a system's closure, so the
# cached builds serve every install.
{ pkgs, ... }:
{
  fileSystems."/" = {
    device = "/dev/disk/by-label/runix-root";
    fsType = "ext4";
  };
  runix.hostName = "runix";
  runix.groups.wheel.gid = 1;
  runix.users.runix = {
    uid = 1000;
    gid = 100;
    extraGroups = [ "wheel" "audio" "input" "render" "video" ];
  };
  programs.sudo.enable = true;
  runix.services.getty.command = "${pkgs.busybox}/bin/getty 38400 tty1";
  runix.systemServices.wifi.enable = true;
  runix.boot.loader.limine = {
    enable = true;
    mode = "efi";
  };
}
