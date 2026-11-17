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
  fileSystemTable = import ./filesystems/table.nix pkgs;
  # ext2 and ext3 are served by the ext4 module, and so on: the table names
  # the module, and an unknown type is taken as its own module name.
  earlyFileSystemModules = lib.unique (
    lib.concatMap (
      fileSystem:
      lib.optional (
        !(lib.elem fileSystem.fsType [
          ""
          "auto"
          "tmpfs"
          "zfs"
        ])
      ) (fileSystemTable.${fileSystem.fsType}.module or fileSystem.fsType)
    ) cfg.build.earlyFileSystems
  );
  kernel = cfg.kernel.package;
  modulesTree = pkgs.aggregateModules ([ (kernel.modules or kernel) ] ++ cfg.kernel.modulePackages);
  emptyFirmware = pkgs.runCommand "runix-empty-firmware" { } ''
    mkdir -p "$out/lib/firmware"
  '';
  firmware =
    if cfg.kernel.firmwarePackages == [ ] then
      emptyFirmware
    else
      pkgs.buildEnv {
        name = "runix-firmware";
        paths = cfg.kernel.firmwarePackages;
        pathsToLink = [ "/lib/firmware" ];
        ignoreCollisions = true;
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
    ++ lib.optional (root.fsType == "f2fs") pkgs.f2fs-tools
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
          fail "early filesystem device did not appear: ${fileSystem.device}"
          exit 1
        fi
        sleep 0.1
      done
    ''}
    step ${lib.escapeShellArg "mounting ${fileSystem.mountPoint} from ${fileSystem.device} (${fileSystem.fsType})"}
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
            fail "VM root device did not appear: $root_device"
            exit 1
          fi
          sleep 0.1
        done
        if [ "$format_root" = 1 ]; then
          step "formatting the persistent VM root"
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
    else if cfg.iso.enable then
      ''
        live_device=${lib.escapeShellArg "/dev/disk/by-label/${cfg.iso.volumeId}"}
        tries=0
        until [ -e "$live_device" ]; do
          tries=$((tries + 1))
          if [ "$tries" -ge ${toString (cfg.initrd.rootTimeout * 10)} ]; then
            fail "live medium did not appear: $live_device"
            exit 1
          fi
          sleep 0.1
        done
        mkdir -p /run/runix-live/iso
        mount -t iso9660 -o ro "$live_device" /run/runix-live/iso
        mount -t tmpfs -o mode=0755 tmpfs /sysroot
        mkdir -p /sysroot/nix/.ro-store /sysroot/nix/.rw-store/upper /sysroot/nix/.rw-store/work /sysroot/nix/store
        store_image=/run/runix-live/iso/runix/nix-store.squashfs
        if grep -qw runix.toram /proc/cmdline; then
          # Copy the store into RAM and let go of the medium, so it can be
          # removed once the system is up.
          step "copying the live system to RAM"
          mkdir -p /run/runix-live/ram
          mount -t tmpfs -o size=100%,mode=0755 tmpfs /run/runix-live/ram
          cp "$store_image" /run/runix-live/ram/nix-store.squashfs
          store_image=/run/runix-live/ram/nix-store.squashfs
        fi
        mount -t squashfs -o ro,loop "$store_image" /sysroot/nix/.ro-store
        if grep -qw runix.toram /proc/cmdline; then
          umount /run/runix-live/iso || true
        fi
        mount -t overlay overlay \
          -o lowerdir=/sysroot/nix/.ro-store,upperdir=/sysroot/nix/.rw-store/upper,workdir=/sysroot/nix/.rw-store/work \
          /sysroot/nix/store
      ''
    else if cfg.zfs.enable then
      let
        pool = lib.escapeShellArg (builtins.head (lib.splitString "/" root.device));
      in
      ''
        zgenhostid -f ${lib.escapeShellArg cfg.zfs.hostId}
        modprobe zfs
        step "importing the ZFS pool ${pool}"
        force=${lib.optionalString cfg.zfs.forceImportRoot "-f"}
        for option in $(cat /proc/cmdline); do
          [ "$option" != zfs_force=1 ] || force=-f
        done
        tries=0
        until zpool list -H ${pool} >/dev/null 2>&1; do
          if zpool import -N -d ${lib.escapeShellArg cfg.zfs.devNodes} $force ${pool} 2>/run/zpool-import.err; then
            break
          fi
          cat /run/zpool-import.err >/dev/console
          # A pool last used under another host ID never imports by waiting.
          if grep -q "in use from another system" /run/zpool-import.err; then
            fail "${pool} was last used by another system (a different host ID)"
            fail "boot once with zfs_force=1 on the kernel command line to import it anyway"
            exit 1
          fi
          tries=$((tries + 1))
          if [ "$tries" -ge ${toString cfg.initrd.rootTimeout} ]; then
            fail "failed to import ZFS root pool ${pool}"
            exit 1
          fi
          sleep 1
        done
        # Plain mount only accepts datasets with mountpoint=legacy; zfsutil
        # mounts the others, whatever their mountpoint says.
        if [ "$(zfs get -H -o value mountpoint "$root_device")" = legacy ]; then
          mount -t zfs -o "$root_options" "$root_device" /sysroot
        else
          mount -t zfs -o "$root_options,zfsutil" "$root_device" /sysroot
        fi
        ${mountEarlyFileSystems}
      ''
    else
      ''
        tries=0
        until [ -e "$root_device" ]; do
          tries=$((tries + 1))
          if [ "$tries" -ge ${toString (cfg.initrd.rootTimeout * 10)} ]; then
            fail "root device did not appear: $root_device"
            exit 1
          fi
          sleep 0.1
        done
        # After a crash or power cut: repair what is safe to repair before
        # mounting. e2fsck -p answers nothing interactively.
        case "$root_fs_type" in
          ext2 | ext3 | ext4)
            step "checking $root_device (e2fsck)"
            fsck_status=0
            e2fsck -p "$root_device" >/dev/console 2>&1 || fsck_status=$?
            if [ $((fsck_status & 2)) -ne 0 ]; then
              warn "the root filesystem was repaired; rebooting"
              sync
              reboot -f
            fi
            if [ $((fsck_status & 4)) -ne 0 ]; then
              fail "the root filesystem has errors e2fsck -p cannot fix;" \
                "booting anyway: run e2fsck -f on it from the ISO"
            fi
            ;;
          f2fs)
            step "checking $root_device (fsck.f2fs)"
            # -a checks only when the filesystem says it needs it.
            fsck.f2fs -a "$root_device" >/dev/console 2>&1 \
              || fail "fsck.f2fs could not repair the root filesystem;" \
                "booting anyway: run fsck.f2fs -f on it from the ISO"
            ;;
        esac
        mount -t "$root_fs_type" -o "$root_options" "$root_device" /sysroot
        ${mountEarlyFileSystems}
      '';

  init = pkgs.writeScript "runix-initrd" ''
    #!/bin/sh
    set -eu
    export PATH=/bin:/sbin
    mkdir -p /dev /proc /run /sys /sysroot
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devtmpfs devtmpfs /dev
    ln -sfn /proc/self/fd /dev/fd
    ln -sfn /proc/self/fd/0 /dev/stdin
    ln -sfn /proc/self/fd/1 /dev/stdout
    ln -sfn /proc/self/fd/2 /dev/stderr
    mount -t tmpfs -o mode=0755 tmpfs /run
    # Boot messages: a green step, a yellow warning, a red failure, each with
    # the seconds since boot. "quiet" hides the steps, never the problems.
    quiet=0
    for option in $(cat /proc/cmdline); do
      [ "$option" != quiet ] || quiet=1
    done
    current_step="starting the initrd"
    # Never fails: a message must not be what stops the boot.
    say() {
      uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null) || uptime=
      printf '\033[2m[%7s]\033[0m %b %s\n' "$uptime" "$1" "$2" >/dev/console 2>/dev/null || true
    }
    step() {
      current_step="$*"
      [ "$quiet" = 1 ] || say '\033[1;32m::\033[0m' "$*"
    }
    warn() { say '\033[1;33m!!\033[0m' "$*"; }
    fail() { say '\033[1;31m!!\033[0m' "$*"; }
    # Anything that ends the initrd early panics the kernel; first say what
    # was going on, and keep it on screen long enough to read.
    on_exit() {
      status=$?
      [ "$status" -ne 0 ] || return 0
      fail "boot stopped while $current_step (exit status $status)"
      sleep 15
    }
    trap on_exit EXIT
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
      fail "no root filesystem in /etc/fstab or fileSystems.\"/\""
      exit 1
    }
    [ -n "$root_fs_type" ] || root_fs_type=auto
    [ -n "$root_options" ] || root_options=defaults
    step "loading kernel modules: ${toString cfg.initrd.loadModules}"
    ${loadModules}
    step "starting the device manager (mdevd)"
    /bin/mdevd -D 3 -f /etc/mdev.conf -F /lib/firmware -O 2 3>/run/mdevd-initrd-ready &
    mdevd_pid="$!"
    tries=0
    until [ -s /run/mdevd-initrd-ready ]; do
      kill -0 "$mdevd_pid" || exit 1
      tries=$((tries + 1))
      [ "$tries" -lt 300 ] || exit 1
      sleep 0.1
    done
    step "finding devices"
    /bin/timeout ${toString cfg.initrd.rootTimeout} /bin/mdevd-coldplug -O 2
    step "mounting / from $root_device ($root_fs_type)"
    ${mountRoot}

    # runit powers off without stage 1, and only activation creates /etc on an
    # empty root. An installed link dangles here, so -e alone would misread it.
    if [ ! -e /sysroot/etc/runit/1 ] && [ ! -L /sysroot/etc/runit/1 ]; then
      mkdir -p /sysroot/etc/runit
      ln -s ${cfg.build.stage1} /sysroot/etc/runit/1
    fi

    stage2_init=/init
    for option in $(cat /proc/cmdline); do
      case "$option" in
        init=*) stage2_init="''${option#init=}" ;;
      esac
    done
    step "switching to the installed system"
    mkdir -p /sysroot/dev /sysroot/proc /sysroot/run /sysroot/sys
    mount --bind /dev /sysroot/dev
    mount --bind /proc /sysroot/proc
    mount --bind /run /sysroot/run
    mount --bind /sys /sysroot/sys
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
        source = "${initrdPath}/bin";
        target = "/sbin";
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
      apply = lib.unique;
      description = "Kernel modules copied into the initial ramdisk.";
    };
    loadModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      apply = lib.unique;
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
        ++ earlyFileSystemModules
      );
      loadModules = lib.mkBefore earlyFileSystemModules;
    };
    build = {
      inherit initrd modulesTree firmware;
    };
  };
}
