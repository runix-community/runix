{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.mdevd;
  groups = config.runix.build.normalizedGroups;
  gid = name: toString groups.${name}.gid;
  diskScript = pkgs.writeScript "runix-mdevd-disk" ''
    #!/bin/sh
    export PATH=/bin:/sbin:/run/current-system/sw/bin
    case "$MDEV" in ""|/*|*..*) exit 1 ;; esac
    # Remove only links belonging to this device.
    for link in /dev/disk/by-uuid/* /dev/disk/by-label/* /dev/disk/by-partuuid/* /dev/disk/by-partlabel/*; do
      [ -L "$link" ] || continue
      [ "$(readlink "$link")" != "/dev/$MDEV" ] || rm -f -- "$link"
    done
    case "''${ACTION:-add}" in
      add|change)
        runix-blkid -o export "/dev/$MDEV" 2>/dev/null |
          while IFS='=' read -r key value; do
            case "$key" in
              UUID) dir=by-uuid ;;
              LABEL) dir=by-label ;;
              PARTUUID) dir=by-partuuid ;;
              PARTLABEL) dir=by-partlabel ;;
              *) continue ;;
            esac
            case "$value" in ""|.|..|*/*) continue ;; esac
            mkdir -p "/dev/disk/$dir"
            ln -sfnT "/dev/$MDEV" "/dev/disk/$dir/$value"
          done
        ;;
    esac
  '';
  helpers = pkgs.runCommand "runix-mdevd-tools" { } ''
    mkdir -p "$out/bin"
    ln -s ${diskScript} "$out/bin/runix-mdevd-disk"
    ln -s ${pkgs.util-linux}/bin/blkid "$out/bin/runix-blkid"
  '';
  rules = pkgs.writeText "runix-mdev.conf" ''
    -$MODALIAS=.* 0:0 660 @${pkgs.kmod}/bin/modprobe -q "$MODALIAS"
    -SUBSYSTEM=block;.* 0:${gid "disk"} 660 *${diskScript}
    null 0:0 666
    zero 0:0 666
    full 0:0 666
    random 0:0 444
    urandom 0:0 444
    hwrandom 0:0 444
    ptmx 0:${gid "tty"} 666
    tty 0:${gid "tty"} 666
    tty[0-9]+ 0:${gid "tty"} 660
    ttyS[0-9]+ 0:${gid "tty"} 660
    ${cfg.rules}
    SUBSYSTEM=sound;.* 0:${gid "audio"} 660
    SUBSYSTEM=drm;dri/card[0-9]+ 0:${gid "video"} 660
    SUBSYSTEM=drm;dri/renderD[0-9]+ 0:${gid "render"} 660
    SUBSYSTEM=input;.* 0:${gid "input"} 660
  '';
in
{
  options.services.mdevd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to run mdevd for device event management.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.mdevd;
      description = "mdevd package.";
    };
    rules = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Additional native mdevd rules.";
    };
  };

  config = {
    runix.groups = {
      tty.gid = lib.mkDefault 5;
      disk.gid = lib.mkDefault 6;
      audio.gid = lib.mkDefault 29;
      video.gid = lib.mkDefault 26;
      input.gid = lib.mkDefault 174;
      render.gid = lib.mkDefault 303;
    };
    runix.packages = lib.optionals cfg.enable [
      cfg.package
      helpers
      pkgs.libudev-zero
    ];
    runix.preparationScripts = [ "ln -sfn ${rules} /etc/mdev.conf" ];
    runix.services = lib.mkIf cfg.enable {
      mdevd = {
        script = ''
          rm -f /run/mdevd-ready /run/mdevd-coldplug-ready
          exec ${cfg.package}/bin/mdevd -D 3 -f ${rules} -F /run/current-system/firmware -O 4 3>/run/mdevd-ready
        '';
        check = "test -s /run/mdevd-ready";
        finish = "rm -f /run/mdevd-ready /run/mdevd-coldplug-ready";
        path = [ pkgs.kmod ];
      };
      mdevd-coldplug = {
        script = ''
          rm -f /run/mdevd-coldplug-ready
          while true; do
            if [ -s /run/mdevd-ready ] && [ ! -e /run/mdevd-coldplug-ready ]; then
              ${pkgs.coreutils}/bin/timeout 60 ${cfg.package}/bin/mdevd-coldplug -O 4
              touch /run/mdevd-coldplug-ready
            fi
            ${pkgs.coreutils}/bin/sleep 1
          done
        '';
        after = [ "mdevd" ];
        check = "test -e /run/mdevd-coldplug-ready";
        finish = "rm -f /run/mdevd-coldplug-ready";
      };
    };
    runix.build = {
      mdevConfig = rules;
      mdevDiskScript = diskScript;
      mdevTools = helpers;
    };
  };
}
