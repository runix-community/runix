# A Runix module. Import it from a Runix flake:
#
#   modules = [
#     inputs.hello.runixModules.default
#     { services.hello.enable = true; }
#   ];
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hello;
in
{
  options.services.hello = {
    enable = lib.mkEnableOption "the hello service";
    greeting = lib.mkOption {
      type = lib.types.str;
      default = "Hello from a flake";
      description = "What the service prints every minute.";
    };
  };

  config = lib.mkIf cfg.enable {
    # runit supervises this; see runix.services in Runix's src/runit.nix for
    # every option (user, environment, path, check, after, restart, log).
    runix.services.hello = {
      script = ''
        while true; do
          echo ${lib.escapeShellArg cfg.greeting}
          sleep 60
        done
      '';
      path = [ pkgs.coreutils ];
    };
  };
}
