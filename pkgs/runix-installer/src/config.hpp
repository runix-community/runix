// Renders the flake written to /etc/runix. Callers validate every value with
// valid_host and valid_user, or take it from a fixed list, so nothing here
// needs Nix string escaping.
#pragma once

#include <array>
#include <string>

namespace config {

enum class Filesystem { Ext4, Btrfs };
inline constexpr std::array<Filesystem, 2> filesystems{Filesystem::Ext4, Filesystem::Btrfs};
const char* name(Filesystem filesystem);
const char* description(Filesystem filesystem);

enum class Desktop { None, Hyprland, Labwc, Niri, Zwwm, Shojiwm, Driftwm };
inline constexpr std::array<Desktop, 7> desktops{
    Desktop::None, Desktop::Hyprland, Desktop::Labwc, Desktop::Niri,
    Desktop::Zwwm, Desktop::Shojiwm, Desktop::Driftwm,
};
const char* name(Desktop desktop);

enum class Network { Wifi, Dhcpcd };
inline constexpr std::array<Network, 2> networks{Network::Wifi, Network::Dhcpcd};
const char* name(Network network);

enum class BootMode { Bios, Efi };
const char* name(BootMode mode);

enum class BootLoader { Limine, Grub };
inline constexpr std::array<BootLoader, 2> loaders{BootLoader::Limine, BootLoader::Grub};
const char* name(BootLoader loader);
const char* description(BootLoader loader);

enum class Cpu { Amd, Intel, Other };

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
    std::string disk;
    Cpu cpu = Cpu::Other;
};

bool valid_host(const std::string& value);
bool valid_user(const std::string& value);
std::string password_hash_path(const std::string& user);

std::string flake(const Settings& settings);
std::string hardware(const Settings& settings);
std::string configuration(const Settings& settings);

}  // namespace config
