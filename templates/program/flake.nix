{
  description = "Programs for Runix, as programs.<name> modules";

  inputs.runix.url = "github:runix-community/runix";

  outputs =
    { runix, ... }:
    {
      # Users add this to their modules, then set programs.foot.enable = true.
      runixModules.default = {
        imports = [
          (runix.lib.mkProgram {
            name = "foot";
            description = "the foot terminal";
            package = pkgs: pkgs.foot;
            extraConfig = cfg: { runix.environmentVariables.TERMINAL = "foot"; };
          })
          # A compositor: its session shows up on the login screen.
          (runix.lib.mkProgram {
            name = "sway";
            description = "the Sway compositor";
            package = pkgs: pkgs.sway;
            session = true;
          })
        ];
      };
    };
}
