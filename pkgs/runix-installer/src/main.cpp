#include <cerrno>
#include <climits>
#include <clocale>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <langinfo.h>
#include <ncurses.h>
#include <string>
#include <optional>
#include <sys/ioctl.h>
#include <unistd.h>
#include <cwchar>
#include <fstream>
#include <sstream>

#include "app.hpp"
#include "i18n.hpp"
#include "process.hpp"
#include "report.hpp"
#include "system.hpp"
#include "ui.hpp"

namespace {

constexpr const char* usage =
    "Usage: runix-installer [OPTIONS]\n"
    "\n"
    "Options:\n"
    "  --demo       Walk through the installer without changing anything\n"
    "  --demo-fail  Like --demo, and end with a failed installation\n"
    "  --language CODE\n"
    "               Start in this language, from the translation catalogs\n"
    "  -h, --help   Show this help\n"
    "\n"
    "Environment:\n"
    "  RUNIX_INSTALLER_TRANSLATIONS  Directories of <code>.json catalogs, colon-separated\n"
    "  RUNIX_INSTALLER_SETTINGS      A JSON file of preselected choices\n"
    "  RUNIX_INSTALLER_LANGUAGE      The starting language, like --language\n";

/// Mounts the kernel filesystems in a private namespace, so they disappear
/// with the shell, and points /run/current-system at the new generation.
constexpr const char* chroot_script = R"(set -e
root=$1
for directory in dev proc sys run; do mkdir -p "$root/$directory"; done
mount --rbind /dev "$root/dev"
mount -t proc proc "$root/proc"
mount --rbind /sys "$root/sys"
mount -t tmpfs -o mode=0755 tmpfs "$root/run"
ln -s /nix/var/nix/profiles/system "$root/run/current-system"
printf '\nYou are in the installed Runix system. Type exit to return to the installer.\n\n'
exec chroot "$root" /nix/var/nix/profiles/system/sw/bin/bash --login
)";

/// The Linux console's 16 colors, redefined around the Runix green. Other
/// terminals keep their own theme, since the UI only uses named colors.
constexpr const char* console_palette[16] = {
    "0e1110", "e0574f", "00a35a", "d9a441", "4f8fd1", "b07fd1", "3fb5a5", "c8ccc6",
    "4d5450", "f0736a", "2fd07f", "f0c060", "74aef0", "cc9ef0", "66d6c6", "f1f3ef",
};

bool on_console() {
    const char* term = std::getenv("TERM");
    return term && std::strcmp(term, "linux") == 0;
}

void set_console_palette(bool enabled) {
    if (!on_console()) return;
    std::string sequence;
    if (enabled) {
        for (int index = 0; index < 16; ++index) {
            char code[16];
            std::snprintf(code, sizeof code, "\x1b]P%X%s", index, console_palette[index]);
            sequence += code;
        }
    } else {
        sequence = "\x1b]R";
    }
    std::fwrite(sequence.data(), 1, sequence.size(), stdout);
    std::fflush(stdout);
}

/// The box-drawing and block glyphs need a UTF-8 locale. The live system may
/// start the installer with no locale at all.
void use_utf8_locale() {
    std::setlocale(LC_ALL, "");
    if (std::strcmp(nl_langinfo(CODESET), "UTF-8") != 0) std::setlocale(LC_ALL, "C.UTF-8");
}

void start_screen() {
    initscr();
    raw();
    noecho();
    keypad(stdscr, TRUE);
    curs_set(0);
    timeout(100);
    ui::init_colors();
}

Key read_key() {
    wint_t character = 0;
    int kind = get_wch(&character);
    if (kind == ERR) return Key::of(Key::Code::Other);
    if (kind == KEY_CODE_YES) {
        switch (character) {
            case KEY_UP: return Key::of(Key::Code::Up);
            case KEY_DOWN: return Key::of(Key::Code::Down);
            case KEY_LEFT: return Key::of(Key::Code::Left);
            case KEY_RIGHT: return Key::of(Key::Code::Right);
            case KEY_BTAB: return Key::of(Key::Code::BackTab);
            case KEY_BACKSPACE: return Key::of(Key::Code::Backspace);
            case KEY_PPAGE: return Key::of(Key::Code::PageUp);
            case KEY_NPAGE: return Key::of(Key::Code::PageDown);
            case KEY_ENTER: return Key::of(Key::Code::Enter);
            default: return Key::of(Key::Code::Other);
        }
    }
    switch (character) {
        case '\n':
        case '\r': return Key::of(Key::Code::Enter);
        case '\t': return Key::of(Key::Code::Tab);
        case 27: return Key::of(Key::Code::Esc);
        case 3: return Key::of(Key::Code::CtrlC);
        case 8:
        case 127: return Key::of(Key::Code::Backspace);
        default: break;
    }
    if (character < 32) return Key::of(Key::Code::Other);
    char buffer[MB_LEN_MAX + 1] = {};
    std::mbstate_t state{};
    std::size_t length = std::wcrtomb(buffer, static_cast<wchar_t>(character), &state);
    if (length == static_cast<std::size_t>(-1)) return Key::of(Key::Code::Other);
    return Key::character(std::string(buffer, length));
}

/// Runs cfdisk or the chroot on the real terminal while the UI is suspended.
std::string run_external(const External& external) {
    std::string error;
    switch (external.kind) {
        case External::Kind::EditPartitions:
            if (!process::interactive({"cfdisk", external.path}, error)) return "Could not open cfdisk: " + error;
            return "";
        case External::Kind::Chroot:
            // The shell's exit status is the user's last command, so only a
            // failure to start counts as an error.
            if (!process::interactive({"unshare", "--mount", "--propagation", "private", "bash", "-c",
                                       chroot_script, "runix-chroot", external.path},
                                      error)) {
                return "Could not open the chroot: " + error;
            }
            return "";
    }
    return "";
}

/// The console changes size under the installer when a GPU driver loads late
/// and the console font is set again; the resize signal does not always
/// reach curses. Checks the real size and redraws everything when it moved.
void follow_terminal_size() {
    winsize size{};
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) != 0 || size.ws_row == 0 || size.ws_col == 0) return;
    if (size.ws_row == LINES && size.ws_col == COLS) return;
    resizeterm(size.ws_row, size.ws_col);
    clearok(curscr, TRUE);
}

Exit run(Options options) {
    auto queue = std::make_shared<Queue>();
    App app(std::move(options), queue);
    while (true) {
        follow_terminal_size();
        ui::draw(app);
        // Snake moves on a short timer; the rest of the installer needs no hurry.
        timeout(app.playing() ? 20 : 100);
        Key key = read_key();
        if (key.code != Key::Code::Other) app.on_key(key);
        while (auto message = queue->pop()) app.on_message(std::move(*message));
        if (app.external) {
            External external = *app.external;
            app.external.reset();
            endwin();
            set_console_palette(false);
            std::string error = run_external(external);
            set_console_palette(true);
            refresh();
            clearok(curscr, TRUE);
            app.after_external(error);
        }
        app.tick();
        if (app.exit) return *app.exit;
    }
}

}  // namespace

int main(int argc, char** argv) {
    bool demo = false;
    bool demo_fail = false;
    std::optional<std::string> language;
    for (int index = 1; index < argc; ++index) {
        std::string argument = argv[index];
        if (argument == "--demo") {
            demo = true;
        } else if (argument == "--demo-fail") {
            demo = true;
            demo_fail = true;
        } else if (argument == "--language" && index + 1 < argc) {
            language = argv[++index];
        } else if (argument == "-h" || argument == "--help") {
            std::fputs(usage, stdout);
            return 0;
        } else {
            std::fprintf(stderr, "runix-installer: unknown argument: %s\n%s", argument.c_str(), usage);
            return 2;
        }
    }
    if (!demo && geteuid() != 0) {
        std::fputs("runix-installer: run this as root, or use --demo to try the interface\n", stderr);
        return 1;
    }
    // A command whose output pipe closes early must not end the installer.
    std::signal(SIGPIPE, SIG_IGN);
    use_utf8_locale();
    // Esc should act at once rather than wait for an escape sequence.
    setenv("ESCDELAY", "25", 0);

    auto env = [](const char* name) -> std::optional<std::string> {
        const char* value = std::getenv(name);
        return value ? std::optional<std::string>(value) : std::nullopt;
    };
    Options options;
    options.demo = demo;
    options.demo_fail = demo_fail;
    options.paste_url = env("RUNIX_LOG_PASTE_URL").value_or(report::default_paste_url);
    options.flake = env("RUNIX_INSTALL_FLAKE").value_or("github:runix-community/runix");
    options.zoneinfo = system_probe::find_zoneinfo(
        {env("RUNIX_ZONEINFO"), env("TZDIR"), std::string("/usr/share/zoneinfo"), std::string("/etc/zoneinfo")});

    if (auto directories = env("RUNIX_INSTALLER_TRANSLATIONS")) {
        const std::string& list = *directories;
        for (std::size_t start = 0; start <= list.size();) {
            std::size_t end = list.find(':', start);
            if (end == std::string::npos) end = list.size();
            if (end > start)
                for (const auto& problem : i18n::load(list.substr(start, end - start)))
                    std::fprintf(stderr, "runix-installer: %s\n", problem.c_str());
            start = end + 1;
        }
    }
    if (auto path = env("RUNIX_INSTALLER_SETTINGS")) {
        std::ifstream file(*path);
        std::stringstream text;
        text << file.rdbuf();
        std::string problem = file ? read_defaults(text.str(), options.defaults) : "cannot be read";
        if (!problem.empty()) std::fprintf(stderr, "runix-installer: %s: %s\n", path->c_str(), problem.c_str());
    }
    if (!language) language = env("RUNIX_INSTALLER_LANGUAGE");
    if (language) options.defaults.language = *language;
    if (!options.defaults.language.empty() && !i18n::use(options.defaults.language))
        std::fprintf(stderr, "runix-installer: no translation for %s, using English\n",
                     options.defaults.language.c_str());

    set_console_palette(true);
    start_screen();
    Exit result = run(std::move(options));
    endwin();
    set_console_palette(false);

    const char* power = nullptr;
    if (result == Exit::Reboot) power = "reboot";
    if (result == Exit::Poweroff) power = "poweroff";
    if (!power) return 0;
    if (demo) {
        std::printf("demo: would run %s\n", power);
        return 0;
    }
    std::string path = std::string("/run/current-system/bin/") + power;
    execl(path.c_str(), power, static_cast<char*>(nullptr));
    std::fprintf(stderr, "runix-installer: could not %s: %s\n", power, std::strerror(errno));
    return 1;
}
