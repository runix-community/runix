{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.gpuScreenRecorder;
in
{
  options.programs.gpuScreenRecorder = {
    enable = lib.mkEnableOption "GPU Screen Recorder";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.gpu-screen-recorder;
      description = "GPU Screen Recorder package.";
    };
  };

  config.runix.packages = lib.optional cfg.enable cfg.package;
}
