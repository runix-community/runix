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
