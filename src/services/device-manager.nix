{
  config,
  lib,
  ...
}:
{
  options.runix.systemServices.deviceManager.enable =
    lib.mkEnableOption "mdevd device event handling";
  config = lib.mkIf config.runix.systemServices.deviceManager.enable {
    services.mdevd.enable = true;
  };
}
