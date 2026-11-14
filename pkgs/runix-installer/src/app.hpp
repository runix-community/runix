// Installer state and key handling. Drawing lives in ui.cpp.
#pragma once

#include <array>
#include <chrono>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "config.hpp"
#include "install.hpp"
#include "system.hpp"

inline constexpr const char* confirmation_word = "ERASE";
/// Partitions smaller than this cannot hold a boot partition.
inline constexpr std::uint64_t minimum_boot_bytes = 256ull * 1024 * 1024;
/// Partitions smaller than this cannot hold a root filesystem.
inline constexpr std::uint64_t minimum_root_bytes = 12ull * 1024 * 1024 * 1024;

enum class Screen {
    Welcome,
    Network,
    Disk,
    Bootloader,
    Partitioning,
    Partitions,
    Filesystem,
    Account,
    Timezone,
    Desktop,
    Connection,
    Review,
    Installing,
    Failed,
    Done,
};

inline constexpr std::array<Screen, 12> wizard{
    Screen::Welcome,  Screen::Network, Screen::Disk,     Screen::Bootloader,
    Screen::Partitioning, Screen::Partitions, Screen::Filesystem, Screen::Account,
    Screen::Timezone, Screen::Desktop, Screen::Connection, Screen::Review,
};

const char* title(Screen screen);

inline constexpr std::array<const char*, 4> done_actions{
    "Reboot now",
    "Power off",
    "Open a shell in the installed system (chroot)",
    "Exit to shell",
};

enum class Exit { Shell, Reboot, Poweroff };
enum class OnlineState { Checking, Online, Offline };

struct Key {
    enum class Code { Char, Enter, Esc, Up, Down, Tab, BackTab, Backspace, PageUp, PageDown, CtrlC, Other };
    Code code = Code::Other;
    /// The typed character, as UTF-8, for Code::Char.
    std::string text;

    static Key of(Code code) { return {code, ""}; }
    static Key character(std::string text) { return {Code::Char, std::move(text)}; }
    bool is(char c) const { return code == Code::Char && text.size() == 1 && text[0] == c; }
};

struct Input {
    std::string value;
    bool masked = false;

    std::string display() const;
    /// Returns whether the value changed.
    bool handle(const Key& key);
};

struct ListState {
    std::optional<std::size_t> selected = 0;
    std::size_t offset = 0;

    void select(std::optional<std::size_t> index) { selected = index; }
    void move(std::size_t length, bool forward);
};

struct Message {
    enum class Kind { Online, Scanned, Connected, Install, Uploaded };
    Kind kind;
    bool online = false;
    std::vector<system_probe::WifiNetwork> networks;
    /// For Connected and Uploaded: empty on success.
    std::string error;
    /// For Uploaded: where the log can be read.
    std::string url;
    install::Update update{};
};

/// Messages from worker threads to the UI thread.
class Queue {
public:
    void push(Message message) {
        std::lock_guard lock(mutex_);
        messages_.push_back(std::move(message));
    }
    std::optional<Message> pop() {
        std::lock_guard lock(mutex_);
        if (messages_.empty()) return std::nullopt;
        Message message = std::move(messages_.front());
        messages_.pop_front();
        return message;
    }

private:
    std::mutex mutex_;
    std::deque<Message> messages_;
};

/// Work that needs the real terminal, so the main loop suspends the UI for it.
struct External {
    enum class Kind { EditPartitions, Chroot };
    Kind kind;
    /// The disk for cfdisk, or the mounted root for the chroot.
    std::string path;
};

struct Modal {
    enum class Kind { Quit, WifiName, WifiPassword, Notice, UploadLog };
    Kind kind;
    Input input;
    std::string ssid;
    std::string text;
};

struct Options {
    bool demo = false;
    bool demo_fail = false;
    std::string flake;
    std::string zoneinfo;
    /// Where a failed installation's log is uploaded, when the user asks.
    std::string paste_url;
};

class App {
public:
    using Clock = std::chrono::steady_clock;

    App(Options options, std::shared_ptr<Queue> queue);
    ~App();
    App(const App&) = delete;
    App& operator=(const App&) = delete;

    Options options;
    Screen screen = Screen::Welcome;
    std::optional<Modal> modal;
    std::optional<Exit> exit;

    OnlineState online = OnlineState::Checking;
    bool wireless = false;
    std::vector<system_probe::WifiNetwork> networks;
    ListState network_list;
    bool scanning = false;
    std::optional<std::string> connecting;

    std::vector<system_probe::Disk> disks;
    ListState disk_list;
    ListState bootloader_list;
    ListState partitioning_list;
    std::vector<system_probe::Partition> partitions;
    ListState partition_list;
    std::optional<std::string> boot_partition;
    std::optional<std::string> root_partition;
    bool format_boot = true;
    std::optional<std::string> partition_error;
    std::optional<External> external;
    ListState filesystem_list;

    Input host{"runix", false};
    Input user;
    Input password{"", true};
    Input confirm{"", true};
    std::size_t focus = 0;
    std::optional<std::string> form_error;

    std::vector<std::string> zones;
    Input zone_filter;
    ListState zone_list;

    ListState desktop_list;
    ListState connection_list;
    Input confirmation;
    config::BootMode boot_mode = config::BootMode::Efi;

    std::size_t phase = 0;
    bool phase_done = false;
    std::deque<std::string> log;
    std::size_t scroll = 0;
    std::optional<std::string> error;
    std::optional<Clock::time_point> started;
    std::optional<Clock::duration> finished;
    install::NixStatus nix;
    bool uploading = false;
    std::optional<std::string> upload_url;
    std::optional<std::string> upload_error;
    ListState done_list;
    std::size_t frame = 0;

    std::vector<std::string> visible_zones() const;
    std::string timezone() const;
    const system_probe::Disk* disk() const;
    config::Filesystem filesystem() const;
    config::Desktop desktop() const;
    config::BootLoader loader() const;
    config::Network connection() const;
    std::vector<std::pair<std::string, std::string>> summary() const;
    std::vector<std::pair<std::string, std::string>> hints() const;

    bool applicable(Screen screen) const;
    bool manual() const;
    const system_probe::Partition* partition(const std::optional<std::string>& path) const;
    install::DiskLayout layout() const;
    std::string layout_summary() const;
    void refresh_partitions();
    /// Empty when the manual choices can be installed to.
    std::string check_manual() const;
    /// Called after cfdisk or the chroot returns; the partitions may have changed.
    void after_external(const std::string& error);
    /// 0..1 across the whole installation, from the phases and Nix's progress.
    double overall_progress() const;

    void enter(Screen screen);
    void on_key(const Key& key);
    void on_message(Message message);
    void tick();

private:
    std::shared_ptr<Queue> queue_;
    std::string partitions_disk_;
    bool checking_ = false;
    std::optional<Clock::time_point> last_check_;
    int lock_fd_ = -1;

    std::optional<std::string> selected_zone() const;
    const system_probe::Partition* selected_partition() const;
    void check_online();
    void scan();
    void connect(std::string ssid, std::optional<std::string> password);
    void advance();
    void back();
    void submit_account();
    bool take_lock();
    void release_lock();
    void start_install();
    void on_install(const install::Update& update);
    void notice(std::string text);
    void upload_log();

    void assign_boot();
    void assign_root();
    void toggle_format_boot();
    void join_selected();

    void on_modal_key(Modal modal, const Key& key);
    void on_wizard_list_key(const Key& key, ListState& list, std::size_t length);
    void on_list_key(const Key& key, ListState& list, std::size_t length);
    void on_log_key(const Key& key);
    void on_network_key(const Key& key);
    void on_partitions_key(const Key& key);
    void on_account_key(const Key& key);
    void on_timezone_key(const Key& key);
};
