{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.nvidia;
  driver = cfg.package;
  kernelModule = if cfg.open then driver.open else driver.bin;
  # From driver 595 the open modules hear about suspend from the kernel
  # itself; older drivers need nvidia-sleep.sh run around it.
  kernelNotifiers = cfg.open && lib.versionAtLeast driver.version "595";
  sleepHook = cfg.powerManagement && !kernelNotifiers;

  # The driver's character devices. udev rules create them on NixOS; here an
  # mdevd rule runs this when a module loads, and activation runs it once for
  # modules that loaded before mdevd started. Existing nodes are kept.
  deviceNodes = pkgs.writeShellScript "runix-nvidia-devices" ''
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnused pkgs.gawk ]}
    node() { [ -e "$1" ] || mknod -m 0666 "$1" c "$2" "$3"; }
    if [ -d /sys/module/nvidia ]; then
      node /dev/nvidiactl 195 255
      for information in /proc/driver/nvidia/gpus/*/information; do
        [ -r "$information" ] || continue
        minor=$(sed -n 's/^Device Minor: *//p' "$information")
        [ -n "$minor" ] && node "/dev/nvidia$minor" 195 "$minor"
      done
    fi
    [ -d /sys/module/nvidia_modeset ] && node /dev/nvidia-modeset 195 254
    if [ -d /sys/module/nvidia_uvm ]; then
      major=$(awk '$2 == "nvidia-uvm" { print $1 }' /proc/devices)
      if [ -n "$major" ]; then
        node /dev/nvidia-uvm "$major" 0
        node /dev/nvidia-uvm-tools "$major" 1
      fi
    fi
    exit 0
  '';
in
{
  options.hardware.nvidia = {
    enable = lib.mkEnableOption "the NVIDIA proprietary driver";
    package = lib.mkOption {
      type = lib.types.package;
      default = config.runix.kernel.packageSet.nvidiaPackages.stable;
      defaultText = lib.literalExpression "config.runix.kernel.packageSet.nvidiaPackages.stable";
      example = lib.literalExpression "config.runix.kernel.packageSet.nvidiaPackages.legacy_580";
      description = ''
        The driver, from the kernel's package set so it matches the kernel.
        `stable` supports Turing (GTX 16 and RTX 20) and newer; Maxwell,
        Pascal and Volta (GTX 900 and 10) need `legacy_580`, and Kepler
        (GTX 600 and 700) `legacy_470`.
      '';
    };
    open = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to use NVIDIA's open kernel modules instead of the closed
        ones. NVIDIA recommends them for Turing and newer, and Blackwell
        (RTX 50) supports only them; older GPUs need the closed modules.
      '';
    };
    modesetting = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Kernel modesetting (nvidia-drm.modeset=1 and fbdev=1), which Wayland and the console need.";
    };
    earlyModesetting = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to load the driver in the initrd, for a native-resolution console from early boot. The initrd grows by the driver's size.";
    };
    powerManagement = lib.mkOption {
      type = lib.types.bool;
      default = (cfg.open && lib.versionAtLeast cfg.package.version "595") || config.runix.systemServices.elogind.enable;
      defaultText = lib.literalExpression "open modules from driver 595, or elogind enabled";
      description = ''
        Whether to save video memory across suspend and hibernation. Without
        it a Wayland session usually comes back from suspend with a broken
        screen. The open modules from driver 595 learn about suspend from the
        kernel; older drivers run nvidia-sleep.sh as an elogind sleep hook.
        Video memory is saved to /var/tmp, on disk rather than RAM.
      '';
    };
    waylandEnvironment = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to set GBM_BACKEND, __GLX_VENDOR_LIBRARY_NAME and LIBVA_DRIVER_NAME for NVIDIA, as Wayland compositors expect.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # The driver is unfree; evaluating it fails unless nixpkgs allows it.
        assertion = (builtins.tryEval driver.drvPath).success;
        message = ''
          hardware.nvidia needs nixpkgs to allow the unfree NVIDIA driver. Pass
          it to runix.lib.runixSystem:
            nixpkgsConfig.allowUnfreePredicate = pkg:
              builtins.elem (pkg.pname or "") [ "nvidia-x11" "nvidia-settings" "nvidia-persistenced" ];
        '';
      }
      {
        assertion = !sleepHook || config.runix.systemServices.elogind.enable;
        message = "hardware.nvidia.powerManagement runs from elogind's sleep hooks: enable runix.systemServices.elogind.";
      }
      {
        assertion = !cfg.open || driver ? open;
        message = "hardware.nvidia.open: this driver branch has no open kernel modules; use the closed ones.";
      }
    ];

    runix.kernel = {
      modulePackages = [ kernelModule ];
      firmwarePackages = lib.optional (driver ? firmware) driver.firmware;
      # The kernel refuses nouveau outright; both drivers cannot own the GPU.
      parameters = [ "module_blacklist=nouveau" ]
        ++ lib.optionals cfg.modesetting [
          "nvidia-drm.modeset=1"
          "nvidia-drm.fbdev=1"
        ]
        ++ lib.optionals cfg.powerManagement [
          "nvidia.NVreg_PreserveVideoMemoryAllocations=1"
          "nvidia.NVreg_TemporaryFilePath=/var/tmp"
        ]
        ++ lib.optional (cfg.powerManagement && kernelNotifiers) "nvidia.NVreg_UseKernelSuspendNotifiers=1";
    };

    hardware.graphics = {
      enable = lib.mkDefault true;
      extraPackages = [ driver.out ];
      kernelModules = [
        "nvidia"
        "nvidia_modeset"
        "nvidia_uvm"
        "nvidia_drm"
      ];
      initrd.enable = lib.mkDefault cfg.earlyModesetting;
    };

    # nvidia-smi and the driver's other tools.
    runix.packages = [ driver.bin ];

    services.mdevd.rules = ''
      -$DEVPATH=/module/nvidia.* 0:0 660 @${deviceNodes}
    '';
    # Loaded here too, before the nodes are made, whatever order activation
    # scripts from other modules run in.
    runix.activationScripts = [
      ''
        ${pkgs.kmod}/bin/modprobe -a nvidia nvidia_modeset nvidia_uvm nvidia_drm || true
        ${deviceNodes}
      ''
    ];

    # What NixOS's nvidia-suspend, -hibernate and -resume services do.
    runix.systemServices.elogind.sleepHooks = lib.mkIf sleepHook {
      nvidia = ''
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.kbd pkgs.gnugrep ]}:$PATH
        case "$1/$2" in
          pre/hibernate | pre/hybrid-sleep | pre/suspend-then-hibernate)
            ${driver.out}/bin/nvidia-sleep.sh hibernate ;;
          pre/*) ${driver.out}/bin/nvidia-sleep.sh suspend ;;
          post/*) ${driver.out}/bin/nvidia-sleep.sh resume ;;
        esac
      '';
    };

    runix.environmentVariables = lib.mkIf cfg.waylandEnvironment {
      GBM_BACKEND = "nvidia-drm";
      __GLX_VENDOR_LIBRARY_NAME = "nvidia";
      LIBVA_DRIVER_NAME = "nvidia";
    };
  };
}
