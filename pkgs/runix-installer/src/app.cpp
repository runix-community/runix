#include "app.hpp"
#include "i18n.hpp"
#include "json.hpp"

#include <algorithm>
#include <cstdio>
#include <fcntl.h>
#include <random>
#include <sys/file.h>
#include <thread>
#include <unistd.h>

#include "report.hpp"
#include "util.hpp"

namespace {

constexpr const char* lock_path = "/run/runix-installer.lock";
constexpr auto recheck_interval = std::chrono::seconds(5);
constexpr std::size_t max_log_lines = 5000;
constexpr std::size_t max_input = 128;

std::optional<std::size_t> first_if(bool any) {
    return any ? std::optional<std::size_t>(0) : std::nullopt;
}

}  // namespace

namespace {

/// A random ZFS host ID: eight hex digits, never zero, which ZFS treats as unset.
std::string new_host_id() {
    std::random_device random;
    std::uint32_t value = 0;
    while (value == 0) value = random();
    char text[9];
    std::snprintf(text, sizeof text, "%08x", value);
    return text;
}

}  // namespace

const char* title(Screen screen) {
    switch (screen) {
        case Screen::Welcome: return N_("Welcome");
        case Screen::Network: return N_("Network");
        case Screen::Disk: return N_("Disk");
        case Screen::Bootloader: return N_("Boot loader");
        case Screen::Kernel: return N_("Kernel");
        case Screen::Partitioning: return N_("Partitioning");
        case Screen::Partitions: return N_("Partitions");
        case Screen::Filesystem: return N_("Filesystem");
        case Screen::Account: return N_("Account");
        case Screen::Timezone: return N_("Time zone");
        case Screen::Desktop: return N_("Desktop");
        case Screen::Server: return N_("Server");
        case Screen::Connection: return N_("Connection");
        case Screen::Review: return N_("Review");
        case Screen::Installing: return N_("Install");
        case Screen::Failed: return N_("Install failed");
        case Screen::Done: return N_("Done");
    }
    return "";
}

std::string Input::display() const {
    return masked ? std::string(util::width(value), '*') : value;
}

bool Input::handle(const Key& key) {
    if (key.code == Key::Code::Backspace) {
        if (value.empty()) return false;
        // Remove one whole UTF-8 character.
        std::size_t end = value.size() - 1;
        while (end > 0 && (static_cast<unsigned char>(value[end]) & 0xC0) == 0x80) --end;
        value.erase(end);
        return true;
    }
    if (key.code == Key::Code::Char && !key.text.empty() && value.size() + key.text.size() <= max_input) {
        value += key.text;
        return true;
    }
    return false;
}

void ListState::move(std::size_t length, bool forward) {
    if (length == 0) {
        selected.reset();
        return;
    }
    std::size_t current = std::min(selected.value_or(0), length - 1);
    selected = forward ? std::min(current + 1, length - 1) : (current == 0 ? 0 : current - 1);
}

App::App(Options options_, std::shared_ptr<Queue> queue)
    : options(std::move(options_)), queue_(std::move(queue)) {
    zones = system_probe::timezones(options.zoneinfo);
    wireless = system_probe::wireless_available(options.demo);
    boot_mode = options.demo ? config::BootMode::Efi : system_probe::boot_mode();
    gpus = system_probe::gpus(options.demo);
    devices = system_probe::devices(options.demo);
    nvidia_device = gpus.nvidia;
    apply_defaults();
}

namespace {

template <typename T, std::size_t N>
void preselect(ListState& list, const std::array<T, N>& choices, const std::string& wanted) {
    if (wanted.empty()) return;
    for (std::size_t index = 0; index < N; ++index)
        if (wanted == config::id(choices[index])) list.select(index);
}

}  // namespace

std::string read_defaults(const std::string& text, Options::Defaults& defaults) {
    auto root = json::parse(text);
    if (!root || !root->is_object()) return "not a JSON object";
    auto take = [&](const char* key, std::string& into) {
        if (auto value = (*root)[key].string()) into = *value;
    };
    take("language", defaults.language);
    take("host", defaults.host);
    take("user", defaults.user);
    take("timezone", defaults.timezone);
    take("bootloader", defaults.bootloader);
    take("kernel", defaults.kernel);
    take("filesystem", defaults.filesystem);
    take("desktop", defaults.desktop);
    take("connection", defaults.connection);
    take("extraConfiguration", defaults.extra_configuration);
    return "";
}

void App::apply_defaults() {
    const auto& wanted = options.defaults;
    if (!wanted.language.empty()) i18n::use(wanted.language);
    if (!wanted.host.empty() && config::valid_host(wanted.host)) host.value = wanted.host;
    if (!wanted.user.empty() && config::valid_user(wanted.user)) user.value = wanted.user;
    if (!wanted.timezone.empty()) {
        auto found = std::find(zones.begin(), zones.end(), wanted.timezone);
        if (found != zones.end()) zone_list.select(static_cast<std::size_t>(found - zones.begin()));
    }
    preselect(bootloader_list, config::loaders, wanted.bootloader);
    preselect(kernel_list, config::kernels, wanted.kernel);
    preselect(filesystem_list, config::filesystems, wanted.filesystem);
    preselect(desktop_list, config::desktops, wanted.desktop);
    preselect(connection_list, config::networks, wanted.connection);
}

void App::cycle_language() {
    const auto& all = i18n::languages();
    if (all.size() < 2) return;
    std::size_t index = 0;
    while (index < all.size() && all[index].code != i18n::current()) ++index;
    i18n::use(all[(index + 1) % all.size()].code);
}

App::~App() {
    release_lock();
}

std::vector<std::string> App::visible_zones() const {
    std::string filter = util::lower(zone_filter.value);
    std::vector<std::string> visible;
    for (const auto& zone : zones) {
        if (util::contains(util::lower(zone), filter)) visible.push_back(zone);
    }
    return visible;
}

std::optional<std::string> App::selected_zone() const {
    auto visible = visible_zones();
    if (!zone_list.selected || *zone_list.selected >= visible.size()) return std::nullopt;
    return visible[*zone_list.selected];
}

std::string App::timezone() const {
    return selected_zone().value_or("UTC");
}

const system_probe::Disk* App::disk() const {
    if (!disk_list.selected || *disk_list.selected >= disks.size()) return nullptr;
    return &disks[*disk_list.selected];
}

config::Filesystem App::filesystem() const {
    return config::filesystems[std::min(filesystem_list.selected.value_or(0), config::filesystems.size() - 1)];
}

config::Desktop App::desktop() const {
    return config::desktops[std::min(desktop_list.selected.value_or(0), config::desktops.size() - 1)];
}

config::BootLoader App::loader() const {
    return config::loaders[std::min(bootloader_list.selected.value_or(0), config::loaders.size() - 1)];
}

config::Kernel App::kernel() const {
    return config::kernels[std::min(kernel_list.selected.value_or(0), config::kernels.size() - 1)];
}

config::Network App::connection() const {
    if (!wireless) return config::Network::Dhcpcd;
    return config::networks[std::min(connection_list.selected.value_or(0), config::networks.size() - 1)];
}

std::string App::graphics_summary() const {
    std::vector<std::string> parts;
    if (nvidia_device) parts.push_back(i18n::format("NVIDIA (proprietary, {})", {config::nvidia_driver(*nvidia_device).branch}));
    if (gpus.amd) parts.push_back("AMD");
    if (gpus.intel) parts.push_back("Intel");
    if (parts.empty()) return tr("no GPU found, generic drivers");
    std::string text;
    for (const auto& part : parts) text += (text.empty() ? "" : " + ") + part;
    return text;
}

std::vector<std::pair<std::string, std::string>> App::summary() const {
    std::string disk_text = tr("none");
    if (const auto* chosen = disk()) {
        disk_text = chosen->path + "  " + util::format_size(chosen->size) + "  " + chosen->model;
    }
    std::vector<std::pair<std::string, std::string>> rows{
        {N_("Disk"), disk_text},
        {N_("Layout"), layout_summary()},
        {N_("Boot loader"), tr(config::name(loader()))},
        {N_("Kernel"), tr(config::name(kernel()))},
        {N_("Filesystem"), tr(config::name(filesystem()))},
        {N_("Boot mode"), config::name(boot_mode)},
        {N_("Graphics"), graphics_summary()},
        {N_("Hardware"), tr(devices.battery ? N_("laptop (battery)") : N_("desktop")) +
                         (devices.bluetooth ? ", Bluetooth" : "")},
        {N_("Host name"), host.value},
        {N_("User"), user.value},
        {N_("Time zone"), timezone()},
        {N_("Desktop"), tr(config::name(desktop()))},
    };
    if (desktop() == config::Desktop::Server) {
        auto or_none = [](const std::string& value, const char* none) { return value.empty() ? tr(none) : value; };
        rows.push_back({N_("Domain"), or_none(domain.value, N_("none, local network only"))});
        rows.push_back({N_("Tunnel"), or_none(tunnel_id.value, N_("none, set up later"))});
        rows.push_back({N_("SSH"), ssh_key.value.empty() ? tr("password logins")
                                                         : tr("key only: ") + ssh_key.value.substr(0, ssh_key.value.find(' '))});
    }
    rows.push_back({N_("Connection"), tr(config::name(connection()))});
    return rows;
}

void App::check_online() {
    if (checking_) return;
    checking_ = true;
    last_check_ = Clock::now();
    std::thread([queue = queue_, demo = options.demo]() {
        Message message{Message::Kind::Online};
        message.online = system_probe::online(demo);
        queue->push(std::move(message));
    }).detach();
}

void App::scan() {
    if (scanning || !wireless) return;
    scanning = true;
    std::thread([queue = queue_, demo = options.demo]() {
        Message message{Message::Kind::Scanned};
        message.networks = system_probe::scan(demo);
        queue->push(std::move(message));
    }).detach();
}

void App::connect(std::string ssid, std::optional<std::string> password) {
    connecting = ssid;
    std::thread([queue = queue_, demo = options.demo, ssid = std::move(ssid), password = std::move(password)]() {
        Message message{Message::Kind::Connected};
        message.error = system_probe::connect(demo, ssid, password);
        queue->push(std::move(message));
    }).detach();
}

void App::enter(Screen next) {
    screen = next;
    switch (next) {
        case Screen::Network:
            check_online();
            scan();
            break;
        case Screen::Disk:
            disks = system_probe::disks(options.demo);
            disk_list.select(first_if(!disks.empty()));
            break;
        case Screen::Partitioning:
        case Screen::Partitions:
            refresh_partitions();
            break;
        case Screen::Review:
            confirmation.value.clear();
            break;
        default:
            break;
    }
}

bool App::applicable(Screen candidate) const {
    if (candidate == Screen::Connection) return wireless;
    if (candidate == Screen::Server) return desktop() == config::Desktop::Server;
    if (candidate == Screen::Partitions) return manual();
    return true;
}

bool App::manual() const {
    return partitioning_list.selected == 1u;
}

const system_probe::Partition* App::partition(const std::optional<std::string>& path) const {
    if (!path) return nullptr;
    for (const auto& candidate : partitions) {
        if (candidate.path == *path) return &candidate;
    }
    return nullptr;
}

install::DiskLayout App::layout() const {
    if (manual() && boot_partition && root_partition) {
        return install::DiskLayout::manual(*boot_partition, *root_partition, format_boot);
    }
    return install::DiskLayout::automatic();
}

std::string App::layout_summary() const {
    auto chosen = layout();
    if (chosen.kind == install::DiskLayout::Kind::Automatic) {
        return tr("Automatic: erase the disk, 1 GiB boot, root on the rest");
    }
    return i18n::format(chosen.format_boot ? N_("Manual: boot {} (format), root {} (format)")
                                            : N_("Manual: boot {} (keep), root {} (format)"),
                        {chosen.boot, chosen.root});
}

void App::refresh_partitions() {
    const auto* chosen = disk();
    if (!chosen) {
        partitions.clear();
        return;
    }
    std::string path = chosen->path;
    partitions = system_probe::partitions(options.demo, path);
    if (partitions_disk_ != path) {
        partitions_disk_ = path;
        boot_partition.reset();
        root_partition.reset();
    }
    if (!partition(boot_partition)) boot_partition.reset();
    if (!partition(root_partition)) root_partition.reset();
    // An existing ESP is the usual dual-boot choice, and keeping it is safe.
    if (!boot_partition) {
        if (const auto* esp = system_probe::existing_esp(partitions)) {
            boot_partition = esp->path;
            format_boot = false;
        }
    }
    if (partitions.empty()) {
        partition_list.select(std::nullopt);
    } else {
        partition_list.select(std::min(partition_list.selected.value_or(0), partitions.size() - 1));
    }
    partition_error.reset();
}

const system_probe::Partition* App::selected_partition() const {
    if (!partition_list.selected || *partition_list.selected >= partitions.size()) return nullptr;
    return &partitions[*partition_list.selected];
}

void App::assign_boot() {
    const auto* chosen = selected_partition();
    if (!chosen) return;
    if (root_partition == chosen->path) root_partition.reset();
    // Only an existing FAT filesystem can be kept as it is.
    format_boot = !chosen->is_vfat();
    boot_partition = chosen->path;
    partition_error.reset();
}

void App::assign_root() {
    const auto* chosen = selected_partition();
    if (!chosen) return;
    if (boot_partition == chosen->path) boot_partition.reset();
    root_partition = chosen->path;
    partition_error.reset();
}

void App::toggle_format_boot() {
    const auto* boot = partition(boot_partition);
    if (boot && boot->is_vfat()) format_boot = !format_boot;
}

std::string App::check_manual() const {
    const auto* boot = partition(boot_partition);
    if (!boot) return tr("Choose a boot partition with b.");
    const auto* root = partition(root_partition);
    if (!root) return tr("Choose a root partition with r.");
    if (boot->mounted || root->mounted) return tr("Unmount the chosen partitions first.");
    if (boot->size < minimum_boot_bytes) {
        return i18n::format("The boot partition needs at least {}.", {util::format_size(minimum_boot_bytes)});
    }
    if (!format_boot && !boot->is_vfat()) return tr("Only a FAT boot partition can be kept; press f to format it.");
    bool needs_bios_boot = loader() == config::BootLoader::Grub && boot_mode == config::BootMode::Bios;
    bool has_bios_boot = std::any_of(partitions.begin(), partitions.end(),
                                     [](const auto& candidate) { return candidate.is_bios_boot(); });
    if (needs_bios_boot && !has_bios_boot) {
        return tr("GRUB on a BIOS machine needs a 1 MiB \"BIOS boot\" partition. Press e to create one.");
    }
    if (root->size < minimum_root_bytes) {
        return i18n::format("The root partition needs at least {}.", {util::format_size(minimum_root_bytes)});
    }
    return "";
}

void App::after_external(const std::string& failure) {
    refresh_partitions();
    if (!failure.empty()) notice(failure);
}

double App::overall_progress() const {
    if (phase_done) return 1.0;
    int total = 0;
    for (int weight : install::phase_weights) total += weight;
    double done = 0;
    for (std::size_t index = 0; index < phase && index < install::phase_weights.size(); ++index) {
        done += install::phase_weights[index];
    }
    if (phase == 4 && nix.fraction) done += install::phase_weights[4] * *nix.fraction;
    return std::clamp(done / total, 0.0, 1.0);
}

void App::notice(std::string text) {
    Modal next{Modal::Kind::Notice};
    next.text = std::move(text);
    modal = std::move(next);
}

void App::advance() {
    auto position = std::find(wizard.begin(), wizard.end(), screen);
    if (position == wizard.end()) return;
    for (auto next = position + 1; next != wizard.end(); ++next) {
        if (applicable(*next)) {
            enter(*next);
            return;
        }
    }
}

void App::back() {
    auto position = std::find(wizard.begin(), wizard.end(), screen);
    if (position == wizard.end()) return;
    while (position != wizard.begin()) {
        --position;
        if (applicable(*position)) {
            enter(*position);
            return;
        }
    }
}

void App::submit_account() {
    form_error.reset();
    if (!config::valid_host(host.value)) {
        form_error = tr("Host names use letters, digits, and hyphens, and cannot start with a hyphen.");
    } else if (!config::valid_user(user.value)) {
        form_error = tr("User names use lowercase letters, digits, hyphens, and underscores, and cannot be root.");
    } else if (password.value.empty()) {
        form_error = tr("The password cannot be empty.");
    } else if (password.value != confirm.value) {
        form_error = tr("The passwords do not match.");
    }
    if (!form_error) advance();
}

bool App::take_lock() {
    if (options.demo || lock_fd_ >= 0) return true;
    int fd = open(lock_path, O_WRONLY | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) return false;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd);
        return false;
    }
    lock_fd_ = fd;
    return true;
}

void App::release_lock() {
    if (lock_fd_ >= 0) {
        close(lock_fd_);
        lock_fd_ = -1;
    }
}

void App::start_install() {
    const auto* chosen = disk();
    if (!chosen) return;
    if (!take_lock()) {
        notice(tr("Another session is already installing."));
        return;
    }
    install::Plan plan;
    plan.layout = layout();
    plan.flake = options.flake;
    plan.host = host.value;
    plan.user = user.value;
    plan.password = password.value;
    plan.timezone = timezone();
    plan.desktop = desktop();
    plan.network = connection();
    plan.root_fs = filesystem();
    plan.boot_mode = boot_mode;
    plan.loader = loader();
    plan.kernel = kernel();
    plan.disk = chosen->path;
    if (zfs_host_id.empty()) zfs_host_id = new_host_id();
    plan.zfs_host_id = zfs_host_id;
    plan.nvidia_device = nvidia_device;
    plan.amd_gpu = gpus.amd;
    plan.intel_gpu = gpus.intel;
    plan.bluetooth = devices.bluetooth;
    plan.battery = devices.battery;
    if (!options.demo) plan.disk_modules = system_probe::disk_modules("/sys", plan.disk);
    plan.extra_configuration = options.defaults.extra_configuration;
    if (plan.desktop == config::Desktop::Server) {
        plan.domain = domain.value;
        plan.tunnel_id = tunnel_id.value;
        plan.ssh_key = ssh_key.value;
    }
    log.clear();
    scroll = 0;
    phase = 0;
    phase_done = false;
    error.reset();
    nix = {};
    upload_url.reset();
    upload_error.reset();
    started = Clock::now();
    finished.reset();
    screen = Screen::Installing;
    install::spawn(std::move(plan), options.demo, options.demo_fail, [queue = queue_](install::Update update) {
        Message message{Message::Kind::Install};
        message.update = std::move(update);
        queue->push(std::move(message));
    });
}

void App::on_message(Message message) {
    switch (message.kind) {
        case Message::Kind::Online:
            checking_ = false;
            online = message.online ? OnlineState::Online : OnlineState::Offline;
            break;
        case Message::Kind::Scanned:
            scanning = false;
            networks = std::move(message.networks);
            network_list.select(first_if(!networks.empty()));
            break;
        case Message::Kind::Connected:
            connecting.reset();
            if (!message.error.empty()) {
                notice(i18n::format("Could not connect: {}", {message.error}));
            } else if (options.demo) {
                online = OnlineState::Online;
            } else {
                check_online();
            }
            break;
        case Message::Kind::Install:
            on_install(message.update);
            break;
        case Message::Kind::Uploaded:
            uploading = false;
            if (message.error.empty()) {
                upload_url = message.url;
                upload_error.reset();
            } else {
                upload_error = message.error;
            }
            break;
    }
}

void App::on_install(const install::Update& update) {
    switch (update.kind) {
        case install::Update::Kind::Phase:
            phase = update.phase;
            break;
        case install::Update::Kind::Line:
            log.push_back(update.text);
            if (log.size() > max_log_lines) log.pop_front();
            break;
        case install::Update::Kind::Nix:
            // Each package Nix finishes reaches the game: a pellet, a falling package.
            if (game && update.nix.completed > nix.completed) game->package(games::package_name(update.nix.current));
            nix = update.nix;
            break;
        case install::Update::Kind::Finished:
            if (started) finished = Clock::now() - *started;
            if (update.error.empty()) {
                phase_done = true;
                password.value.clear();
                confirm.value.clear();
                // Never jump away mid-game; the board shows the news instead.
                if (in_games()) {
                    done_while_playing = true;
                } else {
                    screen = Screen::Done;
                }
            } else {
                // A failure always takes over the screen.
                leave_games();
                error = update.error;
                screen = Screen::Failed;
            }
            break;
    }
}

void App::tick() {
    // Time-based, so the spinner keeps its pace when the loop polls faster.
    frame = static_cast<std::size_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - created_).count() / 100);
    auto now = Clock::now();
    double seconds = std::chrono::duration<double>(now - last_update_).count();
    last_update_ = now;
    if (playing()) game->update(seconds);
    bool due = !last_check_ || Clock::now() - *last_check_ >= recheck_interval;
    if (screen == Screen::Network && online != OnlineState::Online && due) check_online();
}

std::vector<std::pair<std::string, std::string>> App::hints() const {
    if (modal) return {{"enter", N_("confirm")}, {"esc", N_("cancel")}};
    switch (screen) {
        case Screen::Welcome:
            if (i18n::languages().size() > 1)
                return {{"enter", N_("begin")}, {"l", N_("language")}, {"ctrl+c", N_("shell")}};
            return {{"enter", N_("begin")}, {"ctrl+c", N_("shell")}};
        case Screen::Network:
            if (wireless) {
                return {{"enter", N_("continue / join")}, {"o", N_("other")}, {"r", N_("rescan")}, {"s", N_("skip")}, {"esc", N_("back")}};
            }
            return {{"enter", N_("continue")}, {"s", N_("skip")}, {"esc", N_("back")}};
        case Screen::Account: return {{"tab", N_("next")}, {"enter", N_("continue")}, {"esc", N_("back")}};
        case Screen::Server: return {{"tab", N_("next")}, {"enter", N_("continue")}, {"esc", N_("back")}};
        case Screen::Timezone: return {{"type", N_("search")}, {"enter", N_("continue")}, {"esc", N_("back")}};
        case Screen::Partitions:
            return {{"b", N_("boot")}, {"r", N_("root")}, {"f", N_("format boot")}, {"e", N_("cfdisk")}, {"enter", N_("continue")}, {"esc", N_("back")}};
        case Screen::Review: return {{"enter", N_("install")}, {"esc", N_("back")}};
        case Screen::Installing:
            if (done_while_playing) return {{"enter", N_("continue")}};
            if (game) return game->hints();
            if (hub_open) return {{"up/down", N_("choose")}, {"enter", N_("play")}, {"esc", N_("back to the log")}};
            return {{"g", N_("games")}, {"pgup/pgdn", N_("scroll log")}};
        case Screen::Failed:
            return {{"r", N_("retry")}, {"u", N_("upload log")}, {"b", N_("change settings")}, {"s", N_("shell")}, {"pgup/pgdn", N_("log")}};
        case Screen::Done: return {{"enter", N_("select")}};
        default: return {{"up/down", N_("select")}, {"enter", N_("continue")}, {"esc", N_("back")}};
    }
}

void App::on_key(const Key& key) {
    if (modal) {
        Modal current = std::move(*modal);
        modal.reset();
        on_modal_key(std::move(current), key);
        return;
    }
    if (key.code == Key::Code::CtrlC) {
        // The install thread is in the middle of writing to the disk.
        if (screen != Screen::Installing) modal = Modal{Modal::Kind::Quit};
        return;
    }
    switch (screen) {
        case Screen::Welcome:
            if (key.code == Key::Code::Enter) advance();
            if (key.is('l')) cycle_language();
            break;
        case Screen::Network:
            on_network_key(key);
            break;
        case Screen::Disk:
            if (key.code == Key::Code::Enter && disk()) {
                advance();
            } else if (key.is('r')) {
                enter(Screen::Disk);
            } else if (key.code == Key::Code::Esc) {
                back();
            } else {
                on_list_key(key, disk_list, disks.size());
            }
            break;
        case Screen::Partitioning:
            if (key.code == Key::Code::Up || key.code == Key::Code::Down || key.is('j') || key.is('k')) {
                on_list_key(key, partitioning_list, 2);
                refresh_partitions();
            } else {
                on_wizard_list_key(key, partitioning_list, 2);
            }
            break;
        case Screen::Partitions:
            on_partitions_key(key);
            break;
        case Screen::Bootloader:
            on_wizard_list_key(key, bootloader_list, config::loaders.size());
            break;
        case Screen::Kernel:
            on_wizard_list_key(key, kernel_list, config::kernels.size());
            break;
        case Screen::Filesystem:
            if (key.code == Key::Code::Enter) {
                std::string problem = config::check_kernel(kernel(), filesystem());
                if (!problem.empty()) {
                    filesystem_error = tr(problem);
                    break;
                }
            }
            filesystem_error.reset();
            on_wizard_list_key(key, filesystem_list, config::filesystems.size());
            break;
        case Screen::Desktop:
            on_wizard_list_key(key, desktop_list, config::desktops.size());
            break;
        case Screen::Server:
            on_server_key(key);
            break;
        case Screen::Connection:
            on_wizard_list_key(key, connection_list, config::networks.size());
            break;
        case Screen::Account:
            on_account_key(key);
            break;
        case Screen::Timezone:
            on_timezone_key(key);
            break;
        case Screen::Review:
            if (key.code == Key::Code::Esc) {
                back();
            } else if (key.code == Key::Code::Enter && confirmation.value == confirmation_word) {
                start_install();
            } else {
                confirmation.handle(key);
            }
            break;
        case Screen::Installing:
            if (in_games()) {
                on_games_key(key);
            } else if (key.is('g')) {
                hub_open = true;
            } else {
                on_log_key(key);
            }
            break;
        case Screen::Failed:
            if (key.is('r')) {
                start_install();
            } else if (key.is('b')) {
                install::unmount(options.demo);
                release_lock();
                enter(Screen::Disk);
            } else if (key.is('s')) {
                install::unmount(options.demo);
                exit = Exit::Shell;
            } else if (key.is('u') && !uploading && !upload_url) {
                modal = Modal{Modal::Kind::UploadLog};
            } else {
                on_log_key(key);
            }
            break;
        case Screen::Done:
            if (key.code == Key::Code::Enter && done_list.selected == 2u) {
                if (options.demo) {
                    notice(tr("Demo mode does not open a chroot."));
                } else {
                    external = External{External::Kind::Chroot, install::target};
                }
            } else if (key.code == Key::Code::Enter) {
                install::unmount(options.demo);
                exit = done_list.selected == 0u   ? Exit::Reboot
                       : done_list.selected == 1u ? Exit::Poweroff
                                                  : Exit::Shell;
            } else {
                on_list_key(key, done_list, done_actions.size());
            }
            break;
    }
}

void App::start_game(std::size_t index) {
    const auto& entries = games::catalog();
    if (index >= entries.size()) return;
    game_index = index;
    // Sized by the UI to fit under the progress bar.
    game = entries[index].make(game_columns, game_rows,
                               static_cast<std::uint32_t>(Clock::now().time_since_epoch().count()));
    last_update_ = Clock::now();
}

void App::close_game() {
    if (!game) return;
    if (best_.size() < games::catalog().size()) best_.resize(games::catalog().size(), 0);
    best_[game_index] = std::max(best_[game_index], game->score());
    game.reset();
}

void App::leave_games() {
    close_game();
    hub_open = false;
}

int App::best_score(std::size_t index) const {
    int best = index < best_.size() ? best_[index] : 0;
    if (game && index == game_index) best = std::max(best, game->score());
    return best;
}

void App::on_games_key(const Key& key) {
    if (done_while_playing) {
        if (key.code == Key::Code::Enter) {
            leave_games();
            done_while_playing = false;
            screen = Screen::Done;
        }
        return;
    }
    if (!game) {
        // The menu.
        if (key.code == Key::Code::Esc) {
            hub_open = false;
        } else if (key.code == Key::Code::Enter) {
            start_game(hub_list.selected.value_or(0));
        } else {
            on_list_key(key, hub_list, games::catalog().size());
        }
        return;
    }
    if (key.code == Key::Code::Esc) {
        close_game();
        return;
    }
    if (game->over() && key.is('r')) {
        // Keep this round's score before the next one starts.
        if (best_.size() < games::catalog().size()) best_.resize(games::catalog().size(), 0);
        best_[game_index] = std::max(best_[game_index], game->score());
        game->input(games::Input::Restart);
        return;
    }
    if (key.code == Key::Code::Up || key.is('w') || key.is('k')) game->input(games::Input::Up);
    if (key.code == Key::Code::Down || key.is('s') || key.is('j')) game->input(games::Input::Down);
    if (key.code == Key::Code::Left || key.is('a') || key.is('h')) game->input(games::Input::Left);
    if (key.code == Key::Code::Right || key.is('d') || key.is('l')) game->input(games::Input::Right);
    if (key.is(' ')) game->input(games::Input::Action);
}

void App::on_log_key(const Key& key) {
    if (key.code == Key::Code::PageUp) scroll = std::min(scroll + 10, log.size());
    if (key.code == Key::Code::PageDown) scroll = scroll > 10 ? scroll - 10 : 0;
}

void App::on_network_key(const Key& key) {
    if (connecting) return;
    if (key.code == Key::Code::Esc) {
        back();
    } else if (key.code == Key::Code::Enter && online == OnlineState::Online) {
        advance();
    } else if (key.code == Key::Code::Enter || key.is('c')) {
        join_selected();
    } else if (key.is('s')) {
        advance();
    } else if (key.is('r')) {
        scan();
    } else if (key.is('o') && wireless) {
        modal = Modal{Modal::Kind::WifiName};
    } else {
        on_list_key(key, network_list, networks.size());
    }
}

void App::join_selected() {
    if (!network_list.selected || *network_list.selected >= networks.size()) return;
    auto network = networks[*network_list.selected];
    if (network.secured) {
        Modal next{Modal::Kind::WifiPassword};
        next.ssid = network.ssid;
        next.input.masked = true;
        modal = std::move(next);
    } else {
        connect(network.ssid, std::nullopt);
    }
}

void App::on_modal_key(Modal current, const Key& key) {
    switch (current.kind) {
        case Modal::Kind::Quit:
            if (key.code == Key::Code::Enter) {
                exit = Exit::Shell;
            } else if (key.code != Key::Code::Esc) {
                modal = std::move(current);
            }
            break;
        case Modal::Kind::Notice:
            break;
        case Modal::Kind::UploadLog:
            if (key.code == Key::Code::Enter) {
                upload_log();
            } else if (key.code != Key::Code::Esc) {
                modal = std::move(current);
            }
            break;
        case Modal::Kind::WifiName:
            if (key.code == Key::Code::Esc) break;
            if (key.code == Key::Code::Enter && !current.input.value.empty()) {
                Modal next{Modal::Kind::WifiPassword};
                next.ssid = current.input.value;
                next.input.masked = true;
                modal = std::move(next);
                break;
            }
            current.input.handle(key);
            modal = std::move(current);
            break;
        case Modal::Kind::WifiPassword:
            if (key.code == Key::Code::Esc) break;
            if (key.code == Key::Code::Enter) {
                std::optional<std::string> secret;
                if (!current.input.value.empty()) secret = current.input.value;
                connect(current.ssid, secret);
                break;
            }
            current.input.handle(key);
            modal = std::move(current);
            break;
    }
}

void App::on_wizard_list_key(const Key& key, ListState& list, std::size_t length) {
    if (key.code == Key::Code::Enter) {
        advance();
    } else if (key.code == Key::Code::Esc) {
        back();
    } else {
        on_list_key(key, list, length);
    }
}

void App::on_list_key(const Key& key, ListState& list, std::size_t length) {
    if (key.code == Key::Code::Up || key.is('k')) {
        list.move(length, false);
    } else if (key.code == Key::Code::Down || key.is('j')) {
        list.move(length, true);
    }
}

void App::on_partitions_key(const Key& key) {
    if (key.code == Key::Code::Esc) {
        back();
    } else if (key.code == Key::Code::Enter) {
        std::string problem = check_manual();
        if (problem.empty()) {
            advance();
        } else {
            partition_error = problem;
        }
    } else if (key.is('b')) {
        assign_boot();
    } else if (key.is('r')) {
        assign_root();
    } else if (key.is('f')) {
        toggle_format_boot();
    } else if (key.is('e')) {
        if (options.demo) {
            notice(tr("Demo mode does not open cfdisk."));
        } else if (const auto* chosen = disk()) {
            external = External{External::Kind::EditPartitions, chosen->path};
        }
    } else {
        on_list_key(key, partition_list, partitions.size());
    }
}

void App::on_account_key(const Key& key) {
    constexpr std::size_t last_field = 3;
    switch (key.code) {
        case Key::Code::Esc: back(); return;
        case Key::Code::Tab:
        case Key::Code::Down: focus = std::min(focus + 1, last_field); return;
        case Key::Code::BackTab:
        case Key::Code::Up: focus = focus == 0 ? 0 : focus - 1; return;
        case Key::Code::Enter:
            if (focus < last_field) {
                ++focus;
            } else {
                submit_account();
            }
            return;
        default: break;
    }
    Input* field = focus == 0 ? &host : focus == 1 ? &user : focus == 2 ? &password : &confirm;
    if (field->handle(key)) form_error.reset();
}

void App::on_server_key(const Key& key) {
    constexpr std::size_t last_field = 2;
    switch (key.code) {
        case Key::Code::Esc: back(); return;
        case Key::Code::Tab:
        case Key::Code::Down: server_focus = std::min(server_focus + 1, last_field); return;
        case Key::Code::BackTab:
        case Key::Code::Up: server_focus = server_focus == 0 ? 0 : server_focus - 1; return;
        case Key::Code::Enter:
            if (server_focus < last_field) {
                ++server_focus;
            } else {
                submit_server();
            }
            return;
        default: break;
    }
    Input* field = server_focus == 0 ? &domain : server_focus == 1 ? &tunnel_id : &ssh_key;
    if (field->handle(key)) server_error.reset();
}

void App::submit_server() {
    server_error.reset();
    if (!domain.value.empty() && !config::valid_domain(domain.value)) {
        server_error = tr("The domain is a name like example.org: letters, digits, hyphens and dots.");
        server_focus = 0;
    } else if (!tunnel_id.value.empty() && !config::valid_tunnel_id(tunnel_id.value)) {
        server_error = tr("The tunnel ID looks like 6ff42ae2-765d-4adf-8112-31c55c1551ef.");
        server_focus = 1;
    } else if (!ssh_key.value.empty() && !config::valid_ssh_key(ssh_key.value)) {
        server_error = tr("Paste one public key line, like ssh-ed25519 AAAA... you@host.");
        server_focus = 2;
    }
    if (!server_error) advance();
}

void App::on_timezone_key(const Key& key) {
    if (key.code == Key::Code::Esc) {
        back();
    } else if (key.code == Key::Code::Enter) {
        if (selected_zone()) advance();
    } else if (key.code == Key::Code::Up || key.code == Key::Code::Down) {
        zone_list.move(visible_zones().size(), key.code == Key::Code::Down);
    } else if (zone_filter.handle(key)) {
        zone_list.select(first_if(!visible_zones().empty()));
    }
}

void App::upload_log() {
    report::Details details;
    details.error = error.value_or("");
    details.failed_step = phase < install::phases.size() ? install::phases[phase] : "";
    details.boot_mode = config::name(boot_mode);
    details.loader = config::name(loader());
    details.filesystem = config::name(filesystem());
    details.layout = layout().kind == install::DiskLayout::Kind::Automatic ? "automatic" : "manual";
    details.nix_summary = nix.summary;
    details.host = host.value;
    details.user = user.value;
    std::string content = report::build(details, report::read_log(install::log_path, log));
    uploading = true;
    upload_error.reset();
    std::thread([queue = queue_, demo = options.demo, service = options.paste_url, content = std::move(content)]() {
        Message message{Message::Kind::Uploaded};
        if (demo) {
            // Demo logs stay on this machine.
            std::this_thread::sleep_for(std::chrono::seconds(1));
            message.url = "https://paste.example/demo-log";
        } else {
            auto result = report::upload(service, content);
            message.url = result.url;
            message.error = result.error;
        }
        queue->push(std::move(message));
    }).detach();
}
