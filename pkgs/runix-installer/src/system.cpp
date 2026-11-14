#include "system.hpp"

#include <algorithm>
#include <array>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <thread>

#include "install.hpp"
#include "json.hpp"
#include "process.hpp"
#include "util.hpp"

namespace fs = std::filesystem;

namespace system_probe {

namespace {
constexpr const char* live_mount = "/run/runix-live/iso";
}

bool Partition::is_vfat() const {
    return fstype == "vfat";
}

bool Partition::is_bios_boot() const {
    return kind && util::contains(*kind, "BIOS boot");
}

bool Partition::is_efi_system() const {
    return is_vfat() && kind && util::contains(*kind, "EFI");
}

const Partition* existing_esp(const std::vector<Partition>& partitions) {
    for (const auto& partition : partitions) {
        if (partition.is_efi_system()) return &partition;
    }
    return nullptr;
}

std::vector<Disk> parse_disks(const std::string& text, const std::optional<std::string>& live_disk) {
    std::vector<Disk> result;
    auto root = json::parse(text);
    if (!root) return result;
    for (const auto& device : (*root)["blockdevices"].items) {
        if (device["type"].string() != "disk" || device["ro"].is_true()) continue;
        auto path = device["name"].string();
        auto size = device["size"].unsigned_number();
        if (!path || !size) continue;
        std::string model = device["model"].string() ? util::trim(*device["model"].string()) : "Unknown disk";
        if (*size < minimum_disk_bytes || (live_disk && *path == *live_disk)) continue;
        result.push_back({*path, *size, model});
    }
    return result;
}

/// The disk holding the running ISO must never be offered for erasing.
static std::optional<std::string> live_disk() {
    auto source = process::stdout_of({"findmnt", "-no", "SOURCE", live_mount});
    if (!source) return std::nullopt;
    std::string device = util::trim(*source);
    if (device.empty()) return std::nullopt;
    std::string parent = util::trim(process::stdout_of({"lsblk", "-ndo", "PKNAME", device}).value_or(""));
    if (parent.empty()) return device;
    return "/dev/" + parent;
}

std::vector<Disk> disks(bool demo) {
    if (demo) {
        return {
            {"/dev/nvme0n1", 512 * GiB, "Demo NVMe SSD"},
            {"/dev/sda", 2048 * GiB, "Demo SATA Disk"},
        };
    }
    auto live = live_disk();
    auto text = process::stdout_of({"lsblk", "-Jbdpo", "NAME,SIZE,TYPE,RO,MODEL"});
    return text ? parse_disks(*text, live) : std::vector<Disk>{};
}

std::vector<Partition> parse_partitions(const std::string& text) {
    std::vector<Partition> result;
    auto root = json::parse(text);
    if (!root) return result;
    for (const auto& child : (*root)["blockdevices"][0]["children"].items) {
        if (child["type"].string() != "part") continue;
        auto path = child["name"].string();
        auto size = child["size"].unsigned_number();
        if (!path || !size) continue;
        result.push_back({*path, *size, child["fstype"].string(), child["parttypename"].string(),
                          child["mountpoint"].is_string()});
    }
    return result;
}

std::vector<Partition> partitions(bool demo, const std::string& disk) {
    if (demo) {
        auto part = [&](unsigned number, std::uint64_t size, const char* fstype, const char* kind) {
            return Partition{install::partition_path(disk, number), size, fstype, kind, false};
        };
        return {
            part(1, GiB / 2, "vfat", "EFI System"),
            part(2, 200 * GiB, "ntfs", "Microsoft basic data"),
            part(3, 120 * GiB, "ext4", "Linux filesystem"),
        };
    }
    auto text = process::stdout_of({"lsblk", "-Jbpo", "NAME,SIZE,TYPE,FSTYPE,PARTTYPENAME,MOUNTPOINT", disk});
    return text ? parse_partitions(*text) : std::vector<Partition>{};
}

bool online(bool demo) {
    if (demo) return false;
    return process::capture({"curl", "-fsS", "--max-time", "5", "https://cache.nixos.org/nix-cache-info"}).ok();
}

bool wireless_available(bool demo) {
    if (demo) return true;
    std::error_code error;
    for (const auto& entry : fs::directory_iterator("/sys/class/net", error)) {
        if (fs::is_directory(entry.path() / "wireless", error)) return true;
    }
    return false;
}

std::vector<WifiNetwork> parse_scan(const std::string& output) {
    std::vector<WifiNetwork> networks;
    for (const auto& line : util::split(output, '\n')) {
        auto fields = util::split(line, '\t');
        if (fields.size() < 5) continue;
        // The SSID is the last field and may itself hold tabs.
        std::string ssid = fields[4];
        for (std::size_t i = 5; i < fields.size(); ++i) ssid += "\t" + fields[i];
        if (ssid.empty() || !util::contains(fields[0], ":")) continue;
        bool secured = util::contains(fields[3], "WPA") || util::contains(fields[3], "SAE");
        auto found = std::find_if(networks.begin(), networks.end(),
                                  [&](const WifiNetwork& network) { return network.ssid == ssid; });
        if (found != networks.end()) {
            found->secured = found->secured || secured;
        } else {
            networks.push_back({ssid, secured});
        }
    }
    return networks;
}

std::vector<WifiNetwork> scan(bool demo) {
    if (demo) return {{"Demo Home", true}, {"Demo Cafe", false}};
    auto output = process::stdout_of({"runix-network", "scan"});
    return output ? parse_scan(*output) : std::vector<WifiNetwork>{};
}

std::string connect(bool demo, const std::string& ssid, const std::optional<std::string>& password) {
    if (demo) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        return "";
    }
    process::Arguments arguments{"runix-network", "connect", ssid};
    if (password) arguments.push_back(*password);
    auto output = process::capture(arguments);
    if (!output.started) return output.start_error;
    if (output.status == 0) return "";
    auto lines = util::split(util::trim(output.err), '\n');
    std::string last = lines.empty() ? "" : util::trim(lines.back());
    return last.empty() ? "connection failed" : last;
}

static void walk_zones(const fs::path& directory, const std::string& prefix, std::vector<std::string>& zones) {
    std::error_code error;
    for (const auto& entry : fs::directory_iterator(directory, error)) {
        std::string zone = prefix + "/" + entry.path().filename().string();
        if (entry.is_directory(error)) {
            walk_zones(entry.path(), zone, zones);
        } else {
            zones.push_back(zone);
        }
    }
}

std::vector<std::string> timezones(const std::string& zoneinfo) {
    static constexpr std::array<const char*, 9> regions{
        "Africa", "America", "Antarctica", "Asia", "Atlantic", "Australia", "Europe", "Indian", "Pacific",
    };
    std::vector<std::string> zones;
    for (const char* region : regions) walk_zones(fs::path(zoneinfo) / region, region, zones);
    std::sort(zones.begin(), zones.end());
    zones.insert(zones.begin(), "UTC");
    return zones;
}

std::string find_zoneinfo(const std::vector<std::optional<std::string>>& candidates) {
    std::error_code error;
    for (const auto& candidate : candidates) {
        if (candidate && !candidate->empty() && fs::exists(fs::path(*candidate) / "UTC", error)) return *candidate;
    }
    return "/usr/share/zoneinfo";
}

config::BootMode boot_mode() {
    std::error_code error;
    return fs::is_directory("/sys/firmware/efi", error) ? config::BootMode::Efi : config::BootMode::Bios;
}

config::Cpu cpu_vendor() {
    std::ifstream file("/proc/cpuinfo");
    std::string line;
    while (std::getline(file, line)) {
        if (line.rfind("vendor_id", 0) != 0) continue;
        if (util::contains(line, "AuthenticAMD")) return config::Cpu::Amd;
        if (util::contains(line, "GenuineIntel")) return config::Cpu::Intel;
        break;
    }
    return config::Cpu::Other;
}

}  // namespace system_probe
