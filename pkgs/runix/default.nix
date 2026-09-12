{
  coreutils,
  inetutils,
  lib,
  nix,
  sudo,
  writeShellApplication,
}:
writeShellApplication {
  name = "runix-rebuild";
  runtimeInputs = [
    coreutils
    inetutils
    nix
  ];
  text = ''
    usage() {
      cat <<'EOF'
    Usage: runix-rebuild ACTION [OPTIONS] [-- NIX_OPTIONS...]

    Actions:
      build                 Build the system and create ./result
      dry-build             Show what building the system would do
      switch                Build, register, activate, and update the bootloader
      boot                  Build, register, and update the bootloader
      test                  Build and activate without creating a generation
      rollback [switch|boot]
                            Select and optionally activate the previous generation
      bootloader [ROOT]     Refresh the configured bootloader (ROOT defaults to /)
      list-generations      List registered system generations
      delete-generations GENERATION...
                            Delete profile generations and collect their unused store paths

    Options:
      --flake PATH[#HOST]   Flake and runixConfigurations host to use
      --host HOST           Host name when --flake has no #HOST fragment
      -h, --help            Show this help

    The default flake is the current directory when it contains flake.nix,
    otherwise /etc/runix. The default host is the current hostname.
    Arguments after -- are passed to nix build.
    EOF
    }

    die() {
      echo "runix-rebuild: $*" >&2
      exit 2
    }

    as_root() {
      if [ "$(id -u)" -eq 0 ]; then
        "$@"
      elif [ -x /run/wrappers/bin/sudo ]; then
        /run/wrappers/bin/sudo "$@"
      else
        ${lib.getExe sudo} "$@"
      fi
    }

    action="''${1:-}"
    [ -n "$action" ] || { usage >&2; exit 2; }
    shift

    case "$action" in
      -h|--help|help)
        usage
        exit 0
        ;;
      build|dry-build|switch|boot|test|rollback|bootloader|list-generations|delete-generations) ;;
      *) die "unknown action: $action" ;;
    esac

    if [ -e ./flake.nix ]; then
      flake=.
    else
      flake=/etc/runix
    fi
    host="$(hostname)"
    declare -a action_args=()
    declare -a nix_args=()

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --flake)
          [ "$#" -ge 2 ] || die "--flake requires PATH[#HOST]"
          flake="$2"
          shift 2
          ;;
        --flake=*)
          flake="''${1#--flake=}"
          shift
          ;;
        --host)
          [ "$#" -ge 2 ] || die "--host requires a host name"
          host="$2"
          shift 2
          ;;
        --host=*)
          host="''${1#--host=}"
          shift
          ;;
        --)
          shift
          nix_args+=("$@")
          break
          ;;
        *)
          action_args+=("$1")
          shift
          ;;
      esac
    done

    case "$flake" in
      *#*)
        host="''${flake#*#}"
        flake="''${flake%%#*}"
        [ -n "$host" ] || die "empty host in --flake"
        ;;
    esac
    [ -n "$host" ] || die "could not determine the host name; pass --host"

    configuration="$flake#runixConfigurations.$host.config.runix.build"
    profile=/nix/var/nix/profiles/system

    build_path() {
      nix build --no-link --print-out-paths "$configuration.$1" "''${nix_args[@]}"
    }

    case "$action" in
      build)
        [ "''${#action_args[@]}" -eq 0 ] || die "build takes no positional arguments"
        nix build "$configuration.system" "''${nix_args[@]}"
        ;;
      dry-build)
        [ "''${#action_args[@]}" -eq 0 ] || die "dry-build takes no positional arguments"
        nix build --dry-run "$configuration.system" "''${nix_args[@]}"
        ;;
      switch|boot|test)
        [ "''${#action_args[@]}" -eq 0 ] || die "$action takes no positional arguments"
        switch_script="$(build_path switchToConfiguration)"
        [ "$action" != switch ] || printf 'runix-rebuild: rebuilding %s\n' "$host"
        as_root "$switch_script" "$action"
        ;;
      rollback)
        [ "''${#action_args[@]}" -le 1 ] || die "rollback accepts only switch or boot"
        rollback_action="''${action_args[0]:-switch}"
        case "$rollback_action" in
          switch|boot) ;;
          *) die "rollback accepts only switch or boot" ;;
        esac
        rollback_script="$(build_path rollback)"
        as_root "$rollback_script" "$rollback_action"
        ;;
      bootloader)
        [ "''${#action_args[@]}" -le 1 ] || die "bootloader accepts at most one installation root"
        root="''${action_args[0]:-/}"
        installer="$(build_path installBootLoader)"
        as_root "$installer" "$root"
        ;;
      list-generations)
        [ "''${#action_args[@]}" -eq 0 ] || die "list-generations takes no positional arguments"
        current="$(readlink "$profile" 2>/dev/null || true)"
        for link in "''${profile%/*}/''${profile##*/}-"*-link; do
          [ -L "$link" ] || continue
          generation="''${link##*/system-}"
          generation="''${generation%-link}"
          created="$(stat -c '%y' "$link")"
          created="''${created%%.*}"
          marker=""
          [ "''${link##*/}" != "$current" ] || marker="(current)"
          printf '%5s   %s   %s\n' "$generation" "$created" "$marker"
        done
        ;;
      delete-generations)
        [ "''${#action_args[@]}" -gt 0 ] || die "delete-generations requires at least one generation"
        as_root nix-env --option build-users-group "" --profile "$profile" --delete-generations "''${action_args[@]}"
        as_root nix-store --gc
        ;;
    esac
  '';

  meta = {
    description = "Build, activate, and manage Runix systems";
    license = lib.licenses.bsd3;
    mainProgram = "runix-rebuild";
    platforms = lib.platforms.linux;
  };
}
