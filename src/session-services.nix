{
  config,
  lib,
  pkgs,
  ...
}:
let
  pipewire = config.services.pipewire;
  runit = config.runix.runit.package;
  desktopPackages = import ../pkgs/desktop.nix { inherit pkgs; };

  pipewireRun = pkgs.writeShellScript "runix-user-pipewire" ''
    exec ${pipewire.package}/bin/pipewire
  '';
  pulseRun = pkgs.writeShellScript "runix-user-pipewire-pulse" ''
    ${runit}/bin/sv -w ${toString config.runix.runit.serviceTimeout} check ../pipewire
    exec ${pipewire.package}/bin/pipewire-pulse
  '';
  wireplumberRun = pkgs.writeShellScript "runix-user-wireplumber" ''
    ${runit}/bin/sv -w ${toString config.runix.runit.serviceTimeout} check ../pipewire
    exec ${pipewire.wireplumber.package}/bin/wireplumber
  '';

  pipewireServiceTree = pkgs.runCommand "runix-user-pipewire-services" { } ''
    mkdir -p "$out/pipewire"
    ln -s ${pipewireRun} "$out/pipewire/run"
    ${lib.optionalString pipewire.pulse.enable ''
      mkdir -p "$out/pipewire-pulse"
      ln -s ${pulseRun} "$out/pipewire-pulse/run"
    ''}
    ${lib.optionalString pipewire.wireplumber.enable ''
      mkdir -p "$out/wireplumber"
      ln -s ${wireplumberRun} "$out/wireplumber/run"
    ''}
  '';

  pipewireSession = pkgs.writeShellScript "runix-pipewire-session" ''
    set -eu
    if [ -z "''${XDG_RUNTIME_DIR:-}" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then
      echo "runix: XDG_RUNTIME_DIR is unavailable" >&2
      exit 1
    fi

    export PIPEWIRE_RUNTIME_DIR="$XDG_RUNTIME_DIR"
    services="$(${pkgs.coreutils}/bin/mktemp -d "$XDG_RUNTIME_DIR/runix-audio.XXXXXX")"
    ${pkgs.coreutils}/bin/cp -RP ${pipewireServiceTree}/. "$services"/

    ${runit}/bin/runsvdir "$services" &
    supervisor=$!
    cleanup() {
      for service in "$services"/*; do
        [ -d "$service" ] || continue
        ${runit}/bin/sv -w ${toString config.runix.runit.serviceTimeout} force-stop "$service" || true
        ${runit}/bin/sv exit "$service" || true
      done
      kill -TERM "$supervisor" 2>/dev/null || true
      wait "$supervisor" 2>/dev/null || true
      ${pkgs.coreutils}/bin/rm -rf "$services"
    }
    trap cleanup EXIT INT TERM
    wait "$supervisor"
  '';
  audioCommand = pkgs.writeShellApplication {
    name = "runix-audio";
    text = ''
      if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        exec ${pkgs.dbus}/bin/dbus-run-session -- ${pipewireSession}
      fi
      exec ${pipewireSession}
    '';
  };
in
{
  options.services = {
    pipewire = {
      enable = lib.mkEnableOption "per-user PipeWire managed by runit";
      package = lib.mkOption {
        type = lib.types.package;
        default = desktopPackages.pipewire;
        description = "PipeWire package.";
      };
      pulse.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to supervise the PipeWire Pulse server.";
      };
      wireplumber = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to supervise WirePlumber.";
        };
        package = lib.mkOption {
          type = lib.types.package;
          default = desktopPackages.wireplumber;
          description = "WirePlumber package.";
        };
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf pipewire.enable {
      assertions = [
        {
          assertion = config.runix.systemServices.dbus.enable;
          message = "services.pipewire requires runix.systemServices.dbus for realtime policy and session clients";
        }
        {
          assertion = config.services.mdevd.enable;
          message = "services.pipewire requires services.mdevd for audio device discovery";
        }
      ];
      runix.groups.rtkit.gid = 133;
      runix.users.rtkit = {
        uid = 133;
        gid = 133;
        home = "/var/lib/rtkit";
        shell = "/bin/false";
      };
      runix.packages = [
        audioCommand
        pipewire.package
        pkgs.rtkit
      ]
      ++ lib.optional pipewire.wireplumber.enable pipewire.wireplumber.package;
      runix.systemServices.dbusPackages = [ pkgs.rtkit ];
      runix.services.rtkit = {
        command = "${pkgs.rtkit}/libexec/rtkit-daemon";
        after = [ "dbus" ];
      };
      runix.build = {
        inherit pipewireServiceTree pipewireSession;
      };
    })
  ];
}
