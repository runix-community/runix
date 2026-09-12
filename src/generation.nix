{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix;
  hasBootLoader = cfg.boot.loader.grub.enable || cfg.boot.loader.limine.enable;

  transaction = ''
    profile="''${RUNIX_SYSTEM_PROFILE:-/nix/var/nix/profiles/system}"
    ${pkgs.coreutils}/bin/mkdir -p "''${profile%/*}"
    exec 9>"$profile.runix-lock"
    ${pkgs.util-linux}/bin/flock -n 9 || { echo "runix: another generation operation is running" >&2; exit 1; }
    old_profile="$(${pkgs.coreutils}/bin/readlink "$profile" 2>/dev/null || true)"
    old_system="$(${pkgs.coreutils}/bin/readlink -f /run/current-system 2>/dev/null || true)"
    runtime_changed=0
    boot_changed=0

    run_quietly() {
      output="$("$@" 2>&1)" || {
        status="$?"
        printf '%s\n' "$output" >&2
        return "$status"
      }
    }

    current_generation() {
      link="$(${pkgs.coreutils}/bin/readlink "$profile" 2>/dev/null || true)"
      link="''${link##*/}"
      link="''${link#system-}"
      printf '%s\n' "''${link%-link}"
    }

    restore_transaction() {
      status="$1"
      trap - ERR INT TERM
      set +e
      echo "runix: operation failed; restoring the previous generation" >&2
      if [ -n "$old_profile" ]; then
        ${pkgs.coreutils}/bin/ln -sfn "$old_profile" "$profile"
      else
        ${pkgs.coreutils}/bin/rm -f "$profile"
      fi
      if [ "$runtime_changed" = 1 ] && [ -n "$old_system" ] && [ -x "$old_system/activate" ]; then
        "$old_system/activate" || echo "runix: previous generation activation also failed" >&2
      fi
      ${lib.optionalString hasBootLoader ''
        if [ "$boot_changed" = 1 ]; then
          run_quietly ${cfg.build.installBootLoader} / || echo "runix: previous boot menu could not be restored" >&2
        fi
      ''}
      exit "$status"
    }
    trap 'restore_transaction $?' ERR
    trap 'restore_transaction 130' INT
    trap 'restore_transaction 143' TERM
  '';

  switchToConfiguration = pkgs.writeShellScript "runix-switch-to-configuration" ''
    set -Eeuo pipefail
    action="''${1:-switch}"

    case "$action" in
      switch|boot|test) ;;
      *) echo "usage: $0 switch|boot|test" >&2; exit 2 ;;
    esac

    ${transaction}

    if [ "$action" != test ]; then
      ${pkgs.coreutils}/bin/mkdir -p "''${profile%/*}"
      ${pkgs.nix}/bin/nix-env --option build-users-group "" --profile "$profile" --set ${cfg.build.system}
      generation="$(current_generation)"
      echo "runix-switch: registered generation $generation"
    fi
    if [ "$action" != boot ]; then
      runtime_changed=1
      if [ "$action" = test ]; then
        echo "runix-switch: activating test configuration"
      else
        echo "runix-switch: activating generation $generation"
      fi
      ${cfg.build.system}/activate
      ${cfg.build.system}/verify-services
      echo "runix-switch: activation successful"
    fi
    if [ "$action" != test ]; then
      boot_changed=1
      ${lib.optionalString hasBootLoader "run_quietly ${cfg.build.installBootLoader} /"}
      ${lib.optionalString hasBootLoader ''echo "runix-switch: bootloader updated for generation $generation"''}
    fi
    trap - ERR INT TERM
  '';

  rollback = pkgs.writeShellScript "runix-rollback" ''
    set -Eeuo pipefail
    action="''${1:-switch}"
    case "$action" in
      switch|boot) ;;
      *) echo "usage: $0 switch|boot" >&2; exit 2 ;;
    esac

    ${transaction}
    ${pkgs.nix}/bin/nix-env --option build-users-group "" --profile "$profile" --rollback
    system="$(${pkgs.coreutils}/bin/readlink -f "$profile")"
    if [ "$action" = switch ]; then
      runtime_changed=1
      "$system/activate"
      "$system/verify-services"
    fi
    boot_changed=1
    ${lib.optionalString hasBootLoader "run_quietly ${cfg.build.installBootLoader} /"}
    trap - ERR INT TERM
  '';
in
{
  config.runix.build = {
    inherit rollback switchToConfiguration;
  };
}
