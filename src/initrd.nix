{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix;
  root =
    config.fileSystems."/" or {
      device = "";
      fsType = "";
      options = [ ];
    };
  rootFileSystemModule = lib.optional (
    root.fsType != "" && root.fsType != "auto" && root.fsType != "zfs"
  ) root.fsType;
  btrfsChecksumModules = lib.optionals (
    builtins.any (fileSystem: fileSystem.fsType == "btrfs") cfg.build.earlyFileSystems
  ) [
    "crc32c"
    "xxhash64"
    "sha256"
    "blake2b-256"
  ];
  kernel = cfg.kernel.package;
  modulesTree = pkgs.aggregateModules ([ (kernel.modules or kernel) ] ++ cfg.kernel.modulePackages);
  emptyFirmware = pkgs.runCommand "runix-empty-firmware" { } ''
    mkdir -p "$out/lib/firmware"
  '';
  firmware =
    if cfg.kernel.firmwarePackages == [ ] then
      emptyFirmware
    else
      pkgs.symlinkJoin {
        name = "runix-firmware";
        paths = cfg.kernel.firmwarePackages;
      };

  modulesClosure = pkgs.makeModulesClosure {
    rootModules = cfg.initrd.modules;
    kernel = modulesTree;
    inherit firmware;
    allowMissing = false;
  };

  initrdPath = pkgs.buildEnv {
    name = "runix-initrd-path";
    paths = [
      config.services.mdevd.package
      cfg.build.mdevTools
      pkgs.e2fsprogs
      pkgs.busybox
      pkgs.kmod
      pkgs.util-linux.mount
    ]
    ++ lib.optional cfg.zfs.enable cfg.zfs.package;
    pathsToLink = [
      "/bin"
      "/sbin"
    ];
    ignoreCollisions = true;
  };

  loadModules = lib.concatMapStringsSep "\n" (
    module: "modprobe ${lib.escapeShellArg module}"
  ) cfg.initrd.loadModules;
  rootOptions = lib.concatStringsSep "," root.options;
  earlyFileSystems = builtins.filter (
    fileSystem: fileSystem.mountPoint != "/"
  ) cfg.build.earlyFileSystems;
  mountEarlyFileSystems = lib.concatMapStringsSep "\n" (fileSystem: ''
    ${lib.optionalString (lib.hasPrefix "/" fileSystem.device) ''
      tries=0
      until [ -e ${lib.escapeShellArg fileSystem.device} ]; do
        tries=$((tries + 1))
        if [ "$tries" -ge ${toString (cfg.initrd.rootTimeout * 10)} ]; then
          echo "runix: early filesystem device did not appear: ${fileSystem.device}" >/dev/console
          exit 1
        fi
        sleep 0.1
      done
    ''}
    mkdir -p ${lib.escapeShellArg "/sysroot${fileSystem.mountPoint}"}
    mount \
      -t ${lib.escapeShellArg fileSystem.fsType} \
      -o ${lib.escapeShellArg (lib.concatStringsSep "," fileSystem.options)} \
      ${lib.escapeShellArg fileSystem.device} \
      ${lib.escapeShellArg "/sysroot${fileSystem.mountPoint}"}
  '') earlyFileSystems;

  mountRoot =
    if cfg.virtualMachine.enable then
      ''
        tries=0
        until [ -e "$root_device" ]; do
          tries=$((tries + 1))
          if [ "$tries" -ge ${toString (cfg.initrd.rootTimeout * 10)} ]; then
            echo "runix: VM root device did not appear: $root_device" >/dev/console
            exit 1
          fi
          sleep 0.1
        done
        if [ "$format_root" = 1 ]; then
          echo "runix: formatting persistent VM root" >/dev/console
          mkfs.ext4 -q -F -L runix-root "$root_device"
        fi
        mount -t "$root_fs_type" -o "$root_options" "$root_device" /sysroot
        mkdir -p /sysroot/nix/.ro-store /sysroot/nix/.rw-store/upper /sysroot/nix/.rw-store/work /sysroot/nix/store
        mount -t 9p -o trans=virtio,version=9p2000.L,ro nix-store /sysroot/nix/.ro-store
        mount -t overlay overlay \
          -o lowerdir=/sysroot/nix/.ro-store,upperdir=/sysroot/nix/.rw-store/upper,workdir=/sysroot/nix/.rw-store/work \
          /sysroot/nix/store
        mkdir -p /sysroot/nix/.ro-db /sysroot/nix/.rw-db/upper /sysroot/nix/.rw-db/work /sysroot/nix/var/nix/db
        mount -t 9p -o trans=virtio,version=9p2000.L,ro nix-db /sysroot/nix/.ro-db
        mount -t overlay overlay \
          -o lowerdir=/sysroot/nix/.ro-db,upperdir=/sysroot/nix/.rw-db/upper,workdir=/sysroot/nix/.rw-db/work \
          /sysroot/nix/var/nix/db
        ${mountEarlyFileSystems}
      ''
    else if cfg.zfs.enable then
      let
        pool = builtins.head (lib.splitString "/" root.device);
        force = lib.optionalString cfg.zfs.forceImportRoot "-f";
      in
      ''
        zgenhostid -f ${lib.escapeShellArg cfg.zfs.hostId}
        modprobe zfs
        tries=0
        until zpool list -H ${lib.escapeShellArg pool} >/dev/null 2>&1; do
          if zpool import -N -d ${lib.escapeShellArg cfg.zfs.devNodes} ${force} ${lib.escapeShellArg pool}; then
            break
          fi
          tries=$((tries + 1))
          if [ "$tries" -ge ${toString cfg.initrd.rootTimeout} ]; then
            echo "runix: failed to import ZFS root pool ${pool}" >/dev/console
            exit 1
          fi
          sleep 1
        done
        mount -t zfs -o "$root_options" "$root_device" /sysroot
        ${mountEarlyFileSystems}
      ''
    else
      ''
        tries=0
        until [ -e "$root_device" ]; do
          tries=$((tries + 1))
          if [ "$tries" -ge ${toString (cfg.initrd.rootTimeout * 10)} ]; then
            echo "runix: root device did not appear: $root_device" >/dev/console
            exit 1
          fi
          sleep 0.1
        done
        mount -t "$root_fs_type" -o "$root_options" "$root_device" /sysroot
        ${mountEarlyFileSystems}
      '';

  init = pkgs.writeScript "runix-initrd" ''
    #!/bin/sh
    set -eu
    export PATH=/bin:/sbin
    echo "runix: initrd" >/dev/console
    mkdir -p /dev /proc /run /sys /sysroot
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devtmpfs devtmpfs /dev
    ln -sfn /proc/self/fd /dev/fd
    ln -sfn /proc/self/fd/0 /dev/stdin
    ln -sfn /proc/self/fd/1 /dev/stdout
    ln -sfn /proc/self/fd/2 /dev/stderr
    mount -t tmpfs -o mode=0755 tmpfs /run
    format_root=0
    root_device=${lib.escapeShellArg root.device}
    root_fs_type=${lib.escapeShellArg root.fsType}
    root_options=${lib.escapeShellArg rootOptions}
    for option in $(cat /proc/cmdline); do
      case "$option" in
        runix.format-root=1) format_root=1 ;;
        root=*) root_device="''${option#root=}" ;;
        rootfstype=*) root_fs_type="''${option#rootfstype=}" ;;
        rootflags=*) root_options="''${option#rootflags=}" ;;
      esac
    done
    case "$root_device" in
      UUID=*) root_device="/dev/disk/by-uuid/''${root_device#UUID=}" ;;
      LABEL=*) root_device="/dev/disk/by-label/''${root_device#LABEL=}" ;;
      PARTUUID=*) root_device="/dev/disk/by-partuuid/''${root_device#PARTUUID=}" ;;
      PARTLABEL=*) root_device="/dev/disk/by-partlabel/''${root_device#PARTLABEL=}" ;;
    esac
    [ -n "$root_device" ] || {
      echo "runix: no root filesystem in /etc/fstab or fileSystems.\"/\"" >/dev/console
      exit 1
    }
    [ -n "$root_fs_type" ] || root_fs_type=auto
    [ -n "$root_options" ] || root_options=defaults
    ${loadModules}
    /bin/mdevd -D 3 -f /etc/mdev.conf -F /lib/firmware -O 4 3>/run/mdevd-initrd-ready &
    mdevd_pid="$!"
    tries=0
    until [ -s /run/mdevd-initrd-ready ]; do
      kill -0 "$mdevd_pid" || exit 1
      tries=$((tries + 1))
      [ "$tries" -lt 300 ] || exit 1
      sleep 0.1
    done
    /bin/timeout ${toString cfg.initrd.rootTimeout} /bin/mdevd-coldplug -O 4
    ${mountRoot}

    stage2_init=/init
    for option in $(cat /proc/cmdline); do
      case "$option" in
        init=*) stage2_init="''${option#init=}" ;;
      esac
    done
    system="$(dirname "$stage2_init")"
    mkdir -p /sysroot/dev /sysroot/proc /sysroot/run /sysroot/sys
    mount --bind /dev /sysroot/dev
    mount --bind /proc /sysroot/proc
    mount --bind /run /sysroot/run
    mount --bind /sys /sysroot/sys
    chroot /sysroot "$system/activate"
    kill -TERM "$mdevd_pid" 2>/dev/null || true
    wait "$mdevd_pid" 2>/dev/null || true
    umount /sysroot/dev /sysroot/proc /sysroot/run /sysroot/sys
    mount --move /dev /sysroot/dev
    mount --move /proc /sysroot/proc
    mount --move /run /sysroot/run
    mount --move /sys /sysroot/sys
    mkdir -p /sysroot/dev/pts /sysroot/dev/shm
    mount -t devpts -o gid=5,mode=0620,ptmxmode=0666 devpts /sysroot/dev/pts
    ln -sf pts/ptmx /sysroot/dev/ptmx
    mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /sysroot/dev/shm
    exec switch_root /sysroot "$stage2_init"
  '';

  baseInitrd = pkgs.makeInitrdNG {
    name = "runix-initrd";
    compressor = "zstd";
    contents = [
      {
        source = "${modulesClosure}/lib";
        target = "/lib";
      }
      {
        source = "${initrdPath}/bin";
        target = "/bin";
      }
      {
        source = init;
        target = "/init";
      }
      {
        source = config.runix.build.mdevConfig;
        target = "/etc/mdev.conf";
      }
    ];
  };
  initrd =
    if cfg.initrd.prepend == [ ] then
      baseInitrd
    else
      pkgs.runCommand "runix-initrd-with-early-firmware" { } ''
        mkdir -p "$out"
        cat ${lib.escapeShellArgs cfg.initrd.prepend} ${baseInitrd}/initrd > "$out/initrd"
      '';
in
{
  options.runix.initrd = {
    modules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Kernel modules copied into the initial ramdisk.";
    };
    loadModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Kernel modules loaded before mounting root.";
    };
    rootTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Seconds to wait for the root device.";
    };
    prepend = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = "Uncompressed early CPIO archives prepended to the initrd, such as CPU microcode.";
    };
  };

  config.runix = {
    initrd = {
      modules = lib.mkBefore (
        [
          "9p"
          "9pnet"
          "9pnet_virtio"
          "ext4"
          "virtio_blk"
          "virtio_pci"
        ]
        ++ rootFileSystemModule
        ++ btrfsChecksumModules
      );
      loadModules = lib.mkBefore rootFileSystemModule;
    };
    build = {
      inherit initrd modulesTree firmware;
    };
  };
}
