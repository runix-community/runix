#include "config.hpp"

namespace config {

const char* name(Filesystem filesystem) {
    switch (filesystem) {
        case Filesystem::Ext4: return "ext4";
        case Filesystem::Btrfs: return "btrfs";
        case Filesystem::Zfs: return "zfs";
    }
    return "";
}

const char* description(Filesystem filesystem) {
    switch (filesystem) {
        case Filesystem::Ext4: return "Simple and reliable";
        case Filesystem::Btrfs: return "Checksums and compression support";
        case Filesystem::Zfs: return "Pooled storage with snapshots, checksums and compression";
    }
    return "";
}

const char* name(Desktop desktop) {
    switch (desktop) {
        case Desktop::None: return "Console only";
        case Desktop::BlxshellZwwm: return "blxshell on zwwm";
        case Desktop::BlxshellHyprland: return "blxshell on Hyprland";
        case Desktop::Hyprland: return "Hyprland";
        case Desktop::Labwc: return "Labwc";
        case Desktop::Niri: return "Niri";
        case Desktop::Zwwm: return "zwwm";
        case Desktop::Shojiwm: return "ShojiWM";
        case Desktop::Driftwm: return "driftwm";
    }
    return "";
}

const char* description(Desktop desktop) {
    switch (desktop) {
        case Desktop::None: return "a text console, add a desktop later";
        case Desktop::BlxshellZwwm: return "the Runix desktop: blxshell on the zwwm compositor";
        case Desktop::BlxshellHyprland: return "blxshell on Hyprland";
        case Desktop::Hyprland: return "dynamic tiling compositor";
        case Desktop::Labwc: return "stacking compositor, like Openbox";
        case Desktop::Niri: return "scrollable tiling compositor";
        case Desktop::Zwwm: return "the zwwm compositor on its own";
        case Desktop::Shojiwm: return "experimental compositor";
        case Desktop::Driftwm: return "experimental compositor";
    }
    return "";
}

bool with_blxshell(Desktop desktop) {
    return desktop == Desktop::BlxshellZwwm || desktop == Desktop::BlxshellHyprland;
}

static const char* program(Desktop desktop) {
    switch (desktop) {
        case Desktop::None:
        case Desktop::BlxshellHyprland:
        case Desktop::Hyprland: return nullptr;
        case Desktop::BlxshellZwwm: return "zwwm";
        case Desktop::Labwc: return "labwc";
        case Desktop::Niri: return "niri";
        case Desktop::Zwwm: return "zwwm";
        case Desktop::Shojiwm: return "shojiwm";
        case Desktop::Driftwm: return "driftwm";
    }
    return nullptr;
}

const char* name(Network network) {
    switch (network) {
        case Network::Wifi: return "Wi-Fi with runix-network";
        case Network::Dhcpcd: return "Wired with dhcpcd";
    }
    return "";
}

const char* name(BootMode mode) {
    return mode == BootMode::Bios ? "bios" : "efi";
}

const char* name(BootLoader loader) {
    return loader == BootLoader::Limine ? "Limine" : "GRUB";
}

const char* description(BootLoader loader) {
    return loader == BootLoader::Limine ? "small and fast, with a simple menu"
                                        : "the most widely used, with the broadest hardware support";
}

static const char* option(BootLoader loader) {
    return loader == BootLoader::Limine ? "limine" : "grub";
}

const char* name(Kernel kernel) {
    switch (kernel) {
        case Kernel::Default: return "Linux LTS";
        case Kernel::Latest: return "Linux latest";
        case Kernel::Lts612: return "Linux 6.12 LTS";
        case Kernel::Zen: return "Zen";
        case Kernel::Xanmod: return "XanMod";
        case Kernel::Cachyos: return "CachyOS";
        case Kernel::CachyosLts: return "CachyOS LTS";
        case Kernel::CachyosBore: return "CachyOS BORE";
    }
    return "";
}

const char* description(Kernel kernel) {
    switch (kernel) {
        case Kernel::Default: return "the nixpkgs default, long-term support";
        case Kernel::Latest: return "the newest stable release";
        case Kernel::Lts612: return "the previous long-term release, for older hardware";
        case Kernel::Zen: return "tuned for desktop responsiveness";
        case Kernel::Xanmod: return "desktop and gaming tuning, newest stable base";
        case Kernel::Cachyos: return "CachyOS patches and tuning, newest release";
        case Kernel::CachyosLts: return "CachyOS patches on the long-term release";
        case Kernel::CachyosBore: return "CachyOS with the BORE scheduler";
    }
    return "";
}

const char* package_set(Kernel kernel) {
    switch (kernel) {
        case Kernel::Default: return nullptr;
        case Kernel::Latest: return "pkgs.linuxPackages_latest";
        case Kernel::Lts612: return "pkgs.linuxPackages_6_12";
        case Kernel::Zen: return "pkgs.linuxPackages_zen";
        case Kernel::Xanmod: return "pkgs.linuxPackages_xanmod_latest";
        case Kernel::Cachyos:
            return "nix-cachyos-kernel.legacyPackages.x86_64-linux.linuxPackages-cachyos-latest";
        case Kernel::CachyosLts:
            return "nix-cachyos-kernel.legacyPackages.x86_64-linux.linuxPackages-cachyos-lts";
        case Kernel::CachyosBore:
            return "nix-cachyos-kernel.legacyPackages.x86_64-linux.linuxPackages-cachyos-bore";
    }
    return nullptr;
}

bool from_cachyos(Kernel kernel) {
    return kernel == Kernel::Cachyos || kernel == Kernel::CachyosLts || kernel == Kernel::CachyosBore;
}

std::string check_kernel(Kernel kernel, Filesystem filesystem) {
    // The CachyOS flake ships its own ZFS module, which need not match the
    // ZFS tools Runix installs, so the pairing is not offered.
    if (filesystem == Filesystem::Zfs && from_cachyos(kernel)) {
        return "ZFS is not available with CachyOS kernels yet. Go back and pick another kernel.";
    }
    return "";
}

static bool alnum(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

bool valid_host(const std::string& value) {
    if (value.empty() || value.size() > 63 || !alnum(value[0])) return false;
    for (char c : value) {
        if (!alnum(c) && c != '-') return false;
    }
    return true;
}

bool valid_user(const std::string& value) {
    if (value.empty() || value.size() > 32 || value == "root") return false;
    if (!((value[0] >= 'a' && value[0] <= 'z') || value[0] == '_')) return false;
    for (char c : value) {
        bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (!ok) return false;
    }
    return true;
}

std::string password_hash_path(const std::string& user) {
    return "/var/lib/runix/secrets/" + user + ".hash";
}

std::string flake(const Settings& settings) {
    bool cachyos = from_cachyos(settings.kernel);
    std::string substituters = "\"https://runix-community.cachix.org\"";
    std::string keys = "      \"runix-community.cachix.org-1:sENfG2mPWobsz1MKahUs+HOGfVt2L3OvG5oHHD5/coE=\"\n";
    std::string inputs = "  inputs.runix.url = \"" + settings.flake + "\";\n";
    std::string arguments = "{ runix, ... }";
    std::string special;
    std::string extra_modules;
    std::string extra_arguments;
    if (with_blxshell(settings.desktop)) {
        // Built against Runix's nixpkgs, so the desktop shares its libraries.
        inputs += std::string("  inputs.blxshell = {\n"
                              "    url = \"") + blxshell_input + "\";\n"
                  "    inputs.nixpkgs.follows = \"runix/nixpkgs\";\n"
                  "  };\n";
        extra_arguments = "blxshell, ";
        extra_modules = "          blxshell.runixModules.default\n";
    }
    if (!extra_arguments.empty()) arguments.insert(2, extra_arguments);
    if (cachyos) {
        substituters += std::string("\n      \"") + cachyos_substituter + "\"\n    ";
        substituters = "\n      " + substituters;
        keys += std::string("      \"") + cachyos_key + "\"\n";
        // Its nixpkgs is not overridden: the cached kernels were built with it.
        inputs += std::string("  inputs.nix-cachyos-kernel.url = \"") + cachyos_input + "\";\n";
        arguments = "{ runix, nix-cachyos-kernel, ... }";
        special = "        specialArgs = { inherit nix-cachyos-kernel; };\n";
    } else {
        substituters = " " + substituters + " ";
    }
    return "{\n"
           "  description = \"Runix configuration for " + settings.host + "\";\n"
           "\n"
           "  nixConfig = {\n"
           "    extra-substituters = [" + substituters + "];\n"
           "    extra-trusted-public-keys = [\n" +
           keys +
           "    ];\n"
           "  };\n"
           "\n" +
           inputs +
           "\n"
           "  outputs =\n"
           "    " + arguments + ":\n"
           "    {\n"
           "      runixConfigurations." + settings.host + " = runix.lib.runixSystem {\n"
           "        system = \"x86_64-linux\";\n" +
           special +
           "        modules = [\n"
           "          ./hardware.nix\n"
           "          ./configuration.nix\n"
           "          ./nix.nix\n" +
           extra_modules +
           "        ];\n"
           "      };\n"
           "    };\n"
           "}\n";
}

std::string hardware(const Settings& settings) {
    std::string microcode;
    if (settings.cpu == Cpu::Amd) microcode = "  hardware.cpu.amd.updateMicrocode = true;\n";
    if (settings.cpu == Cpu::Intel) microcode = "  hardware.cpu.intel.updateMicrocode = true;\n";
    std::string device;
    if (settings.boot_mode == BootMode::Bios) device = "    device = \"" + settings.disk + "\";\n";
    bool zfs = settings.root_fs == Filesystem::Zfs;
    // ZFS finds datasets by name after importing the pool, not by UUID.
    std::string root_device = zfs ? std::string(zfs_root_dataset) : "UUID=" + settings.root_uuid;
    std::string zfs_settings;
    if (zfs) {
        zfs_settings = "\n"
                       "  runix.zfs = {\n"
                       "    enable = true;\n"
                       "    # Pools remember the host that last used them; keep this as it is.\n"
                       "    hostId = \"" + settings.zfs_host_id + "\";\n"
                       "  };\n";
    }
    return std::string("# Generated by runix-installer for this machine.\n") +
           "{\n"
           "  fileSystems = {\n"
           "    \"/\" = {\n"
           "      device = \"" + root_device + "\";\n"
           "      fsType = \"" + name(settings.root_fs) + "\";\n"
           "    };\n"
           "    \"/boot\" = {\n"
           "      device = \"UUID=" + settings.boot_uuid + "\";\n"
           "      fsType = \"vfat\";\n"
           "    };\n"
           "  };\n"
           "\n"
           "  runix.initrd = {\n"
           "    modules = [\n"
           "      \"ahci\"\n"
           "      \"nvme\"\n"
           "      \"sd_mod\"\n"
           "      \"uas\"\n"
           "      \"usb_storage\"\n"
           "      \"virtio_blk\"\n"
           "      \"virtio_pci\"\n"
           "      \"virtio_scsi\"\n"
           "      \"xhci_pci\"\n"
           "    ];\n"
           "    loadModules = [\n"
           "      \"ahci\"\n"
           "      \"nvme\"\n"
           "      \"sd_mod\"\n"
           "      \"virtio_blk\"\n"
           "      \"virtio_pci\"\n"
           "      \"virtio_scsi\"\n"
           "    ];\n"
           "  };\n"
           "\n"
           "  hardware.enableRedistributableFirmware = true;\n" +
           microcode +
           "  runix.boot.loader." + option(settings.loader) + " = {\n"
           "    enable = true;\n"
           "    mode = \"" + name(settings.boot_mode) + "\";\n" +
           device +
           "  };\n" +
           zfs_settings +
           "}\n";
}

std::string configuration(const Settings& settings) {
    std::string network = settings.network == Network::Wifi
                               ? "  runix.systemServices.wifi.enable = true;\n"
                               : "  runix.systemServices.dhcpcd.enable = true;\n";
    std::string desktop;
    if (settings.desktop != Desktop::None) {
        desktop = "  runix.desktop.enable = true;\n";
        if (const char* chosen = program(settings.desktop)) {
            desktop += "  programs.hyprland.enable = false;\n";
            desktop += std::string("  programs.") + chosen + ".enable = true;\n";
        }
    }
    if (with_blxshell(settings.desktop)) {
        // The login screen wears this user's colours and wallpaper. It runs in
        // zwwm even when the desktop is Hyprland.
        desktop += "\n"
                   "  programs.blxshell = {\n"
                   "    enable = true;\n"
                   "    greeter = {\n"
                   "      enable = true;\n"
                   "      syncUser = \"" + settings.user + "\";\n";
        if (settings.desktop == Desktop::BlxshellHyprland) desktop += "      zwwmPackage = pkgs.zwwm;\n";
        desktop += "    };\n"
                   "  };\n";
    }
    std::string kernel;
    if (const char* set = package_set(settings.kernel)) kernel = std::string("  runix.kernel.packageSet = ") + set + ";\n";
    std::string arguments = from_cachyos(settings.kernel) ? "{ pkgs, nix-cachyos-kernel, ... }:\n" : "{ pkgs, ... }:\n";
    return arguments +
           "{\n"
           "  runix.hostName = \"" + settings.host + "\";\n"
           "  time.timeZone = \"" + settings.timezone + "\";\n"
           "\n"
           "  runix.groups.wheel.gid = 1;\n"
           "  runix.users." + settings.user + " = {\n"
           "    uid = 1000;\n"
           "    gid = 100;\n"
           "    passwordHashFile = \"" + password_hash_path(settings.user) + "\";\n"
           "    extraGroups = [\n"
           "      \"wheel\"\n"
           "      \"audio\"\n"
           "      \"input\"\n"
           "      \"render\"\n"
           "      \"video\"\n"
           "    ];\n"
           "  };\n"
           "\n"
           "  programs.sudo.enable = true;\n"
           "  runix.services.getty.command = \"${pkgs.busybox}/bin/getty 38400 tty1\";\n"
           "\n" +
           kernel + network + desktop + "}\n";
}

std::string nix_settings(const Settings& settings) {
    std::string caches;
    if (from_cachyos(settings.kernel)) {
        // nixConfig in flake.nix only applies while installing; this keeps
        // updates downloading the CachyOS kernel instead of compiling it.
        caches = std::string(
                     "    # The CachyOS kernel's binary cache, from github:xddxdd/nix-cachyos-kernel.\n"
                     "    substituters = [ \"") +
                 cachyos_substituter +
                 "\" ];\n"
                 "    trusted-public-keys = [ \"" +
                 cachyos_key + "\" ];\n\n";
    }
    return "# Nix settings for this machine, written to /etc/nix/nix.conf.\n"
           "#\n"
           "# Lists add to Runix's defaults, which already trust cache.nixos.org and\n"
           "# runix-community.cachix.org. Use lib.mkForce to replace a list instead.\n"
           "# Every setting is described in `man nix.conf`.\n"
           "{ lib, ... }:\n"
           "{\n"
           "  nix.settings = {\n" +
           caches +
           "    # Use every CPU core for builds.\n"
           "    max-jobs = \"auto\";\n"
           "\n"
           "    # Hard-link identical files in /nix/store to save space.\n"
           "    auto-optimise-store = true;\n"
           "\n"
           "    # Let " + settings.user + " add caches and build without sudo. This is as\n"
           "    # powerful as root, like membership of wheel already is.\n"
           "    # trusted-users = [ \"" + settings.user + "\" ];\n"
           "\n"
           "    # Keep build dependencies around, so rebuilding after a garbage\n"
           "    # collection downloads less. Uses more disk space.\n"
           "    # keep-outputs = true;\n"
           "    # keep-derivations = true;\n"
           "\n"
           "    # Another binary cache:\n"
           "    # substituters = [ \"https://cache.example.org\" ];\n"
           "    # trusted-public-keys = [ \"cache.example.org-1:...\" ];\n"
           "  };\n"
           "}\n";
}

}  // namespace config
