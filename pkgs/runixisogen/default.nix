{
  coreutils,
  lib,
  nix,
  writeShellApplication,
}:
writeShellApplication {
  name = "runixisogen";
  runtimeInputs = [
    coreutils
    nix
  ];
  text = ''
    usage() {
      cat <<'EOF'
    Usage: runixisogen [OPTIONS] [-- NIX_OPTIONS...]

    Build a bootable Runix live ISO that starts the TUI installer.

    Options:
      --flake PATH[#HOST]  Flake to build from. Without #HOST, builds its iso
                           package; with #HOST, builds that runixConfigurations
                           host, which must set runix.iso.enable = true
      --output PATH        Where to write the ISO (default: current directory)
      -h, --help           Show this help

    The default flake is the current directory when it contains flake.nix,
    otherwise github:runix-community/runix.
    Arguments after -- are passed to nix build.
    EOF
    }

    die() {
      echo "runixisogen: $*" >&2
      exit 2
    }

    if [ -e ./flake.nix ]; then
      flake=.
    else
      flake=github:runix-community/runix
    fi
    output=.
    declare -a nix_args=()

    while [ "$#" -gt 0 ]; do
      case "$1" in
        -h|--help)
          usage
          exit 0
          ;;
        --flake)
          [ "$#" -ge 2 ] || die "--flake requires PATH[#HOST]"
          flake="$2"
          shift 2
          ;;
        --flake=*)
          flake="''${1#--flake=}"
          shift
          ;;
        --output)
          [ "$#" -ge 2 ] || die "--output requires a path"
          output="$2"
          shift 2
          ;;
        --output=*)
          output="''${1#--output=}"
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

    case "$flake" in
      *#*)
        host="''${flake#*#}"
        flake="''${flake%%#*}"
        [ -n "$host" ] || die "empty host in --flake"
        installable="$flake#runixConfigurations.$host.config.runix.build.iso"
        ;;
      *) installable="$flake#iso" ;;
    esac

    echo "runixisogen: building $installable"
    built="$(nix --extra-experimental-features "nix-command flakes" \
      build --no-link --print-out-paths "$installable" "''${nix_args[@]}")"
    source_iso=""
    for candidate in "$built"/iso/*.iso; do
      [ -f "$candidate" ] || die "the build produced no ISO: $built"
      source_iso="$candidate"
    done

    if [ -d "$output" ]; then
      output="''${output%/}/''${source_iso##*/}"
    fi
    install -m0644 "$source_iso" "$output"
    echo "runixisogen: wrote $output ($(du -h "$output" | cut -f1))"
    sha256sum "$output"
  '';

  meta = {
    description = "Build a bootable Runix live installer ISO";
    license = lib.licenses.bsd3;
    mainProgram = "runixisogen";
    platforms = lib.platforms.linux;
  };
}
