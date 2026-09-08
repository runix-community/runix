{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix;
  qemu = cfg.virtualMachine.qemuPackage;
  kernelParams = lib.concatStringsSep " " (
    [
      "console=ttyS0,115200n8"
      "quiet"
      "loglevel=3"
      "panic=1"
      "init=${cfg.build.system}/init"
    ]
    ++ cfg.kernel.parameters
  );

  vm = pkgs.writeShellScript "runix-vm" ''
    disk="''${RUNIX_VM_DISK:-${cfg.virtualMachine.diskImage}}"
    nix_db="''${RUNIX_VM_NIX_DB:-/nix/var/nix/db}"
    if [ ! -d "$nix_db" ]; then
      nix_db="$disk.nix-db"
      ${pkgs.coreutils}/bin/mkdir -p "$nix_db"
    fi
    kernel_params=${lib.escapeShellArg kernelParams}
    format_root=0
    if [ ! -e "$disk" ]; then
      ${qemu}/bin/qemu-img create -f qcow2 "$disk" ${toString cfg.virtualMachine.diskSize}M
      format_root=1
    fi

    exec ${qemu}/bin/qemu-system-x86_64 \
      -enable-kvm \
      -m ${toString cfg.virtualMachine.memory} \
      -smp ${toString cfg.virtualMachine.cpus} \
      -kernel ${cfg.build.system}/kernel \
      -initrd ${cfg.build.system}/initrd \
      -append "$kernel_params runix.format-root=$format_root" \
      -drive "file=$disk,if=virtio,format=qcow2" \
      -fsdev local,id=nix-store,path=/nix/store,security_model=none,readonly=on \
      -device virtio-9p-pci,fsdev=nix-store,mount_tag=nix-store \
      -fsdev local,id=nix-db,path="$nix_db",security_model=none,readonly=on \
      -device virtio-9p-pci,fsdev=nix-db,mount_tag=nix-db \
      -nographic \
      -no-reboot \
      "$@"
  '';
in
{
  options.runix.virtualMachine = {
    qemuPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.qemu_test;
      description = "Host-side QEMU package; not installed in the guest system.";
    };
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Build for the self-contained Runix QEMU harness.";
    };
    memory = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2048;
      description = "VM memory in MiB.";
    };
    cpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "VM virtual CPU count.";
    };
    diskImage = lib.mkOption {
      type = lib.types.str;
      default = "runix.qcow2";
      description = "Default writable qcow2 root image path, overridable with RUNIX_VM_DISK.";
    };
    diskSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8192;
      description = "Size in MiB used when creating the persistent VM root image.";
    };
  };

  config = lib.mkIf cfg.virtualMachine.enable {
    fileSystems."/" = {
      device = "/dev/vda";
      fsType = "ext4";
    };
    runix.initrd.loadModules = [
      "virtio_pci"
      "virtio_blk"
      "ext4"
      "overlay"
      "e1000"
      "9p"
      "9pnet_virtio"
    ];
    runix.initrd.modules = [
      "virtio_pci"
      "virtio_blk"
      "ext4"
      "overlay"
      "e1000"
      "9p"
      "9pnet"
      "9pnet_virtio"
    ];
    runix.packages = [
      pkgs.cacert
      pkgs.nix
    ];
    runix.environmentVariables.NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    runix.activationScripts = [
      ''
        ${pkgs.iproute2}/bin/ip link set eth0 up
        ${pkgs.iproute2}/bin/ip address replace 10.0.2.15/24 dev eth0
        ${pkgs.iproute2}/bin/ip route replace default via 10.0.2.2
        printf '%s\n' 'nameserver 10.0.2.3' > /etc/resolv.conf
      ''
    ];
    runix.build.vm = vm;
  };
}
