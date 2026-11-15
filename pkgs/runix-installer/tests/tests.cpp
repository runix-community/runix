// Plain assertions, no framework: `make check` builds and runs this file.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

#include "../src/app.hpp"
#include "../src/config.hpp"
#include "../src/install.hpp"
#include "../src/json.hpp"
#include "../src/nixlog.hpp"
#include "../src/report.hpp"
#include "../src/snake.hpp"
#include "../src/bricks.hpp"
#include "../src/fetch.hpp"
#include "../src/xpbd.hpp"
#include "../src/system.hpp"
#include "../src/ui.hpp"
#include "../src/util.hpp"

namespace {

int failures = 0;
int checks = 0;

#define CHECK(condition)                                                              \
    do {                                                                              \
        ++checks;                                                                     \
        if (!(condition)) {                                                           \
            ++failures;                                                               \
            std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition); \
        }                                                                             \
    } while (0)

bool has(const std::string& text, const std::string& part) {
    return text.find(part) != std::string::npos;
}

std::vector<std::pair<const char*, std::function<void()>>>& registry() {
    static std::vector<std::pair<const char*, std::function<void()>>> tests;
    return tests;
}

struct Register {
    Register(const char* name, std::function<void()> test) { registry().emplace_back(name, std::move(test)); }
};

#define TEST(name)                                  \
    void name();                                    \
    const Register register_##name(#name, name);    \
    void name()

config::Settings settings() {
    config::Settings value;
    value.flake = "github:runix-community/runix";
    value.host = "testhost";
    value.user = "alice";
    value.timezone = "Europe/Paris";
    value.desktop = config::Desktop::None;
    value.network = config::Network::Wifi;
    value.root_uuid = "1111-root";
    value.root_fs = config::Filesystem::Ext4;
    value.boot_uuid = "ABCD-1234";
    value.boot_mode = config::BootMode::Efi;
    value.loader = config::BootLoader::Limine;
    value.disk = "/dev/sda";
    value.cpu = config::Cpu::Amd;
    return value;
}

// ---- config

TEST(efi_hardware_has_no_install_device) {
    auto text = config::hardware(settings());
    CHECK(has(text, "mode = \"efi\";"));
    CHECK(!has(text, "/dev/sda"));
    CHECK(has(text, "device = \"UUID=ABCD-1234\";"));
    CHECK(has(text, "hardware.cpu.amd.updateMicrocode = true;"));
}

TEST(bios_hardware_names_the_install_device) {
    auto value = settings();
    value.boot_mode = config::BootMode::Bios;
    value.cpu = config::Cpu::Other;
    auto text = config::hardware(value);
    CHECK(has(text, "mode = \"bios\";"));
    CHECK(has(text, "device = \"/dev/sda\";"));
    CHECK(!has(text, "updateMicrocode"));
}

TEST(the_chosen_boot_loader_is_enabled) {
    CHECK(has(config::hardware(settings()), "runix.boot.loader.limine = {"));
    auto value = settings();
    value.loader = config::BootLoader::Grub;
    value.boot_mode = config::BootMode::Bios;
    auto text = config::hardware(value);
    CHECK(has(text, "runix.boot.loader.grub = {"));
    CHECK(!has(text, "limine"));
}

TEST(the_default_kernel_writes_no_package_set) {
    auto text = config::configuration(settings());
    CHECK(!has(text, "runix.kernel.packageSet"));
    CHECK(has(text, "{ pkgs, ... }:"));
    CHECK(!has(config::flake(settings()), "cachyos"));
}

TEST(nixpkgs_kernels_set_the_package_set) {
    auto value = settings();
    value.kernel = config::Kernel::Zen;
    CHECK(has(config::configuration(value), "  runix.kernel.packageSet = pkgs.linuxPackages_zen;\n"));
    CHECK(!has(config::flake(value), "nix-cachyos-kernel"));
    value.kernel = config::Kernel::Lts612;
    CHECK(has(config::configuration(value), "pkgs.linuxPackages_6_12;"));
}

TEST(cachyos_kernels_bring_their_flake_and_cache) {
    auto value = settings();
    value.kernel = config::Kernel::CachyosBore;
    auto flake_text = config::flake(value);
    CHECK(has(flake_text, "inputs.nix-cachyos-kernel.url = \"github:xddxdd/nix-cachyos-kernel/release\";"));
    CHECK(has(flake_text, "\"https://cache.lantian.pub/lantian\""));
    CHECK(has(flake_text, "\"lantian:WVGO7vsRMSEN+h7Lp7kv6SAmrkEXgUGbbXm7jMDjBuQ=\""));
    CHECK(has(flake_text, "\"https://runix-community.cachix.org\""));
    CHECK(has(flake_text, "{ nix-cachyos-kernel, runix, ... }:"));
    CHECK(has(flake_text, "specialArgs = { inherit nix-cachyos-kernel; };"));
    // The cached kernels were built with the flake's own nixpkgs.
    CHECK(!has(flake_text, "follows"));
    auto text = config::configuration(value);
    CHECK(has(text, "{ pkgs, nix-cachyos-kernel, ... }:"));
    CHECK(has(text, "runix.kernel.packageSet = "
                    "nix-cachyos-kernel.legacyPackages.x86_64-linux.linuxPackages-cachyos-bore;"));
}

TEST(flake_exposes_the_host) {
    auto text = config::flake(settings());
    CHECK(has(text, "runixConfigurations.testhost"));
    CHECK(has(text, "inputs.runix.url = \"github:runix-community/runix\";"));
}

TEST(configuration_uses_runix_networking) {
    auto text = config::configuration(settings());
    CHECK(has(text, "runix.systemServices.wifi.enable = true;"));
    CHECK(!has(text, "networkManager"));
    CHECK(!has(text, "runix.desktop.enable"));
    CHECK(has(text, "passwordHashFile = \"/var/lib/runix/secrets/alice.hash\";"));
    CHECK(has(text, "${pkgs.busybox}/bin/getty"));
}

TEST(other_compositors_replace_hyprland) {
    auto value = settings();
    value.desktop = config::Desktop::Niri;
    value.network = config::Network::Dhcpcd;
    auto text = config::configuration(value);
    CHECK(has(text, "programs.hyprland.enable = false;"));
    CHECK(has(text, "programs.niri.enable = true;"));
    CHECK(has(text, "runix.systemServices.dhcpcd.enable = true;"));
    value.desktop = config::Desktop::Hyprland;
    text = config::configuration(value);
    CHECK(has(text, "runix.desktop.enable = true;"));
    CHECK(!has(text, "programs.hyprland.enable"));
}

TEST(zfs_roots_are_named_datasets_with_a_host_id) {
    auto value = settings();
    value.root_fs = config::Filesystem::Zfs;
    value.zfs_host_id = "1a2b3c4d";
    auto text = config::hardware(value);
    CHECK(has(text, "device = \"rpool/root\";"));
    CHECK(has(text, "fsType = \"zfs\";"));
    CHECK(has(text, "runix.zfs = {"));
    CHECK(has(text, "hostId = \"1a2b3c4d\";"));
    CHECK(!has(text, "UUID=1111-root"));
    CHECK(has(text, "device = \"UUID=ABCD-1234\";"));
    CHECK(!has(config::hardware(settings()), "runix.zfs"));
}

TEST(zfs_is_not_paired_with_cachyos_kernels) {
    CHECK(!config::check_kernel(config::Kernel::Cachyos, config::Filesystem::Zfs).empty());
    CHECK(!config::check_kernel(config::Kernel::CachyosLts, config::Filesystem::Zfs).empty());
    CHECK(config::check_kernel(config::Kernel::Default, config::Filesystem::Zfs).empty());
    CHECK(config::check_kernel(config::Kernel::Zen, config::Filesystem::Zfs).empty());
    CHECK(config::check_kernel(config::Kernel::Cachyos, config::Filesystem::Btrfs).empty());
}

TEST(nix_settings_are_written_with_examples) {
    auto text = config::nix_settings(settings());
    CHECK(has(text, "nix.settings = {"));
    CHECK(has(text, "# trusted-users = [ \"alice\" ];"));
    CHECK(has(text, "auto-optimise-store = true;"));
    CHECK(!has(text, "lantian"));
    CHECK(has(config::flake(settings()), "./nix.nix"));
    auto value = settings();
    value.kernel = config::Kernel::Cachyos;
    text = config::nix_settings(value);
    CHECK(has(text, "substituters = [ \"https://cache.lantian.pub/lantian\" ];"));
    CHECK(has(text, "lantian:WVGO7vsRMSEN+h7Lp7kv6SAmrkEXgUGbbXm7jMDjBuQ="));
}

TEST(the_blxshell_desktops_bring_its_flake_and_greeter) {
    auto value = settings();
    value.desktop = config::Desktop::BlxshellZwwm;
    auto flake = config::flake(value);
    CHECK(has(flake, "url = \"github:binarylinuxx/dots\";"));
    CHECK(has(flake, "inputs.nixpkgs.follows = \"runix/nixpkgs\";"));
    CHECK(has(flake, "{ blxshell, runix, ... }:"));
    CHECK(has(flake, "blxshell.runixModules.default"));
    auto text = config::configuration(value);
    CHECK(has(text, "runix.desktop.enable = true;"));
    CHECK(has(text, "programs.hyprland.enable = false;"));
    CHECK(has(text, "programs.zwwm.enable = true;"));
    CHECK(has(text, "programs.blxshell = {"));
    CHECK(has(text, "syncUser = \"alice\";"));
    CHECK(!has(text, "zwwmPackage"));

    value.desktop = config::Desktop::BlxshellHyprland;
    text = config::configuration(value);
    CHECK(!has(text, "programs.hyprland.enable = false;"));
    CHECK(!has(text, "programs.zwwm.enable"));
    // The greeter still needs zwwm to run in.
    CHECK(has(text, "zwwmPackage = pkgs.zwwm;"));

    // Other desktops leave the blxshell flake out.
    value.desktop = config::Desktop::Niri;
    CHECK(!has(config::flake(value), "blxshell"));
    CHECK(!has(config::configuration(value), "blxshell"));
}

TEST(nvidia_gpus_get_the_driver_their_generation_needs) {
    auto turing = config::nvidia_driver(0x1e84);  // RTX 2070 Super
    CHECK(std::string(turing.branch) == "stable" && turing.open);
    auto blackwell = config::nvidia_driver(0x2b85);  // RTX 5090
    CHECK(std::string(blackwell.branch) == "stable" && blackwell.open);
    auto pascal = config::nvidia_driver(0x1b80);  // GTX 1080
    CHECK(std::string(pascal.branch) == "legacy_580" && !pascal.open);
    auto maxwell = config::nvidia_driver(0x13c2);  // GTX 970
    CHECK(std::string(maxwell.branch) == "legacy_580");
    auto kepler = config::nvidia_driver(0x1184);  // GTX 770
    CHECK(std::string(kepler.branch) == "legacy_470" && !kepler.open);

    auto value = settings();
    value.nvidia_device = 0x2684;  // RTX 4090
    auto hardware = config::hardware(value);
    CHECK(hardware.rfind("# Generated by runix-installer for this machine.\n{ config, ... }:\n{\n", 0) == 0);
    CHECK(has(hardware, "# NVIDIA GPU 10de:2684 (Turing or newer)"));
    CHECK(has(hardware, "package = config.runix.kernel.packageSet.nvidiaPackages.stable;"));
    CHECK(has(hardware, "open = true;"));
    auto flake = config::flake(value);
    CHECK(has(flake, "nixpkgsConfig.allowUnfreePredicate ="));
    CHECK(has(flake, "\"nvidia-x11\""));
    // Without an NVIDIA GPU nothing about it is written.
    CHECK(!has(config::hardware(settings()), "nvidia"));
    CHECK(!has(config::flake(settings()), "allowUnfree"));
    CHECK(config::hardware(settings()).rfind("# Generated by runix-installer for this machine.\n{\n", 0) == 0);
}

TEST(nvidia_display_controllers_are_found_in_sysfs) {
    auto root = std::filesystem::temp_directory_path() / ("runix-pci-" + std::to_string(getpid()));
    auto device = [&](const std::string& slot, const char* vendor, const char* id, const char* kind) {
        std::filesystem::create_directories(root / slot);
        std::ofstream(root / slot / "vendor") << vendor << "\n";
        std::ofstream(root / slot / "device") << id << "\n";
        std::ofstream(root / slot / "class") << kind << "\n";
    };
    device("0000:00:1f.3", "0x10de", "0x10fa", "0x040300");  // NVIDIA audio: not a GPU
    device("0000:03:00.0", "0x1002", "0x7480", "0x030000");  // AMD GPU
    CHECK(!system_probe::find_nvidia(root.string()));
    device("0000:01:00.0", "0x10de", "0x2684", "0x030000");  // NVIDIA GPU
    CHECK(system_probe::find_nvidia(root.string()) == 0x2684u);
    CHECK(!system_probe::find_nvidia("/nonexistent"));
    std::filesystem::remove_all(root);
}

TEST(disk_modules_follow_the_disk_to_its_controller) {
    namespace fs = std::filesystem;
    fs::path sys = fs::temp_directory_path() / ("runix-sys-" + std::to_string(getpid()));
    fs::remove_all(sys);
    auto loadable = [&](const std::string& name) {
        fs::create_directories(sys / "module" / name);
        std::ofstream(sys / "module" / name / "initstate") << "live\n";
    };
    auto driver = [&](const fs::path& device, const std::string& name, const char* module) {
        fs::create_directories(device);
        fs::create_directories(sys / "bus" / "drivers" / name);
        if (module != nullptr) {
            fs::create_directories(sys / "module" / module);
            if (!fs::exists(sys / "bus" / "drivers" / name / "module"))
                fs::create_directory_symlink(sys / "module" / module, sys / "bus" / "drivers" / name / "module");
        }
        fs::create_directory_symlink(sys / "bus" / "drivers" / name, device / "driver");
    };
    // A USB stick: sd_mod <- usb_storage <- (built-in usb) <- xhci_pci <- pcieport.
    fs::path pci = sys / "devices" / "pci0000:00";
    fs::path port = pci / "0000:00:1c.0";
    fs::path xhci = port / "0000:00:14.0";
    fs::path storage = xhci / "usb1" / "1-6" / "1-6:1.0";
    fs::path scsi = storage / "host6" / "target6:0:0" / "6:0:0:0";
    driver(port, "pcieport", "pcieportdrv");  // built in: no initstate
    driver(xhci, "xhci_hcd", "xhci_pci");
    driver(xhci / "usb1", "usb", nullptr);
    driver(storage, "usb-storage", "usb_storage");
    driver(scsi, "sd", "sd_mod");
    for (const char* module : {"xhci_pci", "usb_storage", "sd_mod"}) loadable(module);
    fs::create_directories(sys / "block" / "sdb");
    fs::create_directory_symlink(scsi, sys / "block" / "sdb" / "device");
    auto modules = system_probe::disk_modules(sys.string(), "/dev/sdb");
    CHECK((modules == std::vector<std::string>{"sd_mod", "usb_storage", "xhci_pci"}));
    CHECK(system_probe::disk_modules(sys.string(), "/dev/missing").empty());
    fs::remove_all(sys);
}

TEST(gpus_are_found_by_vendor) {
    namespace fs = std::filesystem;
    fs::path root = fs::temp_directory_path() / ("runix-gpus-" + std::to_string(getpid()));
    auto device = [&](const std::string& slot, const char* vendor, const char* kind) {
        fs::create_directories(root / slot);
        std::ofstream(root / slot / "vendor") << vendor << "\n";
        std::ofstream(root / slot / "device") << "0x1234\n";
        std::ofstream(root / slot / "class") << kind << "\n";
    };
    device("0000:00:02.0", "0x8086", "0x030000");  // Intel iGPU
    device("0000:03:00.0", "0x1002", "0x030000");  // AMD dGPU
    device("0000:00:1f.3", "0x8086", "0x040300");  // Intel audio: not a GPU
    auto found = system_probe::find_gpus(root.string());
    CHECK(found.amd && found.intel && !found.nvidia);
    fs::remove_all(root);

    auto value = settings();
    value.amd_gpu = true;
    value.disk_modules = {"sd_mod", "mmc_block", "sdhci_pci"};
    auto text = config::hardware(value);
    CHECK(has(text, "hardware.amdgpu.enable = true;"));
    CHECK(!has(text, "intelGraphics"));
    CHECK(has(text, "# Found on this machine for its root disk: mmc_block sdhci_pci."));
    CHECK(has(text, "\"mmc_block\""));
    // The usual list stays, and nothing is listed twice.
    CHECK(has(text, "\"nvme\""));
    std::size_t first = text.find("\"sd_mod\"");
    CHECK(text.find("\"sd_mod\"", text.find("\"sd_mod\"", first + 1) + 1) == std::string::npos);
    CHECK(!has(config::hardware(settings()), "Found on this machine"));
}

TEST(names_that_could_break_nix_are_rejected) {
    CHECK(config::valid_host("my-host1"));
    CHECK(!config::valid_host(""));
    CHECK(!config::valid_host("-host"));
    CHECK(!config::valid_host("a\"b"));
    CHECK(!config::valid_host("host.name"));
    CHECK(config::valid_user("alice_1"));
    CHECK(!config::valid_user("root"));
    CHECK(!config::valid_user("Alice"));
    CHECK(!config::valid_user("1alice"));
    CHECK(!config::valid_user("a b"));
}

// ---- json

TEST(json_reads_nested_values_and_escapes) {
    auto value = json::parse(R"({"a": [1, "x\"é", true, null], "b": {"c": 18446744073}})");
    CHECK(value.has_value());
    CHECK((*value)["a"][0].unsigned_number() == 1u);
    CHECK((*value)["a"][1].string() == std::string("x\"\xc3\xa9"));
    CHECK((*value)["a"][2].is_true());
    CHECK((*value)["a"][3].is_null());
    CHECK((*value)["b"]["c"].unsigned_number() == 18446744073ull);
    CHECK((*value)["missing"]["deeper"][4].is_null());
    CHECK(!json::parse("{\"a\": }"));
    CHECK(!json::parse("[1, 2] trailing"));
}

// ---- system

const char* lsblk_disks = R"({"blockdevices": [
  {"name": "/dev/sda", "size": 512110190592, "type": "disk", "ro": false, "model": "Samsung SSD "},
  {"name": "/dev/sdb", "size": "32000000000", "type": "disk", "ro": false, "model": null},
  {"name": "/dev/sdc", "size": 8000000000, "type": "disk", "ro": false, "model": "Too small"},
  {"name": "/dev/sdd", "size": 512110190592, "type": "disk", "ro": true, "model": "Read only"},
  {"name": "/dev/sr0", "size": 512110190592, "type": "rom", "ro": false, "model": "CD"}
]})";

TEST(only_usable_disks_are_offered) {
    auto disks = system_probe::parse_disks(lsblk_disks, std::nullopt);
    CHECK(disks.size() == 2);
    if (disks.size() == 2) {
        CHECK(disks[0].path == "/dev/sda");
        CHECK(disks[0].model == "Samsung SSD");
        CHECK(disks[1].path == "/dev/sdb");
        CHECK(disks[1].model == "Unknown disk");
    }
    auto without_live = system_probe::parse_disks(lsblk_disks, std::string("/dev/sda"));
    for (const auto& disk : without_live) CHECK(disk.path != "/dev/sda");
    CHECK(system_probe::parse_disks("not json", std::nullopt).empty());
}

TEST(partitions_are_read_from_lsblk) {
    const char* text = R"({"blockdevices": [{"name": "/dev/sda", "size": 512110190592, "type": "disk",
      "fstype": null, "parttypename": null, "mountpoint": null, "children": [
        {"name": "/dev/sda1", "size": 536870912, "type": "part", "fstype": "vfat",
         "parttypename": "EFI System", "mountpoint": null},
        {"name": "/dev/sda2", "size": "100000000000", "type": "part", "fstype": null,
         "parttypename": "Linux filesystem", "mountpoint": "/home"}
    ]}]})";
    auto partitions = system_probe::parse_partitions(text);
    CHECK(partitions.size() == 2);
    if (partitions.size() == 2) {
        const auto* esp = system_probe::existing_esp(partitions);
        CHECK(esp && esp->path == "/dev/sda1");
        CHECK(!partitions[0].mounted);
        CHECK(partitions[1].mounted);
        CHECK(!partitions[1].fstype);
    }
    CHECK(system_probe::parse_partitions("not json").empty());
}

TEST(scan_results_are_merged_by_name) {
    std::string output =
        "bssid / frequency / signal level / flags / ssid\n"
        "aa:bb:cc:dd:ee:01\t2412\t-40\t[WPA2-PSK-CCMP][ESS]\tHome Net\n"
        "aa:bb:cc:dd:ee:02\t5180\t-60\t[ESS]\tHome Net\n"
        "aa:bb:cc:dd:ee:03\t2437\t-70\t[ESS]\tCafe\n"
        "aa:bb:cc:dd:ee:04\t2437\t-80\t[ESS]\t\n";
    auto networks = system_probe::parse_scan(output);
    std::vector<system_probe::WifiNetwork> expected{{"Home Net", true}, {"Cafe", false}};
    CHECK(networks == expected);
}

TEST(missing_zoneinfo_directories_are_skipped) {
    auto directory = std::filesystem::temp_directory_path() / ("runix-zoneinfo-" + std::to_string(getpid()));
    std::filesystem::create_directories(directory);
    std::ofstream(directory / "UTC") << "";
    std::string found = directory.string();
    CHECK(system_probe::find_zoneinfo({std::nullopt, std::string("/nonexistent"), found}) == found);
    std::filesystem::remove_all(directory);
}

// ---- util

TEST(sizes_and_percentages_are_readable) {
    CHECK(util::format_size(512ull * 1024 * 1024 * 1024) == "512.0 GiB");
    CHECK(util::percent(1, 4) == "25.0%");
    CHECK(util::percent(1, 100000) == "<0.1%");
    CHECK(util::percent(0, 0) == "0%");
}

TEST(text_is_measured_in_characters) {
    CHECK(util::width("■ ok") == 4);
    CHECK(util::take("█▄x", 2) == "█▄");
    CHECK(util::fit("abcdefghij", 8) == "abcd... ");
    CHECK(util::fit("ab", 4) == "ab  ");
    auto lines = util::wrap("one two three four", 9);
    CHECK(lines.size() == 3 && lines[0] == "one two" && lines[1] == "three" && lines[2] == "four");
}

// ---- install

install::DiskLayout manual_layout(bool format_boot) {
    return install::DiskLayout::manual("/dev/sda1", "/dev/sda3", format_boot);
}

TEST(partition_names_follow_kernel_rules) {
    CHECK(install::partition_path("/dev/sda", 1) == "/dev/sda1");
    CHECK(install::partition_path("/dev/vdb", 2) == "/dev/vdb2");
    CHECK(install::partition_path("/dev/nvme0n1", 2) == "/dev/nvme0n1p2");
    CHECK(install::partition_path("/dev/mmcblk0", 1) == "/dev/mmcblk0p1");
}

TEST(manual_layouts_never_touch_the_partition_table) {
    CHECK(install::partition_commands(manual_layout(true), "/dev/sda").empty());
    for (bool format_boot : {true, false}) {
        for (auto filesystem : config::filesystems) {
            for (const auto& command : install::format_commands(manual_layout(format_boot), filesystem, "/dev/sda1", "/dev/sda3")) {
                for (const auto& argument : command) CHECK(argument != "/dev/sda");
            }
        }
    }
}

TEST(a_kept_boot_partition_is_not_formatted) {
    for (const auto& command : install::format_commands(manual_layout(false), config::Filesystem::Ext4, "/dev/sda1", "/dev/sda3")) {
        for (const auto& argument : command) CHECK(argument != "/dev/sda1");
    }
    bool formats = false;
    for (const auto& command : install::format_commands(manual_layout(true), config::Filesystem::Ext4, "/dev/sda1", "/dev/sda3")) {
        formats = formats || command[0] == "mkfs.fat";
    }
    CHECK(formats);
}

TEST(zfs_creates_the_pool_under_the_target_host_id) {
    auto commands = install::format_commands(install::DiskLayout::automatic(), config::Filesystem::Zfs,
                                             "/dev/sda1", "/dev/sda2", "1a2b3c4d");
    std::size_t hostid = commands.size(), create = commands.size(), dataset = commands.size();
    for (std::size_t i = 0; i < commands.size(); ++i) {
        const auto& command = commands[i];
        CHECK(command[0] != "mkfs.ext4" && command[0] != "mkfs.btrfs");
        if (command[0] == "zgenhostid" && command.back() == "1a2b3c4d") hostid = i;
        if (command[0] == "zpool" && command[1] == "create" && command.back() == "/dev/sda2" &&
            command[command.size() - 2] == "rpool") {
            create = i;
        }
        if (command[0] == "zfs" && command.back() == "rpool/root" && has(command[3], "legacy")) dataset = i;
    }
    // The host ID must be set before the pool records it.
    CHECK(hostid < create && create < dataset && dataset < commands.size());
    auto mount = install::mount_root_command(config::Filesystem::Zfs, "/dev/sda2");
    CHECK(mount.size() == 5 && mount[2] == "zfs" && mount[3] == "rpool/root" && mount[4] == "/mnt");
    CHECK(install::mount_root_command(config::Filesystem::Ext4, "/dev/sda2")[1] == "/dev/sda2");
}

TEST(automatic_layouts_use_the_new_partitions) {
    auto [boot, root] = install::targets(install::DiskLayout::automatic(), "/dev/nvme0n1");
    CHECK(boot == "/dev/nvme0n1p1");
    CHECK(root == "/dev/nvme0n1p2");
    auto commands = install::partition_commands(install::DiskLayout::automatic(), "/dev/sda");
    CHECK(commands.size() == 3);
    bool bios_boot = false;
    for (const auto& argument : commands.back()) bios_boot = bios_boot || argument == "-t3:ef02";
    CHECK(bios_boot);
}

TEST(runix_install_is_asked_for_nix_json_logs) {
    auto arguments = install::install_arguments("/mnt/etc/runix#host");
    bool json_format = false;
    for (std::size_t i = 0; i + 1 < arguments.size(); ++i) {
        json_format = json_format || (arguments[i] == "--log-format" && arguments[i + 1] == "internal-json");
    }
    CHECK(json_format);
    CHECK(arguments[0] == "runix-install");
}

TEST(control_codes_are_removed_from_output) {
    CHECK(install::clean_line("\x1b[31mbad\tline\r") == "bad line");
    CHECK(install::clean_line("\x1b]0;title\x07text") == "text");
}

// ---- nix log

TEST(nix_progress_counts_builds_and_fetches) {
    nixlog::Tracker tracker;
    CHECK(!tracker.fraction());
    CHECK(!tracker.feed(R"(@nix {"action":"start","id":1,"level":3,"type":102,"text":"","fields":[]})"));
    tracker.feed(R"(@nix {"action":"start","id":2,"level":3,"type":104,"text":"","fields":[]})");
    tracker.feed(R"(@nix {"action":"start","id":3,"level":3,"type":103,"text":"","fields":[]})");
    tracker.feed(R"(@nix {"action":"result","id":2,"type":105,"fields":[1,4,1,0]})");
    tracker.feed(R"(@nix {"action":"result","id":3,"type":105,"fields":[5,6,1,0]})");
    tracker.feed(R"(@nix {"action":"result","id":1,"type":106,"fields":[101,2097152]})");
    tracker.feed(R"(@nix {"action":"start","id":9,"level":4,"type":101,"text":"","fields":[]})");
    tracker.feed(R"(@nix {"action":"result","id":9,"type":105,"fields":[1048576,2097152,0,0]})");
    CHECK(tracker.builds().done == 1 && tracker.builds().expected == 4 && tracker.builds().running == 1);
    CHECK(tracker.paths().done == 5 && tracker.paths().expected == 6);
    CHECK(tracker.fraction() && *tracker.fraction() > 0.59 && *tracker.fraction() < 0.61);
    auto summary = tracker.summary();
    CHECK(has(summary, "1/4 built"));
    CHECK(has(summary, "5/6 fetched"));
    CHECK(has(summary, "1.0 MiB of 2.0 MiB downloaded"));
    // Bytes of a finished download still count.
    tracker.feed(R"(@nix {"action":"stop","id":9})");
    CHECK(tracker.downloaded() == 1048576);
}

TEST(nix_log_lines_are_unwrapped) {
    nixlog::Tracker tracker;
    auto started = tracker.feed(
        R"(@nix {"action":"start","id":7,"level":3,"type":105,"text":"building","fields":["/nix/store/0123456789abcdfghijklmnpqrsvwxyz-hello-2.12.drv","",1,1]})");
    CHECK(started == std::string("building hello-2.12"));
    CHECK(tracker.current() == "building hello-2.12");
    tracker.feed(R"(@nix {"action":"result","id":7,"type":104,"fields":["buildPhase"]})");
    CHECK(tracker.current() == "building hello-2.12 (buildPhase)");
    CHECK(tracker.feed(R"(@nix {"action":"result","id":7,"type":101,"fields":["\u001b[1mcompiling\u001b[0m"]})") ==
          std::string("  compiling"));
    CHECK(tracker.feed(R"(@nix {"action":"msg","level":0,"msg":"error: oops"})") == std::string("error: oops"));
    CHECK(!tracker.feed(R"(@nix {"action":"msg","level":5,"msg":"chatty"})"));
    CHECK(tracker.feed("runix-install: plain text") == std::string("runix-install: plain text"));
    CHECK(tracker.feed("@nix {broken") == std::string("@nix {broken"));
    tracker.feed(R"(@nix {"action":"stop","id":7})");
    CHECK(tracker.current().empty());
}

TEST(a_second_nix_run_adds_to_the_first) {
    nixlog::Tracker tracker;
    tracker.feed(R"(@nix {"action":"start","id":1,"level":3,"type":104,"text":"","fields":[]})");
    tracker.feed(R"(@nix {"action":"result","id":1,"type":105,"fields":[3,3,0,0]})");
    tracker.reset();
    // The next process starts numbering at 1 again.
    tracker.feed(R"(@nix {"action":"start","id":1,"level":3,"type":104,"text":"","fields":[]})");
    tracker.feed(R"(@nix {"action":"result","id":1,"type":105,"fields":[0,1,1,0]})");
    CHECK(tracker.builds().done == 3 && tracker.builds().expected == 4);
}

TEST(store_names_drop_the_hash) {
    CHECK(nixlog::store_name("copying path '/nix/store/0123456789abcdfghijklmnpqrsvwxyz-glibc-2.40' from 'x'") ==
          "glibc-2.40");
    CHECK(nixlog::store_name("no path here") == "no path here");
}

// ---- report

TEST(reports_hide_the_host_and_user_names) {
    CHECK(report::redact("user alice made alice_2 and alice", "alice", "<user>") ==
          "user <user> made alice_2 and <user>");
    CHECK(report::redact("runix-install /mnt/etc/runix", "runix", "<host>") == "runix-install /mnt/etc/<host>");
    report::Details details;
    details.error = "runix-install failed (exit status 1)";
    details.failed_step = "Install system";
    details.host = "laptop";
    details.user = "alice";
    auto text = report::build(details, "$ runix-install --flake /mnt/etc/runix#laptop\nhello alice\n");
    CHECK(has(text, "failed step: Install system"));
    CHECK(has(text, "/mnt/etc/runix#<host>"));
    CHECK(has(text, "hello <user>"));
    CHECK(!has(text, "laptop"));
    CHECK(!has(text, "alice"));
    // The default host name is also part of paths, so it is left alone.
    details.host = "runix";
    CHECK(has(report::build(details, "/mnt/etc/runix#runix\n"), "/mnt/etc/runix#runix"));
}

TEST(long_logs_keep_their_end) {
    report::Details details;
    std::string log;
    for (int line = 0; line < 100000; ++line) log += "line " + std::to_string(line) + "\n";
    auto text = report::build(details, log);
    CHECK(text.size() <= report::max_bytes + 1024);
    CHECK(has(text, "line 99999\n"));
    CHECK(!has(text, "line 0\n"));
    CHECK(has(text, "(end only)"));
}

// ---- snake

TEST(the_snake_moves_and_grows_on_food) {
    snake::Game game(10, 5, 1);
    auto head = game.body().front();
    CHECK(game.body().size() == 3);
    game.place_food({head.x + 1, head.y});
    std::size_t food = game.food().size();
    game.step();
    CHECK(game.body().front() == (snake::Point{head.x + 1, head.y}));
    CHECK(game.body().size() == 4);
    CHECK(game.score() == 1 && game.best() == 1);
    // Eating one pellet never leaves the board empty.
    CHECK(!game.food().empty() && game.food().size() <= food);
    game.step();
    CHECK(game.body().size() == 4);
}

TEST(walls_end_the_game_and_reversing_is_ignored) {
    snake::Game game(6, 3, 2);
    game.turn(snake::Direction::Left);
    game.step();
    CHECK(!game.over());
    for (int i = 0; i < 10 && !game.over(); ++i) game.step();
    CHECK(game.over());
    int best = game.best();
    game.restart();
    CHECK(!game.over() && game.score() == 0 && game.best() == best);
}

TEST(the_snake_dies_on_its_own_body) {
    snake::Game game(10, 6, 3);
    auto head = game.body().front();
    for (int i = 1; i <= 2; ++i) game.place_food({head.x + i, head.y});
    game.step();
    game.step();
    CHECK(game.body().size() == 5);
    game.turn(snake::Direction::Down);
    game.step();
    game.turn(snake::Direction::Left);
    game.step();
    game.turn(snake::Direction::Up);
    game.step();
    CHECK(game.over());
}

TEST(bonus_pellets_are_capped) {
    snake::Game game(10, 6, 4);
    for (int i = 0; i < 20; ++i) game.add_food();
    CHECK(game.food().size() == snake::Game::max_food);
}

// ---- physics

TEST(xpbd_bounces_off_walls_and_keeps_links) {
    xpbd::World world;
    world.width = 10;
    world.height = 10;
    world.gravity = {0, 0};
    xpbd::Particle ball;
    ball.position = {1, 5};
    ball.velocity = {-20, 0};
    ball.gravity_scale = 0;
    world.particles.push_back(ball);
    world.step(0.05);
    // Full restitution: it comes back off the left wall at the same speed.
    CHECK(world.particles[0].velocity.x > 19 && world.particles[0].velocity.x < 21);
    CHECK(world.particles[0].position.x >= 0.5 - 1e-9);

    // A stiff link holds two particles at its rest length as they fall.
    xpbd::World falling;
    falling.width = 40;
    falling.height = 40;
    xpbd::Particle a;
    a.position = {10, 5};
    xpbd::Particle b;
    b.position = {13, 5};
    falling.particles = {a, b};
    falling.links.push_back({0, 1, 2.0, 0.0});
    for (int i = 0; i < 20; ++i) falling.step(1.0 / 60);
    double length = (falling.particles[0].position - falling.particles[1].position).length();
    CHECK(length > 1.98 && length < 2.02);
    CHECK(falling.particles[0].position.y > 5.5);  // gravity pulled them down
}

TEST(xpbd_reports_box_hits_and_pushes_out) {
    xpbd::World world;
    world.width = 20;
    world.height = 20;
    world.gravity = {0, 0};
    world.boxes.push_back({{8, 8}, {12, 10}, {}});
    xpbd::Particle ball;
    ball.position = {10, 6};
    ball.velocity = {0, 30};
    ball.gravity_scale = 0;
    world.particles.push_back(ball);
    bool hit = false;
    for (int i = 0; i < 10 && !hit; ++i) {
        world.step(1.0 / 60);
        hit = !world.hits.empty();
    }
    CHECK(hit);
    CHECK(world.particles[0].position.y <= 7.5 + 1e-6);
    CHECK(world.particles[0].velocity.y < 0);  // bounced back up
}

TEST(bricks_serves_breaks_and_loses_lives) {
    games::Bricks bricks(40, 12, 7);
    int total = bricks.bricks_left();
    CHECK(total > 0 && bricks.lives() == 3 && !bricks.served());
    // The ball rides the paddle until served.
    for (int i = 0; i < 5; ++i) bricks.input(games::Input::Right);
    for (int i = 0; i < 10; ++i) bricks.update(1.0 / 60);
    CHECK(bricks.paddle_x() > 20);
    CHECK(!bricks.served());
    bricks.input(games::Input::Action);
    CHECK(bricks.served());
    // Straight up into the wall: a brick breaks and debris appears.
    bricks.world().particles[0].velocity = {0, -bricks.ball_speed()};
    bricks.world().particles[0].position.x = bricks.paddle_x();
    for (int i = 0; i < 120 && bricks.bricks_left() == total; ++i) bricks.update(1.0 / 60);
    CHECK(bricks.bricks_left() == total - 1);
    CHECK(bricks.score() >= 10);
    CHECK(bricks.world().particles.size() >= 3);
    // Dropping the ball costs a life and puts it back on the paddle.
    bricks.world().particles[0].position = {5, 40};
    bricks.update(1.0 / 60);
    CHECK(bricks.lives() == 2 && !bricks.served());
}

TEST(fetch_catches_misses_and_dodges) {
    games::Fetch fetch(40, 10, 3);
    fetch.stop_spawning();
    int centre = fetch.basket_x() + fetch.basket_width() / 2;
    fetch.drop("glibc", false, centre - 3);
    for (int i = 0; i < 400 && !fetch.items().empty(); ++i) fetch.update(0.01);
    CHECK(fetch.score() == 1 && fetch.lives() == 3);
    // A good package that falls past the basket costs a life.
    fetch.drop("bash", false, 0);
    if (fetch.basket_x() < 8) {
        for (int i = 0; i < 10; ++i) fetch.input(games::Input::Right);
    }
    for (int i = 0; i < 400 && !fetch.items().empty(); ++i) fetch.update(0.01);
    CHECK(fetch.lives() == 2);
    // A broken one is safe to let fall, and costs a life when caught.
    centre = fetch.basket_x() + fetch.basket_width() / 2;
    fetch.drop("corrupt nar", true, centre - 6);
    for (int i = 0; i < 400 && !fetch.items().empty(); ++i) fetch.update(0.01);
    CHECK(fetch.lives() == 1);
}

// ---- ui

TEST(every_segment_gets_a_cell) {
    auto cells = ui::segment_cells({1, 1000000, 0}, 40);
    CHECK(cells[0] >= 1);
    CHECK(cells[2] == 0);
    CHECK(cells[0] + cells[1] + cells[2] == 40);
    CHECK(ui::segment_cells({}, 10).empty());
}

// ---- app

std::shared_ptr<Queue> queue = std::make_shared<Queue>();

App demo_app() {
    Options options;
    options.demo = true;
    options.flake = "github:runix-community/runix";
    options.zoneinfo = "/nonexistent";
    return App(options, queue);
}

void press(App& app, Key key) {
    app.on_key(key);
}
void type(App& app, const std::string& text) {
    for (char c : text) press(app, Key::character(std::string(1, c)));
}
Key enter_key() {
    return Key::of(Key::Code::Enter);
}

TEST(manual_partitioning_needs_a_root) {
    App app = demo_app();
    app.enter(Screen::Disk);
    press(app, enter_key());
    CHECK(app.screen == Screen::Bootloader);
    press(app, enter_key());
    CHECK(app.screen == Screen::Kernel);
    press(app, enter_key());
    CHECK(app.screen == Screen::Partitioning);
    press(app, Key::of(Key::Code::Down));
    CHECK(app.manual());
    // The demo ESP is picked as boot and kept.
    CHECK(app.boot_partition && app.boot_partition->ends_with("p1"));
    CHECK(!app.format_boot);
    press(app, enter_key());
    CHECK(app.screen == Screen::Partitions);
    press(app, enter_key());
    CHECK(app.screen == Screen::Partitions);
    CHECK(app.partition_error && has(*app.partition_error, "root"));
    press(app, Key::of(Key::Code::Down));
    press(app, Key::of(Key::Code::Down));
    press(app, Key::character("r"));
    press(app, enter_key());
    CHECK(app.screen == Screen::Filesystem);
    auto layout = app.layout();
    CHECK(layout.kind == install::DiskLayout::Kind::Manual);
    CHECK(layout.root.ends_with("p3"));
    CHECK(!layout.format_boot);
    press(app, Key::of(Key::Code::Esc));
    CHECK(app.screen == Screen::Partitions);
}

TEST(automatic_partitioning_skips_the_partition_screen) {
    App app = demo_app();
    app.enter(Screen::Disk);
    press(app, enter_key());
    press(app, enter_key());
    press(app, enter_key());
    CHECK(app.screen == Screen::Partitioning);
    CHECK(app.layout() == install::DiskLayout::automatic());
    press(app, enter_key());
    CHECK(app.screen == Screen::Filesystem);
    press(app, Key::of(Key::Code::Esc));
    CHECK(app.screen == Screen::Partitioning);
}

TEST(grub_on_bios_needs_a_bios_boot_partition) {
    App app = demo_app();
    app.enter(Screen::Disk);
    app.boot_mode = config::BootMode::Bios;
    app.bootloader_list.select(1);
    app.partitioning_list.select(1);
    app.enter(Screen::Partitions);
    app.root_partition = app.partitions.back().path;
    CHECK(has(app.check_manual(), "BIOS boot"));
    app.bootloader_list.select(0);
    CHECK(app.check_manual().empty());
}

TEST(the_account_form_validates_before_moving_on) {
    App app = demo_app();
    app.enter(Screen::Account);
    app.focus = 3;
    press(app, enter_key());
    CHECK(app.screen == Screen::Account);
    CHECK(app.form_error.has_value());
    app.focus = 1;
    type(app, "alice");
    app.focus = 2;
    type(app, "secret");
    app.focus = 3;
    type(app, "secret");
    press(app, enter_key());
    CHECK(app.screen == Screen::Timezone);
}

TEST(ctrl_c_is_ignored_while_installing) {
    App app = demo_app();
    app.screen = Screen::Installing;
    press(app, Key::of(Key::Code::CtrlC));
    CHECK(!app.modal);
    app.screen = Screen::Disk;
    press(app, Key::of(Key::Code::CtrlC));
    CHECK(app.modal && app.modal->kind == Modal::Kind::Quit);
}

TEST(the_review_needs_the_confirmation_word) {
    App app = demo_app();
    app.enter(Screen::Disk);
    app.enter(Screen::Review);
    press(app, enter_key());
    CHECK(app.screen == Screen::Review);
    type(app, "ERASE");
    press(app, enter_key());
    CHECK(app.screen == Screen::Installing);
}

TEST(overall_progress_follows_nix) {
    App app = demo_app();
    app.phase = 4;
    double before = app.overall_progress();
    app.nix.fraction = 0.5;
    double halfway = app.overall_progress();
    CHECK(halfway > before);
    CHECK(halfway > 0.5 && halfway < 0.6);
    app.phase_done = true;
    CHECK(app.overall_progress() == 1.0);
}

TEST(uploading_the_log_asks_first) {
    App app = demo_app();
    app.screen = Screen::Failed;
    app.error = "demo failure";
    press(app, Key::character("u"));
    CHECK(app.modal && app.modal->kind == Modal::Kind::UploadLog);
    press(app, Key::of(Key::Code::Esc));
    CHECK(!app.modal && !app.uploading);
    press(app, Key::character("u"));
    press(app, enter_key());
    CHECK(app.uploading);
    // Demo mode answers with a made-up address instead of uploading.
    for (int wait = 0; wait < 40 && app.uploading; ++wait) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        while (auto message = queue->pop()) app.on_message(std::move(*message));
    }
    CHECK(!app.uploading);
    CHECK(app.upload_url && has(*app.upload_url, "example"));
}

TEST(the_filesystem_screen_refuses_zfs_with_cachyos) {
    App app = demo_app();
    app.kernel_list.select(5);
    CHECK(config::from_cachyos(app.kernel()));
    app.enter(Screen::Filesystem);
    app.filesystem_list.select(2);
    CHECK(app.filesystem() == config::Filesystem::Zfs);
    press(app, enter_key());
    CHECK(app.screen == Screen::Filesystem);
    CHECK(app.filesystem_error.has_value());
    app.kernel_list.select(0);
    press(app, enter_key());
    CHECK(app.screen == Screen::Account);
    CHECK(!app.filesystem_error);
}

Message nix_progress(std::uint64_t completed, const std::string& current) {
    Message message{Message::Kind::Install};
    message.update.kind = install::Update::Kind::Nix;
    message.update.nix.completed = completed;
    message.update.nix.current = current;
    return message;
}

int count_glyph(const games::Frame& frame, const std::string& glyph) {
    int count = 0;
    for (const auto& cell : frame.cells) count += cell.glyph == glyph ? 1 : 0;
    return count;
}

TEST(the_hub_never_hides_how_the_install_ends) {
    App app = demo_app();
    app.screen = Screen::Installing;
    press(app, Key::character("g"));
    CHECK(app.hub_open && !app.game);
    press(app, enter_key());  // Snake is first.
    CHECK(app.game && app.playing());
    // A finished package reaches the game: Snake gains a pellet.
    int pellets = count_glyph(app.game->frame(), "▐");
    app.on_message(nix_progress(1, "fetching glibc-2.40"));
    CHECK(count_glyph(app.game->frame(), "▐") == pellets + 1);
    // Success waits for Enter instead of yanking the board away.
    Message done{Message::Kind::Install};
    done.update.kind = install::Update::Kind::Finished;
    app.on_message(done);
    CHECK(app.screen == Screen::Installing && app.done_while_playing && !app.playing());
    press(app, enter_key());
    CHECK(app.screen == Screen::Done && !app.in_games());

    // A failure replaces the games at once.
    App failing = demo_app();
    failing.screen = Screen::Installing;
    press(failing, Key::character("g"));
    Message failed{Message::Kind::Install};
    failed.update.kind = install::Update::Kind::Finished;
    failed.update.error = "boom";
    failing.on_message(failed);
    CHECK(failing.screen == Screen::Failed && !failing.in_games());

    // Esc steps back: game, then menu, then the log. Ctrl+C never quits.
    App leaving = demo_app();
    leaving.screen = Screen::Installing;
    press(leaving, Key::character("g"));
    press(leaving, Key::of(Key::Code::Down));
    press(leaving, enter_key());
    CHECK(leaving.game && leaving.game_index == 1);
    press(leaving, Key::of(Key::Code::CtrlC));
    CHECK(!leaving.modal && leaving.game);
    press(leaving, Key::of(Key::Code::Esc));
    CHECK(!leaving.game && leaving.hub_open);
    press(leaving, Key::of(Key::Code::Esc));
    CHECK(!leaving.in_games() && leaving.screen == Screen::Installing);
}

TEST(fetch_drops_the_packages_nix_installs) {
    App app = demo_app();
    app.screen = Screen::Installing;
    press(app, Key::character("g"));
    press(app, Key::of(Key::Code::Down));
    press(app, enter_key());
    auto* fetch = dynamic_cast<games::Fetch*>(app.game.get());
    CHECK(fetch != nullptr);
    if (!fetch) return;
    app.on_message(nix_progress(1, "fetching openssl-3.6 (+2 more)"));
    CHECK(fetch->queued() == 1);
    CHECK(games::package_name("building hello-2.12 (buildPhase)") == "hello-2.12");
}

TEST(chroot_is_offered_after_installing) {
    App app = demo_app();
    app.screen = Screen::Done;
    app.done_list.select(2);
    press(app, enter_key());
    // Demo mode explains instead of opening a shell.
    CHECK(app.modal && app.modal->kind == Modal::Kind::Notice);
    CHECK(!app.external);
}

}  // namespace

int main() {
    for (const auto& [name, test] : registry()) {
        int before = failures;
        test();
        if (failures != before) std::fprintf(stderr, "FAILED: %s\n", name);
    }
    std::printf("%d checks, %d failed, %zu tests\n", checks, failures, registry().size());
    return failures == 0 ? 0 : 1;
}
