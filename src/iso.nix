{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix;
  iso = cfg.iso;
  fileName = "runix-live-${pkgs.stdenv.hostPlatform.system}.iso";

  storageModules = [
    "ahci"
    "ata_piix"
    "cdrom"
    "ehci_pci"
    "isofs"
    "loop"
    "nvme"
    "overlay"
    "sd_mod"
    "sr_mod"
    "squashfs"
    "uas"
    "usb_storage"
    "virtio_scsi"
    "xhci_pci"
  ];

  installer = pkgs.callPackage ../pkgs/runix-installer {
    runix-install = pkgs.callPackage ../pkgs/runix-install { };
    flakeUrl = iso.installerFlake;
    logPasteUrl = iso.logPasteUrl;
  };

  session = pkgs.writeShellScript "runix-live-session" ''
    . /etc/profile
    export HOME=/root USER=root
    cd /root
    # A larger, sharper console font; the serial console has no font to set.
    case "$(${pkgs.coreutils}/bin/tty)" in
      /dev/tty[0-9]*)
        ${pkgs.kbd}/bin/setfont ${pkgs.terminus_font}/share/consolefonts/ter-v22b.psf.gz 2>/dev/null || true
        ;;
    esac
    ${lib.getExe installer} || true
    exec ${pkgs.bashInteractive}/bin/bash --login
  '';
  shell = pkgs.writeShellScript "runix-live-shell" ''
    . /etc/profile
    export HOME=/root USER=root
    cd /root
    exec ${pkgs.bashInteractive}/bin/bash --login
  '';
  agetty = program: arguments: "${pkgs.util-linux}/bin/agetty --noclear --noissue --skip-login --login-program ${program} ${arguments}";

  closure = pkgs.closureInfo { rootPaths = [ cfg.build.system ]; };
  store =
    pkgs.runCommand "runix-live-store.squashfs" { nativeBuildInputs = [ pkgs.squashfsTools ]; }
      ''
        cp ${closure}/registration nix-path-registration
        mksquashfs nix-path-registration $(cat ${closure}/store-paths) "$out" \
          -no-hardlinks -keep-as-directory -all-root -root-mode 0755 \
          -b 1048576 -comp zstd -Xcompression-level ${toString iso.compressionLevel} \
          -processors "$NIX_BUILD_CORES"
      '';

  bootEntry = title: extraParameters: ''
    /${title}
    protocol: linux
    path: boot():/boot/kernel
    module_path: boot():/boot/initrd
    cmdline: ${
      lib.concatStringsSep " " (
        [ "init=${cfg.build.system}/init" ] ++ cfg.kernel.parameters ++ extraParameters
      )
    }
  '';
  limineConfig = pkgs.writeText "runix-live-limine.conf" ''
    timeout: ${toString iso.timeout}

    ${bootEntry "Runix Installer" [ ]}
    ${bootEntry "Runix Installer (safe graphics)" [ "nomodeset" ]}
  '';

  image =
    pkgs.runCommand fileName
      {
        nativeBuildInputs = [
          iso.liminePackage
          pkgs.xorriso
        ];
      }
      ''
        limine_files=${iso.liminePackage}/share/limine
        for file in limine-bios.sys limine-bios-cd.bin limine-uefi-cd.bin BOOTX64.EFI; do
          if [ ! -e "$limine_files/$file" ]; then
            echo "runix.iso.liminePackage has no $file; it must be built with BIOS, CD, and UEFI support" >&2
            exit 1
          fi
        done

        mkdir -p iso_root/boot/limine iso_root/EFI/BOOT iso_root/runix
        cp -L ${cfg.build.system}/kernel ${cfg.build.system}/initrd iso_root/boot/
        cp ${limineConfig} iso_root/boot/limine/limine.conf
        cp "$limine_files"/limine-bios.sys "$limine_files"/limine-bios-cd.bin \
          "$limine_files"/limine-uefi-cd.bin iso_root/boot/limine/
        cp "$limine_files"/BOOTX64.EFI iso_root/EFI/BOOT/
        cp ${store} iso_root/runix/nix-store.squashfs

        mkdir -p "$out/iso"
        xorriso -as mkisofs -iso-level 3 -r -J \
          -V ${lib.escapeShellArg iso.volumeId} \
          -b boot/limine/limine-bios-cd.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
          --efi-boot boot/limine/limine-uefi-cd.bin -efi-boot-part --efi-boot-image \
          --protective-msdos-label \
          -o "$out/iso/${fileName}" iso_root
        limine bios-install "$out/iso/${fileName}"
      '';
in
{
  options.runix.iso = {
    enable = lib.mkEnableOption "the bootable live installer image";
    volumeId = lib.mkOption {
      type = lib.types.strMatching "[A-Z0-9_]{1,16}";
      default = "RUNIX_LIVE";
      description = "ISO volume label the initrd uses to find the boot medium.";
    };
    timeout = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 5;
      description = "Seconds before the default boot entry is selected.";
    };
    compressionLevel = lib.mkOption {
      type = lib.types.ints.between 1 22;
      default = 15;
      description = "Zstandard compression level for the live Nix store.";
    };
    firmware = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to include redistributable firmware, which most Wi-Fi hardware needs.";
    };
    installerFlake = lib.mkOption {
      type = lib.types.str;
      default = "github:runix-community/runix";
      description = "Flake reference used as the runix input of installed systems.";
    };
    logPasteUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://paste.rs/";
      example = "https://paste.example.org/";
      description = ''
        Where the installer uploads the log of a failed installation, only
        after the user confirms. The service must accept the log as a raw POST
        body and answer with the paste's URL.
      '';
    };
    liminePackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.limine.override { enableAll = true; };
      description = "Limine package providing the BIOS and UEFI CD boot files.";
    };
  };

  config = lib.mkIf iso.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isx86_64;
        message = "runix.iso currently supports only x86_64-linux";
      }
      {
        assertion = !cfg.virtualMachine.enable;
        message = "runix.iso and runix.virtualMachine cannot be enabled together";
      }
    ];

    runix.hostName = lib.mkDefault "runix-live";
    fileSystems."/" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" ];
    };

    runix.initrd = {
      modules = storageModules;
      loadModules = storageModules;
    };
    runix.kernel.parameters = [
      "console=ttyS0,115200n8"
      "console=tty0"
      "loglevel=3"
    ];
    hardware.enableRedistributableFirmware = lib.mkDefault iso.firmware;

    runix.systemServices.wifi.enable = true;
    runix.packages = [
      installer
      pkgs.curl
      pkgs.gptfdisk
      pkgs.pciutils
      pkgs.usbutils
    ];

    # The registration sits in the squashfs because it cannot reference itself.
    runix.activationScripts = [
      ''
        if [ -f /nix/store/nix-path-registration ]; then
          ${pkgs.nix}/bin/nix-store --load-db < /nix/store/nix-path-registration
          rm -f /nix/store/nix-path-registration
        fi
      ''
    ];

    runix.services = {
      # wpa-supplicant never becomes ready without a wireless card, and wired
      # machines still need DHCP.
      dhcpcd.after = lib.mkForce [ "mdevd-coldplug" ];
      installer = {
        command = agetty session "tty1 linux";
        log = false;
        after = [ "mdevd-coldplug" ];
      };
      live-shell = {
        command = agetty shell "tty2 linux";
        log = false;
        after = [ "mdevd-coldplug" ];
      };
      # Headless machines get the installer too; most PCs have no ttyS0 to open.
      installer-serial = {
        script = ''
          if ! ${pkgs.coreutils}/bin/stty -F /dev/ttyS0 >/dev/null 2>&1; then
            exec ${pkgs.coreutils}/bin/sleep infinity
          fi
          exec ${agetty session "-L 115200 ttyS0 vt100"}
        '';
        log = false;
        after = [ "mdevd-coldplug" ];
      };
    };

    runix.build.iso = image;
  };
}
