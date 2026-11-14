// The destructive part of the installer. It runs on its own thread and stops
// at the first failed step; nothing here may continue past an error.
#pragma once

#include <array>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "config.hpp"

namespace install {

inline constexpr const char* log_path = "/tmp/runix-install.log";
inline constexpr const char* target = "/mnt";
inline constexpr std::uint64_t boot_size = 1024ull * 1024 * 1024;

inline constexpr std::array<const char*, 6> phases{
    "Prepare disk", "Format filesystems", "Mount target", "Write configuration", "Install system", "Finish",
};
/// How much of the overall bar each phase fills. Installing is nearly all of it.
inline constexpr std::array<int, 6> phase_weights{3, 3, 2, 2, 85, 5};

struct DiskLayout {
    enum class Kind { Automatic, Manual };
    /// Automatic erases the whole disk: a 1 GiB boot partition, root on the
    /// rest, and a 1 MiB BIOS boot partition that GRUB needs on BIOS machines.
    /// Manual uses existing partitions and never changes the partition table.
    Kind kind = Kind::Automatic;
    std::string boot;
    std::string root;
    bool format_boot = true;

    static DiskLayout automatic() { return {}; }
    static DiskLayout manual(std::string boot, std::string root, bool format_boot) {
        return {Kind::Manual, std::move(boot), std::move(root), format_boot};
    }
    bool operator==(const DiskLayout&) const = default;
};

using Commands = std::vector<std::vector<std::string>>;

std::string partition_path(const std::string& disk, unsigned number);
/// Commands that rewrite the partition table. Manual layouts have none.
Commands partition_commands(const DiskLayout& layout, const std::string& disk);
/// The boot and root partitions a layout installs to.
std::pair<std::string, std::string> targets(const DiskLayout& layout, const std::string& disk);
Commands format_commands(const DiskLayout& layout, config::Filesystem root_fs, const std::string& boot,
                         const std::string& root);
/// The arguments for runix-install, asking Nix for its machine-readable log.
std::vector<std::string> install_arguments(const std::string& flake_reference);

/// Everything chosen in the UI. UUIDs are only known once the disk is formatted.
struct Plan {
    DiskLayout layout;
    std::string flake;
    std::string host;
    std::string user;
    std::string password;
    std::string timezone;
    config::Desktop desktop = config::Desktop::None;
    config::Network network = config::Network::Wifi;
    config::Filesystem root_fs = config::Filesystem::Ext4;
    config::BootMode boot_mode = config::BootMode::Efi;
    config::BootLoader loader = config::BootLoader::Limine;
    std::string disk;
};

/// What Nix reports while the system is installed.
struct NixStatus {
    std::optional<double> fraction;
    std::string summary;
    std::string current;
    bool operator==(const NixStatus&) const = default;
};

struct Update {
    enum class Kind { Phase, Line, Nix, Finished };
    Kind kind;
    std::size_t phase = 0;
    std::string text;
    NixStatus nix;
    /// For Finished: empty on success, otherwise the error.
    std::string error;
};

using Sender = std::function<void(Update)>;

/// Starts the installation on its own thread.
void spawn(Plan plan, bool demo, bool demo_fail, Sender send);

void unmount(bool demo);

/// Terminal control codes in build output would corrupt the screen.
std::string clean_line(const std::string& text);

}  // namespace install
