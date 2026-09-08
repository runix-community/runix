{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.tmpfiles;
  rulesFile = pkgs.writeText "runix-tmpfiles.conf" (lib.concatStringsSep "\n" cfg.rules + "\n");
  rules = map (rule: {
    inherit rule;
    fields = builtins.match "d +(/[^ ]*) +(-|[0-7]{3,4}) +([^ ]+) +([^ ]+) +- +- *" rule;
  }) (lib.filter (rule: rule != "" && !lib.hasPrefix "#" rule) cfg.rules);
in
{
  options.services.tmpfiles = {
    enable = lib.mkEnableOption "declarative temporary file and directory creation";
    rules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "d /var/cache/example 0750 root root - -" ];
      description = "Native directory rules: d /absolute/path mode user group - -. Other tmpfiles rule types are rejected; no systemd tools are used.";
    };
    cleanOnBoot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether age-based cleanup and removal rules run during activation.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.cleanOnBoot;
        message = "Runix native tmpfiles does not implement age-based cleanup; services.tmpfiles.cleanOnBoot must be false.";
      }
    ]
    ++ map (entry: {
      assertion = entry.fields != null;
      message = "Unsupported Runix tmpfiles rule (expected: d /path mode user group - -): ${entry.rule}";
    }) rules;
    runix.preparationScripts = [
      ''
        mkdir -p /etc/tmpfiles.d
        ln -sfn ${rulesFile} /etc/tmpfiles.d/runix.conf
        ${lib.concatMapStringsSep "\n" (
          entry:
          let
            field = builtins.elemAt entry.fields;
            path = field 0;
            mode = field 1;
            user = field 2;
            group = field 3;
          in
          ''
            (
              path=${lib.escapeShellArg path}
              case "$path" in
                /dev|/dev/*|/proc|/proc/*|/sys|/sys/*)
                  echo "runix: tmpfiles cannot manage kernel/device paths: $path" >&2; exit 1 ;;
              esac
              if [ "$(readlink -m "$path")" != "$path" ]; then
                echo "runix: tmpfiles requires a canonical path without symlinks: $path" >&2
                exit 1
              fi
              mkdir -p "$path"
              ${lib.optionalString (user != "-") "chown ${lib.escapeShellArg user} \"$path\""}
              ${lib.optionalString (group != "-") "chgrp ${lib.escapeShellArg group} \"$path\""}
              ${lib.optionalString (mode != "-") "chmod ${lib.escapeShellArg mode} \"$path\""}
            )
          ''
        ) (lib.filter (entry: entry.fields != null) rules)}
      ''
    ];
  };
}
