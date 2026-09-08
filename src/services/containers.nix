{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.runix.systemServices.docker.enable = lib.mkEnableOption "Docker with containerd";
  config = lib.mkIf config.runix.systemServices.docker.enable {
    runix.packages = [
      pkgs.containerd
      pkgs.docker
      pkgs.iptables
    ];
    runix.activationScripts = [
      ''
        if ! ${pkgs.util-linux}/bin/mountpoint -q /sys/fs/cgroup; then
          mkdir -p /sys/fs/cgroup
          ${pkgs.util-linux}/bin/mount -t cgroup2 cgroup2 /sys/fs/cgroup
        fi
      ''
    ];
    runix.preparationScripts = [ "mkdir -p /etc/docker /var/lib/containerd /var/lib/docker" ];
    runix.services.containerd = {
      command = "${pkgs.containerd}/bin/containerd";
      check = "test -S /run/containerd/containerd.sock";
    };
    runix.services.docker = {
      command = "${pkgs.docker}/bin/dockerd --host=unix:///run/docker.sock --containerd=/run/containerd/containerd.sock";
      after = [ "containerd" ];
      check = "test -S /run/docker.sock";
    };
  };
}
