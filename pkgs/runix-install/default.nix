{
  bash,
  coreutils,
  jq,
  lib,
  nix,
  sudo,
  util-linux,
  writeShellApplication,
}:
writeShellApplication {
  name = "runix-install";
  runtimeInputs = [
    coreutils
    jq
    nix
    util-linux
  ];
  text = ''
    usage() {
      cat <<'EOF'
    Usage: runix-install --flake PATH#HOST [OPTIONS] [-- NIX_OPTIONS...]

    Options:
      --flake PATH#HOST   Required Runix flake configuration
      --root PATH         Mounted target root (default: /mnt)
      --no-activate       Register the generation without activating the target
      --no-bootloader     Do not install or refresh the configured bootloader
      -h, --help          Show this help

    Mount the root and configured persistent filesystems yourself. The command
    never partitions or formats disks. It validates the mounted target, builds
    the selected configuration, prepares it offline, and installs the bootloader.
    Arguments after -- are passed to nix build.
    EOF
    }

    die() {
      echo "runix-install: $*" >&2
      exit 2
    }

    original_args=("$@")
    flake_ref=""
    root=/mnt
    activate=1
    install_bootloader=1
    declare -a nix_args=()

    while [ "$#" -gt 0 ]; do
      case "$1" in
        -h|--help)
          usage
          exit 0
          ;;
        --flake)
          [ "$#" -ge 2 ] || die "--flake requires PATH#HOST"
          flake_ref="$2"
          shift 2
          ;;
        --flake=*)
          flake_ref="''${1#--flake=}"
          shift
          ;;
        --root)
          [ "$#" -ge 2 ] || die "--root requires a path"
          root="$2"
          shift 2
          ;;
        --root=*)
          root="''${1#--root=}"
          shift
          ;;
        --no-activate)
          activate=0
          shift
          ;;
        --no-bootloader)
          install_bootloader=0
          shift
          ;;
        --)
          shift
          nix_args+=("$@")
          break
          ;;
        *) die "unknown argument: $1" ;;
      esac
    done

    [ -n "$flake_ref" ] || die "--flake PATH#HOST is required"
    case "$flake_ref" in
      *#*)
        flake="''${flake_ref%%#*}"
        host="''${flake_ref#*#}"
        ;;
      *) die "--flake must include a #HOST fragment" ;;
    esac
    [ -n "$flake" ] || die "the flake path is empty"
    [ -n "$host" ] || die "the flake host is empty"
    case "$root" in
      /*) ;;
      *) die "--root must be an absolute path" ;;
    esac
    root="$(readlink -m "$root")"
    [ "$root" != / ] || die "refusing to install over the running root"

    if [ "$(id -u)" -ne 0 ]; then
      if [ -x /run/wrappers/bin/sudo ]; then
        exec /run/wrappers/bin/sudo "$0" "''${original_args[@]}"
      else
        exec ${lib.getExe sudo} "$0" "''${original_args[@]}"
      fi
    fi

    ${util-linux}/bin/mountpoint -q "$root" || die "target root is not mounted: $root"
    [ "$(stat -Lc '%d:%i' "$root")" != "$(stat -Lc '%d:%i' /)" ] || die "target is an alias of the running root"
    mkdir -p /run/lock
    exec 9>"/run/lock/runix-install-$(stat -Lc '%d-%i' "$root").lock"
    ${util-linux}/bin/flock -n 9 || die "another installation is already using this target"
    configuration="$flake#runixConfigurations.$host.config.runix.build"
    store="local?root=$root"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    echo "runix-install: building configuration $host"
    system=$(nix build --out-link "$work/system" --print-out-paths "$configuration.system" "''${nix_args[@]}")
    [ -d "$system" ] || die "system build did not produce a directory"
    ${bash}/bin/bash ${./preflight.sh} "$root" "$system/install-spec.json" "$install_bootloader" "$activate"
    if [ "$install_bootloader" -eq 1 ]; then
      echo "runix-install: building the configured bootloader installer"
      installer=$(nix build --out-link "$work/bootloader" --print-out-paths "$configuration.installBootLoader" "''${nix_args[@]}")
    fi

    if [ ! -s "$root/etc/fstab" ]; then
      echo "runix-install: generating /etc/fstab"
      mkdir -p "$root/etc"
      ${bash}/bin/bash ${./fstab.sh} "$root" > "$work/fstab"
      install -m0644 "$work/fstab" "$root/etc/fstab"
    fi

    mkdir -p "$root/nix"
    echo "runix-install: installing the configured system closure"
    nix copy --to "$store" "$system"

    if [ "$activate" -eq 1 ]; then
      echo "runix-install: preparing users, configuration, and service state offline"
      ${util-linux}/bin/unshare --mount --propagation private \
        ${bash}/bin/bash ${./activate-target.sh} "$root" "$system"
      [ -f "$root/etc/passwd" ] && [ -f "$root/etc/nix/nix.conf" ] || die "target configuration is incomplete"
    fi

    echo "runix-install: registering the system generation"
    nix-env \
      --store "$store" \
      --option build-users-group "" \
      --profile /nix/var/nix/profiles/system \
      --set "$system"

    if [ "$install_bootloader" -eq 1 ]; then
      echo "runix-install: installing the bootloader"
      boot=$(jq -r .bootLoader.mountPoint "$system/install-spec.json")
      mkdir -p "$root$boot"
      "$installer" "$root"
    fi

    sync -f "$root"
    echo "runix-install: installation complete"
  '';

  meta = {
    description = "Install a flake-defined Runix system into a mounted target";
    license = lib.licenses.bsd3;
    mainProgram = "runix-install";
    platforms = lib.platforms.linux;
  };
}
