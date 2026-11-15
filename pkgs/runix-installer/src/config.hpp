// Renders the flake written to /etc/runix. Callers validate every value with
// valid_host and valid_user, or take it from a fixed list, so nothing here
// needs Nix string escaping.
#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace config {

enum class Filesystem { Ext4, Btrfs, Zfs };
inline constexpr std::array<Filesystem, 3> filesystems{Filesystem::Ext4, Filesystem::Btrfs, Filesystem::Zfs};
const char* name(Filesystem filesystem);
const char* description(Filesystem filesystem);

/// A ZFS root is the dataset rpool/root, mounted the classic way (legacy).
inline constexpr const char* zfs_pool = "rpool";
inline constexpr const char* zfs_root_dataset = "rpool/root";

enum class Desktop {
    None, BlxshellZwwm, BlxshellHyprland, Hyprland, Labwc, Niri, Zwwm, Shojiwm, Driftwm,
};
inline constexpr std::array<Desktop, 9> desktops{
    Desktop::None,     Desktop::BlxshellZwwm, Desktop::BlxshellHyprland,
    Desktop::Hyprland, Desktop::Labwc,        Desktop::Niri,
    Desktop::Zwwm,     Desktop::Shojiwm,      Desktop::Driftwm,
};
const char* name(Desktop desktop);
const char* description(Desktop desktop);
/// The blxshell desktops come from its own flake, github:binarylinuxx/dots.
bool with_blxshell(Desktop desktop);
inline constexpr const char* blxshell_input = "github:binarylinuxx/dots";

enum class Network { Wifi, Dhcpcd };
inline constexpr std::array<Network, 2> networks{Network::Wifi, Network::Dhcpcd};
const char* name(Network network);

enum class BootMode { Bios, Efi };
const char* name(BootMode mode);

enum class BootLoader { Limine, Grub };
inline constexpr std::array<BootLoader, 2> loaders{BootLoader::Limine, BootLoader::Grub};
const char* name(BootLoader loader);
const char* description(BootLoader loader);

enum class Kernel { Default, Latest, Lts612, Zen, Xanmod, Cachyos, CachyosLts, CachyosBore };
inline constexpr std::array<Kernel, 8> kernels{
    Kernel::Default, Kernel::Latest,  Kernel::Lts612,     Kernel::Zen,
    Kernel::Xanmod,  Kernel::Cachyos, Kernel::CachyosLts, Kernel::CachyosBore,
};
const char* name(Kernel kernel);
const char* description(Kernel kernel);
/// The Nix expression for runix.kernel.packageSet, or null for the default.
const char* package_set(Kernel kernel);
/// CachyOS kernels come from xddxdd's flake and its binary cache.
bool from_cachyos(Kernel kernel);

inline constexpr const char* cachyos_input = "github:xddxdd/nix-cachyos-kernel/release";
inline constexpr const char* cachyos_substituter = "https://cache.lantian.pub/lantian";
inline constexpr const char* cachyos_key = "lantian:WVGO7vsRMSEN+h7Lp7kv6SAmrkEXgUGbbXm7jMDjBuQ=";

enum class Cpu { Amd, Intel, Other };

/// The NVIDIA driver for a GPU, chosen by its PCI device ID: the 590 and later
/// drivers start at Turing, and only Turing and newer have open modules.
struct NvidiaDriver {
    const char* branch;  // an attribute of nvidiaPackages
    bool open;
    const char* generation;
};
NvidiaDriver nvidia_driver(std::uint32_t device);

struct Settings {
    std::string flake;
    std::string host;
    std::string user;
    std::string timezone;
    Desktop desktop = Desktop::None;
    Network network = Network::Wifi;
    std::string root_uuid;
    Filesystem root_fs = Filesystem::Ext4;
    std::string boot_uuid;
    BootMode boot_mode = BootMode::Efi;
    BootLoader loader = BootLoader::Limine;
    Kernel kernel = Kernel::Default;
    std::string disk;
    Cpu cpu = Cpu::Other;
    /// An NVIDIA GPU's PCI device ID, for the proprietary driver.
    std::optional<std::uint32_t> nvidia_device;
    bool amd_gpu = false;
    bool intel_gpu = false;
    /// Modules the root disk needs to be found at boot, from the hardware.
    std::vector<std::string> disk_modules;
    /// Eight hex digits; the pool is created under this host ID, so the
    /// installed system imports it as its own.
    std::string zfs_host_id;
};

/// Empty when this kernel and filesystem work together, otherwise why not.
std::string check_kernel(Kernel kernel, Filesystem filesystem);

bool valid_host(const std::string& value);
bool valid_user(const std::string& value);
std::string password_hash_path(const std::string& user);

std::string flake(const Settings& settings);
std::string hardware(const Settings& settings);
std::string configuration(const Settings& settings);
/// /etc/runix/nix.nix: Nix settings, with commented examples to start from.
std::string nix_settings(const Settings& settings);

}  // namespace config
