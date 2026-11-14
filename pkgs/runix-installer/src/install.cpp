#include "install.hpp"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <memory>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>

#include "nixlog.hpp"
#include "process.hpp"
#include "system.hpp"
#include "util.hpp"

namespace fs = std::filesystem;

namespace install {

namespace {

constexpr const char* wifi_config = "/var/lib/runix/wifi/wpa_supplicant.conf";

/// Thrown to stop the installation at the first failed step.
struct Failure {
    std::string message;
};

}  // namespace

std::string partition_path(const std::string& disk, unsigned number) {
    bool digit = !disk.empty() && disk.back() >= '0' && disk.back() <= '9';
    return disk + (digit ? "p" : "") + std::to_string(number);
}

Commands partition_commands(const DiskLayout& layout, const std::string& disk) {
    if (layout.kind == DiskLayout::Kind::Manual) return {};
    return {
        {"wipefs", "-af", disk},
        {"sgdisk", "--zap-all", disk},
        {"sgdisk", "-n3:1MiB:+1MiB", "-t3:ef02", "-c3:RUNIX_BIOS", "-n1:2MiB:+1GiB", "-t1:ef00",
         "-c1:RUNIX_BOOT", "-n2:0:0", "-t2:8300", "-c2:RUNIX_ROOT", disk},
    };
}

std::pair<std::string, std::string> targets(const DiskLayout& layout, const std::string& disk) {
    if (layout.kind == DiskLayout::Kind::Manual) return {layout.boot, layout.root};
    return {partition_path(disk, 1), partition_path(disk, 2)};
}

Commands format_commands(const DiskLayout& layout, config::Filesystem root_fs, const std::string& boot,
                         const std::string& root) {
    Commands commands;
    bool format_boot = layout.kind == DiskLayout::Kind::Automatic || layout.format_boot;
    if (format_boot) commands.push_back({"mkfs.fat", "-F32", "-n", "RUNIXBOOT", boot});
    // Old signatures on a reused partition would confuse blkid later.
    commands.push_back({"wipefs", "-a", root});
    if (root_fs == config::Filesystem::Ext4) {
        commands.push_back({"mkfs.ext4", "-q", "-F", "-L", "runix-root", root});
    } else {
        commands.push_back({"mkfs.btrfs", "-q", "-f", "-L", "runix-root", root});
    }
    return commands;
}

std::vector<std::string> install_arguments(const std::string& flake_reference) {
    return {"runix-install", "--flake", flake_reference, "--root", target,
            "--", "--accept-flake-config", "--log-format", "internal-json"};
}

std::string clean_line(const std::string& text) {
    return nixlog::clean(text);
}

namespace {

class Runner {
public:
    Runner(Sender send, bool keep_log) : send_(std::move(send)) {
        if (keep_log) log_ = std::fopen(log_path, "w");
    }
    ~Runner() {
        if (log_) std::fclose(log_);
    }
    Runner(const Runner&) = delete;
    Runner& operator=(const Runner&) = delete;

    void line(const std::string& text) {
        if (log_) {
            std::fprintf(log_, "%s\n", text.c_str());
            std::fflush(log_);
        }
        Update update{Update::Kind::Line};
        update.text = text;
        send_(std::move(update));
    }

    void phase(std::size_t index) {
        Update update{Update::Kind::Phase};
        update.phase = index;
        send_(std::move(update));
        line(std::string("==> ") + phases[index]);
    }

    void finished(const std::string& error) {
        Update update{Update::Kind::Finished};
        update.error = error;
        send_(std::move(update));
    }

    /// One line of output from a command, which may be a Nix log message.
    void output(const std::string& raw) {
        // runix-install starts a new Nix process for each build.
        if (raw.rfind("runix-install: building", 0) == 0) tracker_.reset();
        bool from_nix = raw.rfind("@nix ", 0) == 0;
        if (from_nix && log_) {
            // The log file keeps the raw messages for debugging.
            std::fprintf(log_, "%s\n", raw.c_str());
        }
        auto shown = tracker_.feed(raw);
        if (shown) {
            for (const auto& piece : util::split(*shown, '\n')) {
                if (piece.empty()) continue;
                if (from_nix) {
                    Update update{Update::Kind::Line};
                    update.text = piece;
                    send_(std::move(update));
                } else {
                    line(piece);
                }
            }
        }
        if (from_nix) report_nix();
    }

    void run(const std::vector<std::string>& arguments, const process::Environment& environment = {}) {
        std::string shown = "$";
        for (const auto& argument : arguments) shown += " " + argument;
        line(shown);
        std::string start_error;
        auto status = process::stream(
            arguments, environment, [this](const std::string& text) { output(text); }, start_error);
        if (!status) throw Failure{start_error.empty() ? "could not start " + arguments[0] : start_error};
        if (*status != 0) throw Failure{arguments[0] + " failed (" + process::describe_status(*status) + ")"};
    }

    void run_all(const Commands& commands) {
        for (const auto& command : commands) run(command);
    }

private:
    Sender send_;
    std::FILE* log_ = nullptr;
    nixlog::Tracker tracker_;
    NixStatus last_;
    std::chrono::steady_clock::time_point last_sent_{};

    void report_nix() {
        NixStatus status{tracker_.fraction(), tracker_.summary(), tracker_.current()};
        auto now = std::chrono::steady_clock::now();
        // Downloads report many times a second; the screen needs ten updates at most.
        bool same_text = status.summary == last_.summary && status.current == last_.current;
        if (status == last_ || (same_text && now - last_sent_ < std::chrono::milliseconds(100))) return;
        last_ = status;
        last_sent_ = now;
        Update update{Update::Kind::Nix};
        update.nix = status;
        send_(std::move(update));
    }
};

std::string capture_trimmed(const std::vector<std::string>& arguments) {
    auto output = process::capture(arguments);
    if (!output.started) throw Failure{output.start_error};
    if (output.status != 0) {
        throw Failure{arguments[0] + " failed (" + process::describe_status(output.status) + ")"};
    }
    return util::trim(output.out);
}

std::string hash_password(const std::string& password) {
    auto output = process::capture({"mkpasswd", "-m", "yescrypt", "--stdin"}, password);
    std::string hash = util::trim(output.out);
    if (!output.started) throw Failure{output.start_error};
    if (output.status != 0 || hash.empty()) throw Failure{"mkpasswd could not hash the password"};
    return hash;
}

void wait_for_block_device(const std::string& path) {
    for (int attempt = 0; attempt < 100; ++attempt) {
        struct stat info {};
        if (stat(path.c_str(), &info) == 0 && S_ISBLK(info.st_mode)) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    throw Failure{"device did not appear: " + path};
}

void make_directories(const std::string& path, fs::perms mode = fs::perms::none) {
    std::error_code error;
    fs::create_directories(path, error);
    if (error) throw Failure{"could not create " + path + ": " + error.message()};
    if (mode != fs::perms::none) fs::permissions(path, mode, error);
}

void write_file(const std::string& path, const std::string& contents) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file << contents;
    file.close();
    if (!file) throw Failure{"could not write " + path};
}

void write_secret(const std::string& path, const std::string& contents) {
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) throw Failure{"could not create " + path + ": " + std::strerror(errno)};
    bool ok = write(fd, contents.data(), contents.size()) == static_cast<ssize_t>(contents.size());
    ok = close(fd) == 0 && ok;
    if (!ok) throw Failure{"could not write " + path};
}

void install(const Plan& plan, Runner& runner) {
    const std::string& disk = plan.disk;
    auto [boot, root] = targets(plan.layout, disk);
    bool automatic = plan.layout.kind == DiskLayout::Kind::Automatic;

    runner.phase(0);
    unmount(false);
    // A manual layout only formats its own partitions, so other mounted
    // partitions on the same disk are fine there.
    std::vector<std::string> busy = automatic ? std::vector<std::string>{disk} : std::vector<std::string>{boot, root};
    for (const auto& device : busy) {
        if (!capture_trimmed({"lsblk", "-nrpo", "MOUNTPOINT", device}).empty()) {
            throw Failure{device + " is in use; unmount it and try again"};
        }
    }
    auto partitioning = partition_commands(plan.layout, disk);
    runner.run_all(partitioning);
    if (!partitioning.empty()) {
        // The partitions may already be visible, so a failure here is not fatal.
        try {
            runner.run({"blockdev", "--rereadpt", disk});
        } catch (const Failure&) {
        }
    }
    wait_for_block_device(boot);
    wait_for_block_device(root);

    runner.phase(1);
    runner.run_all(format_commands(plan.layout, plan.root_fs, boot, root));

    runner.phase(2);
    make_directories(target);
    runner.run({"mount", root, target});
    std::string boot_target = std::string(target) + "/boot";
    make_directories(boot_target);
    runner.run({"mount", boot, boot_target});

    runner.phase(3);
    std::string secrets = std::string(target) + "/var/lib/runix/secrets";
    make_directories(secrets, fs::perms::owner_all);
    write_secret(std::string(target) + config::password_hash_path(plan.user), hash_password(plan.password));

    config::Settings settings;
    settings.flake = plan.flake;
    settings.host = plan.host;
    settings.user = plan.user;
    settings.timezone = plan.timezone;
    settings.desktop = plan.desktop;
    settings.network = plan.network;
    settings.root_uuid = capture_trimmed({"blkid", "-s", "UUID", "-o", "value", root});
    settings.root_fs = plan.root_fs;
    settings.boot_uuid = capture_trimmed({"blkid", "-s", "UUID", "-o", "value", boot});
    settings.boot_mode = plan.boot_mode;
    settings.loader = plan.loader;
    settings.disk = plan.disk;
    settings.cpu = system_probe::cpu_vendor();
    if (settings.root_uuid.empty() || settings.boot_uuid.empty()) {
        throw Failure{"blkid returned no filesystem UUID"};
    }
    std::string flake_directory = std::string(target) + "/etc/runix";
    make_directories(flake_directory);
    write_file(flake_directory + "/flake.nix", config::flake(settings));
    write_file(flake_directory + "/hardware.nix", config::hardware(settings));
    write_file(flake_directory + "/configuration.nix", config::configuration(settings));

    // Keep the network joined in the live session for the first boot.
    std::error_code error;
    if (plan.network == config::Network::Wifi && fs::is_regular_file(wifi_config, error)) {
        runner.run({"install", "-D", "-m0600", wifi_config, std::string(target) + wifi_config});
    }

    runner.phase(4);
    // The live system runs from RAM, so builds must use the target disk.
    std::string build_directory = std::string(target) + "/var/tmp";
    make_directories(build_directory);
    runner.run(install_arguments(flake_directory + "#" + plan.host), {{"TMPDIR", build_directory}});

    runner.phase(5);
    for (const auto& entry : fs::directory_iterator(build_directory, error)) {
        std::error_code ignored;
        fs::remove_all(entry.path(), ignored);
    }
    runner.run({"sync"});
}

/// Plays a believable installation, including Nix's log, without touching anything.
void demo(bool fail, Runner& runner) {
    using namespace std::chrono_literals;
    const std::string hash = "0123456789abcdfghijklmnpqrsvwxyz";
    auto nix = [&](const std::string& message) { runner.output("@nix " + message); };
    for (std::size_t index = 0; index < phases.size(); ++index) {
        runner.phase(index);
        if (index != 4) {
            for (int step = 1; step <= 6; ++step) {
                runner.line(std::string("demo: ") + phases[index] + " step " + std::to_string(step) + " of 6");
                std::this_thread::sleep_for(100ms);
            }
            continue;
        }
        runner.output("runix-install: building configuration demo in the target store");
        const int paths = 48;
        const int builds = 6;
        const std::uint64_t path_bytes = 24ull * 1024 * 1024;
        nix(R"({"action":"start","id":1,"level":3,"type":102,"text":"","fields":[]})");
        nix(R"({"action":"start","id":2,"level":3,"type":104,"text":"","fields":[]})");
        nix(R"({"action":"start","id":3,"level":3,"type":103,"text":"","fields":[]})");
        nix(R"({"action":"result","id":1,"type":106,"fields":[101,)" + std::to_string(paths * path_bytes) + "]}");
        int next = 10;
        for (int path = 1; path <= paths; ++path) {
            std::string store = "/nix/store/" + hash + "-demo-package-" + std::to_string(path);
            int substitute = next++;
            int transfer = next++;
            nix(R"({"action":"start","id":)" + std::to_string(substitute) +
                R"(,"level":4,"type":108,"text":"copying path","fields":[")" + store +
                R"(","https://cache.nixos.org"]})");
            nix(R"({"action":"result","id":3,"type":105,"fields":[)" + std::to_string(path - 1) + "," +
                std::to_string(paths) + ",1,0]}");
            nix(R"({"action":"start","id":)" + std::to_string(transfer) +
                R"(,"level":4,"type":101,"text":"downloading","fields":[]})");
            for (int chunk = 1; chunk <= 4; ++chunk) {
                nix(R"({"action":"result","id":)" + std::to_string(transfer) + R"(,"type":105,"fields":[)" +
                    std::to_string(path_bytes * chunk / 4) + "," + std::to_string(path_bytes) + ",0,0]}");
                std::this_thread::sleep_for(15ms);
            }
            nix(R"({"action":"stop","id":)" + std::to_string(transfer) + "}");
            nix(R"({"action":"stop","id":)" + std::to_string(substitute) + "}");
        }
        nix(R"({"action":"result","id":3,"type":105,"fields":[)" + std::to_string(paths) + "," +
            std::to_string(paths) + ",0,0]}");
        for (int build = 1; build <= builds; ++build) {
            int id = next++;
            std::string drv = "/nix/store/" + hash + "-runix-demo-" + std::to_string(build) + ".drv";
            nix(R"({"action":"result","id":2,"type":105,"fields":[)" + std::to_string(build - 1) + "," +
                std::to_string(builds) + ",1,0]}");
            nix(R"({"action":"start","id":)" + std::to_string(id) +
                R"(,"level":3,"type":105,"text":"building","fields":[")" + drv + R"(","",1,1]})");
            for (int step = 1; step <= 5; ++step) {
                nix(R"({"action":"result","id":)" + std::to_string(id) +
                    R"(,"type":101,"fields":["demo build output line )" + std::to_string(step) + "\"]}");
                std::this_thread::sleep_for(120ms);
            }
            nix(R"({"action":"stop","id":)" + std::to_string(id) + "}");
            if (fail && build == builds / 2) {
                nix(R"({"action":"msg","level":0,"msg":"error: builder for 'runix-demo' failed with exit code 1"})");
                throw Failure{"demo: simulated failure"};
            }
        }
        nix(R"({"action":"result","id":2,"type":105,"fields":[)" + std::to_string(builds) + "," +
            std::to_string(builds) + ",0,0]}");
        for (int id = 1; id <= 3; ++id) nix(R"({"action":"stop","id":)" + std::to_string(id) + "}");
    }
}

}  // namespace

void unmount(bool demo) {
    if (demo) return;
    process::capture({"umount", "-R", target});
}

void spawn(Plan plan, bool demo_mode, bool demo_fail, Sender send) {
    std::thread([plan = std::move(plan), demo_mode, demo_fail, send = std::move(send)]() {
        Runner runner(send, !demo_mode);
        std::string error;
        try {
            if (demo_mode) {
                demo(demo_fail, runner);
            } else {
                install(plan, runner);
            }
        } catch (const Failure& failure) {
            error = failure.message;
        } catch (const std::exception& exception) {
            error = exception.what();
        }
        if (!error.empty()) runner.line("error: " + error);
        runner.finished(error);
    }).detach();
}

}  // namespace install
