{ pkgs, ... }:
{
  runix.hostName = "nixos-machine";

  fileSystems = {
    "/" = {
      device = "rpool/root";
      fsType = "zfs";
    };
    "/nix" = {
      device = "rpool/nix";
      fsType = "zfs";
    };
    "/home" = {
      device = "rpool/home";
      fsType = "zfs";
    };
    "/persist" = {
      device = "rpool/persist";
      fsType = "zfs";
    };
  };

  runix.zfs = {
    enable = true;
    hostId = "1af9f2ec";
    package = pkgs.zfs;
    devNodes = "/dev";
    forceImportRoot = false;
    maintenance = {
      pools = [ "rpool" ];
      scrub.enable = true;
      trim.enable = true;
    };
  };

  runix.initrd = {
    modules = [
      "ahci"
      "ext4"
      "nvme"
      "sd_mod"
      "xhci_pci"
    ];
    loadModules = [
      "ahci"
      "nvme"
      "sd_mod"
    ];
  };

  runix.kernel = {
    # Custom kernels require a matching ZFS module from the same package set.
    packageSet = pkgs.linuxPackages;
    parameters = [ "quiet" ];
  };

  hardware = {
    amdgpu.enable = true;
    bluetooth.enable = true;
    cpu.amd.updateMicrocode = true;
    graphics = {
      extraPackages = with pkgs; [
        libdrm
        vulkan-loader
      ];
      rocmPackages = with pkgs.rocmPackages; [
        clr
        rocblas
        hipblas
      ];
    };
    i2c.enable = true;
    uinput.enable = true;
  };

  # Enable one bootloader; BIOS mode also requires a whole-disk device.
  runix.boot.loader.grub = {
    enable = true;
    mode = "efi";
  };
  runix.boot.loader.configurationLimit = 10;

  runix.groups = {
    wheel.gid = 1;
    networkmanager.gid = 57;
    video.gid = 26;
    input.gid = 174;
    render.gid = 303;
    docker.gid = 131;
    libvirtd.gid = 169;
  };

  runix.users.blx = {
    uid = 1000;
    gid = 100;
    description = "blx";
    # Set passwordHashFile to a root-readable runtime file to enable login.
    passwordHash = "!";
    shell = "${pkgs.fish}/bin/fish";
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
      "input"
      "render"
      "i2c"
      "uinput"
      "docker"
      "libvirtd"
    ];
  };

  runix.packages = with pkgs; [
    fish
    git
    git-lfs
    htop
    micro
    slurp
    tree
    wget
    xwayland-satellite
  ];

  runix.systemServices = {
    networkManager.enable = true;
    openssh.enable = true;
    docker.enable = true;
    libvirt.enable = true;
    yggdrasil.enable = true;
    powerProfiles.enable = true;
    upower.enable = true;
  };

  time.timeZone = "Asia/Jerusalem";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";
  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = 1048576;
    "vm.swappiness" = 10;
  };
  services.xserver.xkb = {
    layout = "us,ru";
    variant = ",";
    options = "grp:alt_shift_toggle";
  };
  fonts = {
    packages = with pkgs; [
      mona-sans
      noto-fonts
      noto-fonts-color-emoji
      nerd-fonts.jetbrains-mono
      nerd-fonts.symbols-only
    ];
    fontconfig.localConf = ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
      <fontconfig>
        <match target="pattern">
          <test qual="first" name="family" compare="eq"><string>Mona Sans VF</string></test>
          <edit name="family" mode="assign"><string>Mona Sans VF</string></edit>
          <edit name="genericfamily" mode="delete"/>
        </match>
        <match target="pattern">
          <test qual="first" name="family" compare="eq"><string>Mona Sans</string></test>
          <edit name="family" mode="assign"><string>Mona Sans</string></edit>
          <edit name="genericfamily" mode="delete"/>
        </match>
      </fontconfig>
    '';
  };

  runix.desktop = {
    enable = true;
    portals.enable = true;
  };

  programs = {
    hyprland = {
      package = pkgs.hyprland;
      xwayland.enable = true;
    };
    flatpak.enable = true;
    gpuScreenRecorder.enable = true;
    sudo.enable = true;
  };

  services.tmpfiles = {
    enable = true;
    rules = [
      "d /var/cache/runix 0755 root root - -"
      "d /var/lib/runix 0755 root root - -"
    ];
  };

  runix.services.getty.command = "${pkgs.busybox}/bin/getty 38400 tty1";
}
