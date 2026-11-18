// Read-only probes of the live machine, plus Wi-Fi through runix-network.
// Every function takes `demo` so --demo never touches real hardware.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "config.hpp"

namespace system_probe {

inline constexpr std::uint64_t GiB = 1024ull * 1024 * 1024;
inline constexpr std::uint64_t minimum_disk_bytes = 16 * GiB;

struct Disk {
    std::string path;
    std::uint64_t size = 0;
    std::string model;
};

struct Partition {
    std::string path;
    std::uint64_t size = 0;
    std::optional<std::string> fstype;
    std::optional<std::string> kind;
    bool mounted = false;

    bool is_vfat() const;
    bool is_bios_boot() const;
    bool is_efi_system() const;
};

/// The partition a manual layout most likely boots from: an existing ESP.
const Partition* existing_esp(const std::vector<Partition>& partitions);

struct WifiNetwork {
    std::string ssid;
    bool secured = false;

    bool operator==(const WifiNetwork&) const = default;
};

std::vector<Disk> parse_disks(const std::string& json, const std::optional<std::string>& live_disk);
std::vector<Disk> disks(bool demo);

std::vector<Partition> parse_partitions(const std::string& json);
std::vector<Partition> partitions(bool demo, const std::string& disk);

struct Connection {
    bool online = false;
    /// The mirror Nix uses when cache.nixos.org is blocked or slow, or empty.
    std::string mirror;
};
/// The mirror runix-mirrors chose, from its "using: URL?priority=10 ..." line.
std::string parse_mirror(const std::string& probe_output);
Connection online(bool demo);
bool wireless_available(bool demo);
std::vector<WifiNetwork> parse_scan(const std::string& output);
std::vector<WifiNetwork> scan(bool demo);
/// An empty string on success, otherwise the reason.
std::string connect(bool demo, const std::string& ssid, const std::optional<std::string>& password);

std::vector<std::string> timezones(const std::string& zoneinfo);
/// The first directory holding a UTC zone file.
std::string find_zoneinfo(const std::vector<std::optional<std::string>>& candidates);

config::BootMode boot_mode();
/// The PCI device ID of the first NVIDIA display controller under
/// `pci_devices` (normally /sys/bus/pci/devices), if there is one.
std::optional<std::uint32_t> find_nvidia(const std::string& pci_devices);
std::optional<std::uint32_t> nvidia_gpu(bool demo);

/// The graphics on this machine, from the PCI display controllers.
struct Gpus {
    bool amd = false;
    bool intel = false;
    std::optional<std::uint32_t> nvidia;
};
Gpus find_gpus(const std::string& pci_devices);
Gpus gpus(bool demo);

/// The kernel modules between a disk and the machine: its controller, bus
/// and disk drivers (nvme, ahci and sd_mod, xhci_pci and usb_storage...).
/// Walks /sys/block/<name>/device up through `sys` and keeps drivers that are
/// loadable modules, per `sys`/module/<module>/initstate.
std::vector<std::string> disk_modules(const std::string& sys, const std::string& disk);

/// Bluetooth and a battery, from `sys` (normally /sys).
struct Devices {
    bool bluetooth = false;
    bool battery = false;
};
Devices find_devices(const std::string& sys);
Devices devices(bool demo);
config::Cpu cpu_vendor();

}  // namespace system_probe
