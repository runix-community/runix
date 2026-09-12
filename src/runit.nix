{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix;

  serviceType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to supervise ${name}.";
        };
        command = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Foreground command.";
        };
        script = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Shell implementation used instead of command.";
        };
        finish = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Shell code run after the service exits.";
        };
        after = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Services that must report up first.";
        };
        check = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Readiness check used by sv check and dependent services.";
        };
        environment = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Environment variables specific to this service.";
        };
        path = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Additional packages added to this service's PATH.";
        };
        workingDirectory = lib.mkOption {
          type = lib.types.nullOr (lib.types.strMatching "/.*");
          default = null;
          description = "Working directory for the service process.";
        };
        user = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "User under which the service process runs.";
        };
        group = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Primary group for the service process; requires user.";
        };
        umask = lib.mkOption {
          type = lib.types.strMatching "[0-7]{3,4}";
          default = "0022";
          description = "File creation mask for the service process.";
        };
        restart = lib.mkOption {
          type = lib.types.enum [
            "always"
            "on-failure"
            "never"
          ];
          default = "always";
          description = "Whether runit restarts the service after it exits.";
        };
        log = lib.mkOption {
          type = lib.types.bool;
          default = name != "console";
          description = "Whether to capture output with svlogd; disabled by default for the console service.";
        };
      };
    }
  );

  services = lib.filterAttrs (_: service: service.enable) cfg.services;
  serviceNames = lib.attrNames services;
  kernelTarget = cfg.kernel.package.target or "bzImage";
  profileVariables = lib.concatMapAttrsStringSep "\n" (
    name: value: "export ${name}=${lib.escapeShellArg value}"
  ) cfg.environmentVariables;
  serviceEnvironment = service: cfg.environmentVariables // service.environment;
  servicePath =
    service:
    lib.concatStringsSep ":" (
      [
        "/run/current-system/sw/bin"
        "/run/current-system/sw/sbin"
      ]
      ++ lib.optional (service.path != [ ]) (lib.makeBinPath service.path)
    );
  serviceIdentity =
    service: service.user + lib.optionalString (service.group != null) ":${service.group}";

  serviceBody =
    name: service:
    pkgs.writeShellScript "runix-service-${name}-body" ''
      set -eu
      ${if service.script != "" then service.script else "exec ${service.command}"}
    '';
  runScript =
    name: service:
    pkgs.writeShellScript "runix-service-${name}" ''
      set -eu
      export PATH=${lib.escapeShellArg (servicePath service)}
      ${lib.optionalString service.log "exec 2>&1"}
      ${lib.concatMapAttrsStringSep "\n" (
        variable: value: "export ${variable}=${lib.escapeShellArg value}"
      ) (serviceEnvironment service)}
      umask ${service.umask}
      ${lib.optionalString (
        service.workingDirectory != null
      ) "cd ${lib.escapeShellArg service.workingDirectory}"}
      ${lib.concatMapStringsSep "\n" (dependency: ''
        ${cfg.runit.package}/bin/sv -w ${toString cfg.runit.serviceTimeout} check ${lib.escapeShellArg "/run/runit/service/${dependency}"} >/dev/null 2>&1
      '') service.after}
      exec ${lib.optionalString (name == "console") "${pkgs.util-linux}/bin/setsid --fork --wait "}${
        lib.optionalString (
          service.user != null
        ) "${cfg.runit.package}/bin/chpst -u ${lib.escapeShellArg (serviceIdentity service)} "
      }${serviceBody name service}
    '';
  checkScript =
    name: service:
    pkgs.writeShellScript "runix-service-${name}-check" ''
      export PATH=${lib.escapeShellArg (servicePath service)}
      ${lib.concatMapAttrsStringSep "\n" (
        variable: value: "export ${variable}=${lib.escapeShellArg value}"
      ) (serviceEnvironment service)}
      ${lib.optionalString (
        service.workingDirectory != null
      ) "cd ${lib.escapeShellArg service.workingDirectory}"}
      ${service.check}
    '';
  finishScript =
    name: service:
    pkgs.writeShellScript "runix-service-${name}-finish" ''
      export PATH=${lib.escapeShellArg (servicePath service)}
      ${service.finish}
      ${lib.optionalString (service.restart == "never") "printf d > supervise/control"}
      ${lib.optionalString (service.restart == "on-failure") ''
        if [ "''${1:-0}" -eq 0 ]; then
          printf d > supervise/control
        fi
      ''}
    '';
  logScript =
    name:
    pkgs.writeShellScript "runix-service-${name}-log" ''
      ${pkgs.coreutils}/bin/mkdir -p /var/log/runit/${lib.escapeShellArg name}
      exec ${cfg.runit.package}/bin/svlogd -tt /var/log/runit/${lib.escapeShellArg name}
    '';

  serviceTree = pkgs.runCommand "runix-service-tree" { } (
    ''
      mkdir -p "$out"
    ''
    + lib.concatMapAttrsStringSep "\n" (
      name: service:
      ''
        mkdir -p "$out/${name}"
        ln -s ${runScript name service} "$out/${name}/run"
        printf '%s\n' ${lib.escapeShellArg (toString (runScript name service))} > "$out/${name}/revision"
      ''
      + lib.optionalString (service.check != "") ''
        ln -s ${checkScript name service} "$out/${name}/check"
        printf '%s\n' ${lib.escapeShellArg (toString (checkScript name service))} >> "$out/${name}/revision"
      ''
      + lib.optionalString (service.finish != "" || service.restart != "always") ''
        ln -s ${finishScript name service} "$out/${name}/finish"
        printf '%s\n' ${lib.escapeShellArg (toString (finishScript name service))} >> "$out/${name}/revision"
      ''
      + lib.optionalString service.log ''
        mkdir -p "$out/${name}/log"
        ln -s ${logScript name} "$out/${name}/log/run"
        printf '%s\n' ${lib.escapeShellArg (toString (logScript name))} >> "$out/${name}/revision"
      ''
    ) services
  );

  stage1 = pkgs.writeShellScript "runix-stage-1" ''
    set -eu
    init="$(${pkgs.coreutils}/bin/tr '\0' '\n' </proc/1/cmdline | ${pkgs.gnused}/bin/sed -n '1p')"
    system="''${init%/*}"
    "$system/activate"
  '';

  stage2 = pkgs.writeShellScript "runix-stage-2" ''
    export PATH=${cfg.runit.package}/bin
    ${pkgs.coreutils}/bin/rm -f /run/runit/stop
    ${pkgs.coreutils}/bin/mkdir -p /var/log/runit
    ${cfg.runit.package}/bin/runsvdir /run/runit/service >>/var/log/runit/runsvdir.log 2>&1 &
    supervisor="$!"
    trap 'kill -TERM "$supervisor" 2>/dev/null || true; wait "$supervisor" 2>/dev/null || true; exit 0' TERM
    while [ ! -e /run/runit/stop ]; do
      ${pkgs.coreutils}/bin/sleep 0.1
    done
    kill -TERM "$supervisor" 2>/dev/null || true
    wait "$supervisor" 2>/dev/null || true
  '';

  stage3 = pkgs.writeShellScript "runix-stage-3" ''
    for service in /run/runit/service/*; do
      [ -d "$service" ] || continue
      ${cfg.runit.package}/bin/sv -w ${toString cfg.runit.serviceTimeout} force-stop "$service" || true
      ${cfg.runit.package}/bin/sv exit "$service" || true
    done
    ${lib.concatStringsSep "\n" cfg.shutdownScripts}
    ${pkgs.coreutils}/bin/sync
  '';

  verifyServices = pkgs.writeShellScript "runix-verify-services" ''
    set -eu
    ${lib.concatMapStringsSep "\n" (name: ''
      if ! output="$(${cfg.runit.package}/bin/sv -w ${toString cfg.runit.serviceTimeout} check ${
        lib.escapeShellArg "/run/runit/service/${name}"
      } 2>&1)"; then
        echo "runix: service ${name} failed its readiness check" >&2
        printf '%s\n' "$output" >&2
        exit 1
      fi
    '') serviceNames}
  '';

  etcTree = pkgs.runCommand "runix-etc" { } ''
    mkdir -p "$out/runit" "$out/profile.d"
    ln -s ${stage1} "$out/runit/1"
    ln -s ${stage2} "$out/runit/2"
    ln -s ${stage3} "$out/runit/3"
    touch "$out/runit/stopit" "$out/runit/reboot"
    printf '%s\n' ${lib.escapeShellArg cfg.hostName} > "$out/hostname"
    printf '%s\n' ${lib.escapeShellArg cfg.build.passwd} > "$out/passwd"
    printf '%s\n' ${lib.escapeShellArg cfg.build.shadow} > "$out/shadow"
    printf '%s\n' ${lib.escapeShellArg cfg.build.group} > "$out/group"
    printf '%s\n' ${lib.escapeShellArg cfg.build.gshadow} > "$out/gshadow"
    printf '127.0.0.1 localhost\n127.0.1.1 %s\n' ${lib.escapeShellArg cfg.hostName} > "$out/hosts"
    printf 'nameserver 1.1.1.1\n' > "$out/resolv.conf"
    cp ${cfg.build.fstab} "$out/fstab"
    printf '%s\n' ${lib.escapeShellArg ''
      export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/run/current-system/sw/sbin
      ${profileVariables}
    ''} > "$out/profile"
  '';

  activation = pkgs.writeShellScript "runix-activate" ''
    set -eu
    umask 0022
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
      ]
    }
    export RUNIX_OFFLINE=0
    case "''${1-}" in
      --offline) RUNIX_OFFLINE=1 ;;
      "") ;;
      *) echo "usage: activate [--offline]" >&2; exit 2 ;;
    esac
    system="$(readlink -f "''${0%/*}")"
    mkdir -p /bin /dev /home /lib /proc /root /run/runit /sys /tmp /usr/bin /var/log/runit
    if [ -e /var/run ] && [ ! -L /var/run ] && [ ! -d /run/runit/service ]; then
      rm -rf /var/run
    fi
    if [ ! -e /var/run ]; then
      ln -s /run /var/run
    fi
    chmod 1777 /tmp
    ${pkgs.bash}/bin/bash ${./activate-etc.sh} ${etcTree} / ${
      if config.fileSystems == { } then "1" else "0"
    }
    ln -sfn ${cfg.build.modulesTree}/lib/modules /lib/modules
    ln -sfn "$system" /run/current-system
    if [ "$RUNIX_OFFLINE" = 0 ]; then
      printf '%s\n' ${lib.escapeShellArg "${pkgs.kmod}/bin/modprobe"} > /proc/sys/kernel/modprobe
      if [ -w /sys/module/firmware_class/parameters/path ]; then
        printf '%s' ${cfg.build.firmware}/lib/firmware > /sys/module/firmware_class/parameters/path
      fi
      ${lib.concatMapStringsSep "\n" (
        module: "${pkgs.kmod}/bin/modprobe ${lib.escapeShellArg module}"
      ) cfg.kernel.modules}
      ${pkgs.util-linux}/bin/mount -a
    fi
    chmod 0000 /etc/runit/stopit /etc/runit/reboot
    chmod 0600 /etc/shadow /etc/gshadow
    ${lib.concatMapAttrsStringSep "\n" (
      name: user:
      lib.optionalString (user.passwordHashFile != null) ''
        hash_file=${lib.escapeShellArg user.passwordHashFile}
        if [ -r "$hash_file" ]; then
          hash="$(cat "$hash_file")"
          case "$hash" in
            ""|*:*|*$'\n'*) echo "runix: invalid password hash file for ${name}" >&2; exit 1 ;;
          esac
          shadow=$(mktemp /etc/.shadow.XXXXXX)
          while IFS=: read -r account old_hash rest; do
            if [ "$account" = ${lib.escapeShellArg name} ]; then old_hash="$hash"; fi
            printf '%s:%s:%s\n' "$account" "$old_hash" "$rest"
          done < /etc/shadow > "$shadow"
          mv -f "$shadow" /etc/shadow
        else
          echo "runix: missing password hash file for ${name}: $hash_file" >&2
          exit 1
        fi
      ''
    ) cfg.build.normalizedUsers}
    ln -sfn ${pkgs.bashInteractive}/bin/bash /bin/sh
    ln -sfn ${pkgs.coreutils}/bin/env /usr/bin/env

    ${lib.concatMapAttrsStringSep "\n" (_: user: ''
      mkdir -p ${lib.escapeShellArg user.home}
      ${lib.optionalString (user.home != "/var/empty") ''
        chown ${toString user.uid}:${toString user.gid} ${lib.escapeShellArg user.home}
      ''}
      ${lib.optionalString
        (user.uid >= 1000 && user.home != "/var/empty" && !cfg.systemServices.elogind.enable)
        ''
          mkdir -p /run/user/${toString user.uid}
          chown ${toString user.uid}:${toString user.gid} /run/user/${toString user.uid}
          chmod 0700 /run/user/${toString user.uid}
        ''
      }
    '') cfg.build.normalizedUsers}
    mkdir -p /var/empty
    chown 0:0 /var/empty
    chmod 0755 /var/empty

    ${lib.concatStringsSep "\n" cfg.preparationScripts}
    # Never change the live kernel or services during offline installation.
    [ "$RUNIX_OFFLINE" = 0 ] || exit 0
    ${pkgs.busybox}/bin/hostname ${lib.escapeShellArg cfg.hostName}
    ${lib.concatStringsSep "\n" cfg.activationScripts}

    source=${serviceTree}
    target=/run/runit/service
    mkdir -p "$target"
    stop_service() {
      service="$1"
      if [ -d "$service/supervise" ]; then
        ${cfg.runit.package}/bin/sv -w ${toString cfg.runit.serviceTimeout} force-stop "$service" >/dev/null 2>&1 || true
        ${cfg.runit.package}/bin/sv exit "$service" >/dev/null 2>&1 || true
      fi
      if [ -d "$service/log/supervise" ]; then
        ${cfg.runit.package}/bin/sv -w ${toString cfg.runit.serviceTimeout} force-stop "$service/log" >/dev/null 2>&1 || true
        ${cfg.runit.package}/bin/sv exit "$service/log" >/dev/null 2>&1 || true
      fi
    }
    for current in "$target"/*; do
      [ -e "$current" ] || continue
      name="''${current##*/}"
      if [ ! -d "$source/$name" ]; then
        stop_service "$current"
        rm -rf "$current"
      fi
    done
    for definition in "$source"/*; do
      [ -d "$definition" ] || continue
      name="''${definition##*/}"
      current="$target/$name"
      if [ -f "$current/revision" ] && ${pkgs.diffutils}/bin/cmp -s "$definition/revision" "$current/revision"; then
        continue
      fi
      # Never tear down the active login session. The new console definition is
      # installed on the next boot, before runsvdir starts supervising services.
      if [ "$name" = console ] && [ -d "$current/supervise" ]; then
        continue
      fi
      stop_service "$current"
      rm -rf "$current"
      mkdir -p "$current"
      cp -RP "$definition"/. "$current"/
    done
    touch "$target"
    for definition in "$source"/*; do
      [ -d "$definition" ] || continue
      name="''${definition##*/}"
      current="$target/$name"
      tries=0
      while [ ! -e "$current/supervise/ok" ]; do
        tries=$((tries + 1))
        [ "$tries" -lt ${toString (cfg.runit.serviceTimeout * 10)} ] || {
          echo "runix: runsvdir did not supervise $name" >&2
          exit 1
        }
        ${pkgs.coreutils}/bin/sleep 0.1
      done
    done

  '';

  powerCommands = pkgs.runCommand "runix-power-commands" { } ''
    mkdir -p "$out/bin"
    for name in halt poweroff; do
      ln -s ${pkgs.writeShellScript "runix-poweroff" ''
        ${pkgs.coreutils}/bin/chmod 0000 /etc/runit/reboot
        ${pkgs.coreutils}/bin/touch /run/runit/stop
      ''} "$out/bin/$name"
    done
    ln -s ${pkgs.writeShellScript "runix-reboot" ''
      ${pkgs.coreutils}/bin/chmod 0100 /etc/runit/reboot
      ${pkgs.coreutils}/bin/touch /run/runit/stop
    ''} "$out/bin/reboot"
    ln -s ${pkgs.writeShellScript "runix-init" ''
      case "''${1-}" in
        0) exec /run/current-system/bin/poweroff ;;
        6) exec /run/current-system/bin/reboot ;;
        *) echo "usage: init 0|6" >&2; exit 1 ;;
      esac
    ''} "$out/bin/init"
  '';

  system = pkgs.runCommand "runix-system" { } ''
    mkdir -p "$out/bin"
    ln -s ${
      pkgs.writeText "runix-install-spec.json" (
        builtins.toJSON {
          system = pkgs.stdenv.hostPlatform.system;
          hostName = cfg.hostName;
          fileSystems = config.fileSystems;
          passwordHashFiles = lib.filter (path: path != null) (
            map (user: user.passwordHashFile) (lib.attrValues cfg.build.normalizedUsers)
          );
          bootLoader = {
            enabled = cfg.boot.loader.grub.enable || cfg.boot.loader.limine.enable;
            mode =
              if cfg.boot.loader.grub.enable then cfg.boot.loader.grub.mode else cfg.boot.loader.limine.mode;
            mountPoint = cfg.boot.loader.mountPoint;
          };
        }
      )
    } "$out/install-spec.json"
    printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " cfg.kernel.parameters)} > "$out/kernel-params"
    printf '%s\n' ${
      lib.escapeShellArg (
        if config.fileSystems ? "/" then
          let
            root = config.fileSystems."/";
          in
          "root=${root.device} rootfstype=${root.fsType} rootflags=${lib.concatStringsSep "," root.options}"
        else
          ""
      )
    } > "$out/root-params"
    ln -s ${cfg.runit.package}/bin/runit "$out/init"
    ln -s ${cfg.kernel.package}/${kernelTarget} "$out/kernel"
    ln -s ${cfg.build.initrd}/initrd "$out/initrd"
    ln -s ${cfg.build.firmware}/lib/firmware "$out/firmware"
    ln -s ${cfg.build.environment} "$out/sw"
    ln -s ${cfg.build.packageManifest} "$out/package-manifest.json"
    ln -s ${activation} "$out/activate"
    ln -s ${verifyServices} "$out/verify-services"
    ln -s ${powerCommands}/bin/* "$out/bin/"
  '';
in
{
  options.runix = {
    runit = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ../pkgs/runit { };
        description = "Runit package used as PID 1.";
      };
      serviceTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Seconds allowed for service state transitions.";
      };
    };

    services = lib.mkOption {
      type = lib.types.attrsOf serviceType;
      default = { };
      description = "Foreground processes supervised by runit.";
    };
  };

  config = {
    assertions =
      lib.concatLists (
        lib.mapAttrsToList (name: service: [
          {
            assertion = (service.command != null) != (service.script != "");
            message = "runix service ${name} must define exactly one of command or script";
          }
          {
            assertion = service.group == null || service.user != null;
            message = "runix service ${name} cannot set group without user";
          }
          {
            assertion = service.user == null || builtins.hasAttr service.user cfg.build.normalizedUsers;
            message = "runix service ${name} references an unknown user";
          }
          {
            assertion = service.group == null || builtins.hasAttr service.group cfg.build.normalizedGroups;
            message = "runix service ${name} references an unknown group";
          }
        ]) services
      )
      ++ lib.concatLists (
        lib.mapAttrsToList (
          name: service:
          map (dependency: {
            assertion = lib.elem dependency serviceNames;
            message = "runix service ${name} depends on unknown service ${dependency}";
          }) service.after
        ) services
      );

    runix.packages = lib.mkBefore [ powerCommands ];
    runix.environmentVariables.SVDIR = lib.mkDefault "/run/runit/service";
    runix.build = {
      inherit
        activation
        etcTree
        serviceTree
        system
        verifyServices
        ;
    };
  };
}
