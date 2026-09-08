{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.graphics;
  drivers = pkgs.buildEnv {
    name = "runix-graphics-drivers";
    paths = [ cfg.package ] ++ cfg.extraPackages;
    pathsToLink = [
      "/lib"
      "/share"
    ];
    ignoreCollisions = true;
  };
  rocmEnvironment = pkgs.symlinkJoin {
    name = "runix-rocm";
    paths = cfg.rocmPackages;
  };
in
{
  options.hardware.graphics = {
    enable = lib.mkEnableOption "hardware accelerated graphics";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.mesa;
      description = "Primary OpenGL, EGL, and Vulkan driver package.";
    };
    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Additional graphics, VA-API, VDPAU, OpenCL, or Vulkan driver packages.";
    };
    kernelModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "amdgpu" ];
      description = "Graphics kernel modules loaded after the root filesystem is mounted.";
    };
    initrd = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether graphics modules are copied to and loaded from the initrd for early modesetting.";
      };
      kernelModules = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = cfg.kernelModules;
        description = "Graphics modules used for early modesetting.";
      };
    };
    rocmPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "ROCm packages combined under /opt/rocm.";
    };
  };

  config = lib.mkIf cfg.enable {
    runix.groups = {
      video.gid = lib.mkDefault 26;
      render.gid = lib.mkDefault 303;
    };
    runix.kernel.modules = cfg.kernelModules;
    runix.initrd = lib.mkIf cfg.initrd.enable {
      modules = cfg.initrd.kernelModules;
      loadModules = cfg.initrd.kernelModules;
    };
    runix.packages = [
      drivers
      pkgs.libdrm
      pkgs.vulkan-loader
    ]
    ++ cfg.rocmPackages;
    runix.preparationScripts = [
      ''
        ln -sfn ${drivers} /run/opengl-driver
        ${lib.optionalString (cfg.rocmPackages != [ ]) ''
          mkdir -p /opt
          ln -sfn ${rocmEnvironment} /opt/rocm
        ''}
      ''
    ];
    runix.build.graphicsDrivers = drivers;
  };
}
