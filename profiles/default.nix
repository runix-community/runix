# The installer's desktop choices, as modules on top of base.nix.
{ }:
let
  desktop = extra: {
    runix.desktop.enable = true;
    programs.firefox.enable = true;
  } // extra;
  only = program: desktop {
    programs.hyprland.enable = false;
    programs.${program}.enable = true;
  };
  blxshell = extra: { pkgs, ... }: {
    imports = [ (desktop extra) ];
    programs.blxshell = {
      enable = true;
      greeter = {
        enable = true;
        syncUser = "runix";
        zwwmPackage = pkgs.zwwm;
      };
    };
  };
in
{
  console = { };
  hyprland = desktop { };
  labwc = only "labwc";
  niri = only "niri";
  zwwm = only "zwwm";
  blxshell-zwwm = blxshell {
    programs.hyprland.enable = false;
    programs.zwwm.enable = true;
  };
  # The greeter runs in zwwm even when the desktop is Hyprland.
  blxshell-hyprland = blxshell { };
}
