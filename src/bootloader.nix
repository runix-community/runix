{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix;
  loader = cfg.boot.loader;
  grubEnabled = loader.grub.enable;
  limineEnabled = loader.limine.enable;
  selectedLoader =
    if grubEnabled then
      "grub"
    else if limineEnabled then
      "limine"
    else
      null;

  kernelParams = lib.concatStringsSep " " cfg.kernel.parameters;
  configuredRoot = config.fileSystems."/" or null;
  configuredRootParams =
    if configuredRoot == null then
      ""
    else
      "root=${configuredRoot.device} rootfstype=${configuredRoot.fsType} "
      + "rootflags=${lib.concatStringsSep "," configuredRoot.options}";
  grubPackage = if loader.grub.mode == "efi" then pkgs.grub2_efi else pkgs.grub2;
  installCommon = ''
    root="''${1:-/}"
    case "$root" in
      /*) ;;
      *) echo "runix: installation root must be an absolute path" >&2; exit 2 ;;
    esac
    boot="''${root%/}${loader.mountPoint}"
    if [ ! -d "$boot" ]; then
      echo "runix: boot mount point does not exist: $boot" >&2
      exit 1
    fi
    boot_path=${lib.escapeShellArg "${lib.removeSuffix "/" loader.mountPoint}/runix"}
    if ${pkgs.util-linux}/bin/mountpoint -q "$boot"; then
      boot_path=/runix
    fi

    root_params=${lib.escapeShellArg configuredRootParams}
    if [ -r "$root/etc/fstab" ]; then
      while read -r source target type options _; do
        [ -n "$source" ] || continue
        case "$source" in \#*) continue ;; esac
        if [ "$target" = / ]; then
          root_params="root=$source rootfstype=$type rootflags=$options"
          break
        fi
      done < "$root/etc/fstab"
    fi
    [ -n "$root_params" ] || {
      echo "runix: /etc/fstab has no root filesystem" >&2
      exit 1
    }

    profile="$root/nix/var/nix/profiles/system"
    current_generation_link=""
    if [ -L "$profile" ]; then
      current_generation="$(${pkgs.coreutils}/bin/readlink "$profile")"
      current_generation_link="''${profile%/*}/''${current_generation##*/}"
    fi

    generation_links() {
      if [ -L "$current_generation_link" ]; then
        printf '%s\n' "$current_generation_link"
      fi
      for link in $(${pkgs.coreutils}/bin/printf '%s\n' "$root/nix/var/nix/profiles"/system-*-link | ${pkgs.coreutils}/bin/sort -Vr); do
        [ -L "$link" ] || continue
        [ "$link" = "$current_generation_link" ] && continue
        printf '%s\n' "$link"
      done
    }

    mapfile -t generations < <(generation_links | ${pkgs.coreutils}/bin/head -n ${toString loader.configurationLimit})
    if [ "''${#generations[@]}" -eq 0 ]; then
      generations=(current)
    fi

    boot_files="$boot/runix"
    ${pkgs.coreutils}/bin/mkdir -p "$boot_files"
    install_generation() {
      generation_params=${lib.escapeShellArg kernelParams}
      generation_root="$root_params"
      if [ -f "$system/kernel-params" ]; then generation_params="$(< "$system/kernel-params")"; fi
      if [ -s "$system/root-params" ]; then
        configured="$(< "$system/root-params")"
        [ -z "$configured" ] || generation_root="$configured"
      fi
      for artifact in kernel initrd; do
        if [ ! -e "$boot_files/$name-$artifact" ]; then
          ${pkgs.coreutils}/bin/install -m0644 "$system/$artifact" "$boot_files/$name-$artifact.tmp"
          ${pkgs.coreutils}/bin/mv "$boot_files/$name-$artifact.tmp" "$boot_files/$name-$artifact"
        fi
      done
    }
  '';

  grubInstaller = pkgs.writeShellScript "runix-install-grub" ''
    set -eu
    ${installCommon}
    ${pkgs.coreutils}/bin/mkdir -p "$boot/grub"
    config_file="$boot/grub/grub.cfg.tmp"
    ${pkgs.coreutils}/bin/printf '%s\n' \
      'set default=0' \
      'set timeout=${toString loader.timeout}' \
      ${lib.escapeShellArg loader.grub.extraConfig} >"$config_file"

    first=1
    for link in "''${generations[@]}"; do
      if [ "$link" = current ]; then
        generation=current
        system=${cfg.build.system}
      else
        generation="''${link##*/system-}"
        generation="''${generation%-link}"
        system="$(${pkgs.coreutils}/bin/readlink -f "$link")"
      fi
      name="''${system##*/}"
      install_generation
      if [ "$first" -eq 1 ]; then
        title='Latest generation'
      else
        title="Generation $generation"
      fi
      ${pkgs.coreutils}/bin/printf '%s\n' \
        "menuentry '$title' {" \
        "  linux $boot_path/$name-kernel init=$system/init $generation_params $generation_root" \
        "  initrd $boot_path/$name-initrd" \
        '}' >>"$config_file"
      if [ "$first" -eq 1 ]; then
        ${pkgs.coreutils}/bin/printf '%s\n' "submenu 'Other generations' {" >>"$config_file"
        first=0
      fi
    done
    ${pkgs.coreutils}/bin/printf '%s\n' '}' >>"$config_file"
    ${pkgs.coreutils}/bin/printf '%s\n' ${lib.escapeShellArg loader.grub.extraEntries} >>"$config_file"
    ${pkgs.coreutils}/bin/sync -f "$boot"
    ${pkgs.coreutils}/bin/mv "$config_file" "$boot/grub/grub.cfg"
    ${pkgs.coreutils}/bin/sync -f "$boot"
    ${grubPackage}/bin/grub-install \
      --boot-directory="$boot" \
      --recheck \
      ${
        if loader.grub.mode == "efi" then
          ''
            --target=${grubPackage.grubTarget} \
            --efi-directory="$boot" \
            --bootloader-id=Runix \
            --removable \
            --no-nvram
          ''
        else
          ''
            --target=i386-pc \
            ${lib.escapeShellArg loader.grub.device}
          ''
      }
  '';

  limineEfiFile =
    if pkgs.stdenv.hostPlatform.isx86_64 then
      "BOOTX64.EFI"
    else if pkgs.stdenv.hostPlatform.isAarch64 then
      "BOOTAA64.EFI"
    else
      "unsupported.EFI";

  limineInstaller = pkgs.writeShellScript "runix-install-limine" ''
    set -eu
    ${installCommon}
    ${pkgs.coreutils}/bin/mkdir -p "$boot/limine"
    config_file="$boot/limine/limine.conf.tmp"
    ${pkgs.coreutils}/bin/printf '%s\n' \
      'timeout: ${toString loader.timeout}' \
      'editor_enabled: ${if loader.limine.editorEnabled then "yes" else "no"}' \
      ${lib.escapeShellArg loader.limine.extraConfig} >"$config_file"

    first=1
    for link in "''${generations[@]}"; do
      if [ "$link" = current ]; then
        generation=current
        system=${cfg.build.system}
      else
        generation="''${link##*/system-}"
        generation="''${generation%-link}"
        system="$(${pkgs.coreutils}/bin/readlink -f "$link")"
      fi
      name="''${system##*/}"
      install_generation
      if [ "$first" -eq 1 ]; then
        title=/Latest\ generation
      else
        if [ "$first" -eq 0 ]; then
          ${pkgs.coreutils}/bin/printf '%s\n' '/+Other generations' >>"$config_file"
          first=2
        fi
        title="//Generation $generation"
      fi
      ${pkgs.coreutils}/bin/printf '%s\n' \
        "$title" \
        'protocol: linux' \
        "path: boot():$boot_path/$name-kernel" \
        "module_path: boot():$boot_path/$name-initrd" \
        "cmdline: init=$system/init $generation_params $generation_root" >>"$config_file"
      [ "$first" -ne 1 ] || first=0
    done
    ${pkgs.coreutils}/bin/printf '%s\n' ${lib.escapeShellArg loader.limine.extraEntries} >>"$config_file"
    ${pkgs.coreutils}/bin/sync -f "$boot"
    ${pkgs.coreutils}/bin/mv "$config_file" "$boot/limine/limine.conf"
    ${pkgs.coreutils}/bin/sync -f "$boot"
    ${
      if loader.limine.mode == "efi" then
        ''
          ${pkgs.coreutils}/bin/install -Dm0644 \
            ${loader.limine.package}/share/limine/${limineEfiFile} \
            "$boot/EFI/BOOT/${limineEfiFile}"
        ''
      else
        ''
          ${pkgs.coreutils}/bin/install -Dm0644 \
            ${loader.limine.package}/share/limine/limine-bios.sys \
            "$boot/limine/limine-bios.sys"
          ${loader.limine.package}/bin/limine bios-install ${lib.escapeShellArg loader.limine.device}
        ''
    }
  '';
in
{
  options.runix.boot.loader = {
    mountPoint = lib.mkOption {
      type = lib.types.strMatching "/.*";
      default = "/boot";
      description = "Boot filesystem mount point below the installation root.";
    };
    timeout = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 5;
      description = "Seconds before the default boot entry is selected.";
    };
    configurationLimit = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Maximum number of system profile generations in the boot menu.";
    };
    grub = {
      enable = lib.mkEnableOption "the GRUB bootloader";
      mode = lib.mkOption {
        type = lib.types.enum [
          "bios"
          "efi"
        ];
        default = if pkgs.stdenv.hostPlatform.isx86 then "bios" else "efi";
        description = "Firmware mode for the GRUB installation.";
      };
      device = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "/dev/disk/by-id/REPLACE-ME";
        description = "Whole disk on which to install BIOS GRUB.";
      };
      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Additional GRUB commands before the Runix entry.";
      };
      extraEntries = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Additional GRUB menu entries.";
      };
    };

    limine = {
      enable = lib.mkEnableOption "the Limine bootloader";
      mode = lib.mkOption {
        type = lib.types.enum [
          "bios"
          "efi"
        ];
        default = if pkgs.stdenv.hostPlatform.isx86 then "bios" else "efi";
        description = "Firmware mode for the Limine installation.";
      };
      device = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "/dev/disk/by-id/REPLACE-ME";
        description = "Whole disk on which to install BIOS Limine.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.limine;
        description = "Limine package containing host tools and boot files.";
      };
      editorEnabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the Limine boot-entry editor is available.";
      };
      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Additional global Limine configuration.";
      };
      extraEntries = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Additional Limine menu entries.";
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = !(grubEnabled && limineEnabled);
        message = "runix supports only one enabled bootloader at a time";
      }
      {
        assertion = !grubEnabled || loader.grub.mode != "bios" || loader.grub.device != "";
        message = "runix.boot.loader.grub.device is required for a BIOS installation";
      }
      {
        assertion = !limineEnabled || loader.limine.mode != "bios" || loader.limine.device != "";
        message = "runix.boot.loader.limine.device is required for a BIOS installation";
      }
      {
        assertion = !grubEnabled || loader.grub.mode != "bios" || pkgs.stdenv.hostPlatform.isx86;
        message = "GRUB BIOS installation is supported only on x86";
      }
      {
        assertion = !limineEnabled || loader.limine.mode != "bios" || pkgs.stdenv.hostPlatform.isx86;
        message = "Limine BIOS installation is supported only on x86";
      }
      {
        assertion =
          selectedLoader == null || (pkgs.stdenv.hostPlatform.isx86_64 || pkgs.stdenv.hostPlatform.isAarch64);
        message = "Runix bootloader installation supports x86_64 and aarch64 systems";
      }
    ];

    runix.build = lib.optionalAttrs (selectedLoader != null) {
      bootLoader = selectedLoader;
      installBootLoader = if grubEnabled then grubInstaller else limineInstaller;
    };
  };
}
