{ config, lib, ... }:
{
  options.runix.wayland = {
    enable = lib.mkEnableOption "shared Wayland compositor infrastructure";
    sessionPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Compositors from outside Runix whose share/wayland-sessions entries the login screen offers; runix.lib.mkProgram adds to it.";
    };
  };

  config = lib.mkIf config.runix.wayland.enable {
    hardware.graphics.enable = lib.mkDefault true;
    hardware.input.enable = lib.mkDefault true;
    services.pipewire.enable = lib.mkDefault true;
    runix.systemServices = {
      dbus.enable = lib.mkDefault true;
      elogind.enable = lib.mkDefault true;
      seatd.enable = lib.mkDefault true;
    };
    runix.environmentVariables = {
      LIBSEAT_BACKEND = lib.mkDefault "seatd";
      XDG_SESSION_TYPE = lib.mkDefault "wayland";
    };
  };
}
