#include "ui.hpp"

#include <algorithm>
#include <array>
#include <cstdio>
#include <ncurses.h>

#include "app.hpp"
#include "install.hpp"
#include "report.hpp"
#include "util.hpp"

namespace ui {

namespace {

// Named colors, so the console palette set in main.cpp decides the shades.
enum class Color {
    Accent,
    Light,
    Muted,
    Warn,
    Error,
    Blue,
    Magenta,
    Cyan,
    LightMagenta,
    LightYellow,
    LightCyan,
    Black,
};
constexpr int color_count = 12;
constexpr int background_pairs = 20;

bool many_colors = false;

struct ColorSpec {
    short number;
    bool bright;
};

ColorSpec spec(Color color) {
    switch (color) {
        case Color::Accent: return {COLOR_GREEN, false};
        case Color::Light: return {COLOR_WHITE, true};
        case Color::Muted: return {COLOR_BLACK, true};
        case Color::Warn: return {COLOR_YELLOW, false};
        case Color::Error: return {COLOR_RED, false};
        case Color::Blue: return {COLOR_BLUE, false};
        case Color::Magenta: return {COLOR_MAGENTA, false};
        case Color::Cyan: return {COLOR_CYAN, false};
        case Color::LightMagenta: return {COLOR_MAGENTA, true};
        case Color::LightYellow: return {COLOR_YELLOW, true};
        case Color::LightCyan: return {COLOR_CYAN, true};
        case Color::Black: return {COLOR_BLACK, false};
    }
    return {COLOR_WHITE, false};
}

/// With 16 colors a bright color is its own number; with 8 it is bold.
short number(Color color) {
    ColorSpec value = spec(color);
    return static_cast<short>(value.bright && many_colors ? value.number + 8 : value.number);
}

attr_t fg(Color color, bool bold = false) {
    attr_t attributes = COLOR_PAIR(1 + static_cast<int>(color));
    if (bold || (spec(color).bright && !many_colors)) attributes |= A_BOLD;
    return attributes;
}

attr_t bg(Color color) {
    return COLOR_PAIR(background_pairs + static_cast<int>(color)) | A_BOLD;
}

struct Span {
    std::string text;
    attr_t attributes = A_NORMAL;
};
using Line = std::vector<Span>;

Span span(std::string text, Color color, bool bold = false) {
    return {std::move(text), fg(color, bold)};
}
Span plain(std::string text) {
    return {std::move(text), A_NORMAL};
}
Line muted(std::string text) {
    return {span(std::move(text), Color::Muted)};
}
std::size_t line_width(const Line& line) {
    std::size_t total = 0;
    for (const auto& part : line) total += util::width(part.text);
    return total;
}

struct Rect {
    int x = 0, y = 0, w = 0, h = 0;
};

/// Splits off `rows` rows from the top of `area`.
Rect take_rows(Rect& area, int rows) {
    rows = std::clamp(rows, 0, area.h);
    Rect top{area.x, area.y, area.w, rows};
    area.y += rows;
    area.h -= rows;
    return top;
}

/// A centered column of at most `width`, with a little margin on small screens.
Rect column(Rect area, int width) {
    width = std::max(std::min(width, area.w - 4), std::min(area.w, 20));
    return {area.x + (area.w - width) / 2, area.y, width, area.h};
}

void put(int y, int x, const std::string& text, attr_t attributes, int room) {
    if (room <= 0 || y < 0 || y >= LINES || x >= COLS) return;
    std::string clipped = util::take(text, static_cast<std::size_t>(room));
    attron(attributes);
    mvaddstr(y, x, clipped.c_str());
    attroff(attributes);
}

/// Draws a line, cut at the area's right edge. `fill` paints the whole row.
void draw_line(int y, int x, int width, const Line& line, attr_t fill = 0) {
    if (fill) put(y, x, std::string(static_cast<std::size_t>(std::max(width, 0)), ' '), fill, width);
    int column_x = x;
    for (const auto& part : line) {
        int room = x + width - column_x;
        if (room <= 0) break;
        put(y, column_x, part.text, part.attributes | fill, room);
        column_x += static_cast<int>(util::width(part.text));
    }
}

void draw_lines(Rect area, const std::vector<Line>& lines) {
    for (int row = 0; row < area.h && row < static_cast<int>(lines.size()); ++row) {
        draw_line(area.y + row, area.x, area.w, lines[static_cast<std::size_t>(row)]);
    }
}

/// One styled text wrapped at spaces to the area's width.
std::vector<Line> wrapped(const std::string& text, attr_t attributes, int width) {
    std::vector<Line> lines;
    for (const auto& piece : util::wrap(text, static_cast<std::size_t>(std::max(width, 1)))) {
        lines.push_back({Span{piece, attributes}});
    }
    return lines;
}

constexpr int column_width = 76;
constexpr std::array<char, 4> spinner_frames{'|', '/', '-', '\\'};

char spinner(const App& app) {
    return spinner_frames[app.frame / 2 % spinner_frames.size()];
}

// The Runix snowflake from assets/runix-logo-fastfetch.txt.
enum class Tone { Light, Green };
struct Piece {
    Tone tone;
    const char* text;
};
const std::array<std::vector<Piece>, 7> mark{{
    {{Tone::Light, "  \\  "}, {Tone::Green, "\\ //"}},
    {{Tone::Light, " ==\\__"}, {Tone::Green, "\\/ "}, {Tone::Light, "//"}},
    {{Tone::Green, "   //   \\"}, {Tone::Light, "//"}},
    {{Tone::Green, "==//     "}, {Tone::Light, "//=="}},
    {{Tone::Green, " //"}, {Tone::Light, "\\ "}, {Tone::Green, "___"}, {Tone::Light, "//"}},
    {{Tone::Green, "// "}, {Tone::Light, "/\\  "}, {Tone::Green, "\\=="}},
    {{Tone::Light, "  // \\  "}, {Tone::Green, "\\==="}},
}};
constexpr int mark_width = 13;

const std::array<const char*, 5> wordmark{
    "████▄  █   █  █▄  █  ███  █   █",
    "█   █  █   █  █▀▄ █   █   ▀▄ ▄▀",
    "████▀  █   █  █ ▀▄█   █     █  ",
    "█  ▀▄  █   █  █  ▀█   █   ▄▀ ▀▄",
    "█   █  ▀▄▄▄▀  █   █  ███  █   █",
};

constexpr int logo_width = mark_width + 3 + 31;
constexpr int logo_height = 7;
/// Below this height the mark is replaced by a one-line header.
constexpr int logo_min_rows = 30;

std::vector<Line> logo() {
    std::vector<Line> lines;
    for (int row = 0; row < logo_height; ++row) {
        Line line;
        int width = 0;
        for (const auto& piece : mark[static_cast<std::size_t>(row)]) {
            width += static_cast<int>(util::width(piece.text));
            line.push_back(span(piece.text, piece.tone == Tone::Light ? Color::Light : Color::Accent, true));
        }
        line.push_back(plain(std::string(static_cast<std::size_t>(mark_width - width + 3), ' ')));
        if (row >= 1 && row - 1 < static_cast<int>(wordmark.size())) {
            line.push_back(span(wordmark[static_cast<std::size_t>(row - 1)], Color::Light, true));
        }
        lines.push_back(line);
    }
    return lines;
}

Line compact_header() {
    return {span("runix", Color::Accent, true), span("  installer", Color::Muted)};
}

std::string subtitle(const App& app) {
    switch (app.screen) {
        case Screen::Network: return "Runix downloads its packages while installing.";
        case Screen::Disk: return "Choose the disk to install Runix on.";
        case Screen::Bootloader:
            return app.boot_mode == config::BootMode::Efi
                       ? "This machine boots with UEFI. Both loaders list every Runix generation."
                       : "This machine boots with legacy BIOS. Both loaders list every Runix generation.";
        case Screen::Partitioning: return "Let the installer partition the disk, or pick partitions yourself.";
        case Screen::Partitions: return "Mark a boot and a root partition. Others are left alone.";
        case Screen::Filesystem: return "Choose a filesystem for the root partition.";
        case Screen::Account: return "Name this computer and create your administrator account.";
        case Screen::Timezone: return "Type to search, then pick yours.";
        case Screen::Desktop: return "Desktops take longer to install.";
        case Screen::Connection: return "Wi-Fi keeps the network you joined here.";
        case Screen::Review: return "Last chance to go back. Nothing has changed yet.";
        case Screen::Installing: return "This takes a while. Keep the computer powered on.";
        case Screen::Failed: return "Nothing past the failed step was run.";
        case Screen::Done: return "Remove the installation medium, then reboot.";
        case Screen::Welcome: return "";
    }
    return "";
}

Line progress_dots(const App& app) {
    std::vector<Screen> steps;
    for (Screen step : wizard) {
        if (app.applicable(step)) steps.push_back(step);
    }
    auto found = std::find(steps.begin(), steps.end(), app.screen);
    Line line;
    for (std::size_t index = 0; index < steps.size(); ++index) {
        if (found == steps.end()) {
            line.push_back(span("■", Color::Accent));
        } else {
            auto current = static_cast<std::size_t>(found - steps.begin());
            if (index == current) {
                line.push_back(span("■", Color::Light, true));
            } else if (index > current) {
                line.push_back(span("·", Color::Muted));
            } else {
                line.push_back(span("■", Color::Accent));
            }
        }
        line.push_back(plain(" "));
    }
    if (found != steps.end()) {
        line.push_back(span(" " + std::to_string(found - steps.begin() + 1) + "/" + std::to_string(steps.size()),
                            Color::Muted));
    }
    return line;
}

/// Draws the shared header and returns the area left for the screen itself.
Rect draw_frame(const App& app, Rect body) {
    Rect area = column(body, std::max(column_width, logo_width));
    bool large = body.h >= logo_min_rows && area.w >= logo_width;
    take_rows(area, 1);
    Rect header = take_rows(area, large ? logo_height : 1);
    take_rows(area, 1);
    Rect steps = take_rows(area, 1);
    Rect heading = take_rows(area, 1);
    Rect sub = take_rows(area, 1);
    take_rows(area, 1);

    if (large) {
        draw_lines(header, logo());
    } else {
        draw_lines(header, {compact_header()});
    }
    draw_lines(steps, {progress_dots(app)});
    Color heading_color = app.screen == Screen::Failed ? Color::Error : Color::Light;
    draw_lines(heading, {{span(title(app.screen), heading_color, true)}});
    draw_lines(sub, {muted(subtitle(app))});
    return area;
}

void draw_footer(const App& app, Rect area) {
    Line line;
    bool first = true;
    for (const auto& [key, action] : app.hints()) {
        if (!first) line.push_back(span("  ·  ", Color::Muted));
        first = false;
        line.push_back(span(key, Color::Light, true));
        line.push_back(span(" " + action, Color::Muted));
    }
    int width = static_cast<int>(line_width(line));
    draw_line(area.y, area.x + std::max(0, (area.w - width) / 2), area.w, line);
}

void draw_welcome(Rect area) {
    bool large = area.h >= logo_height + 10 && area.w >= logo_width + 2;
    std::vector<Line> lines = large ? logo() : std::vector<Line>{compact_header()};
    lines.push_back({});
    lines.push_back(muted("A NixOS that runs on runit."));
    lines.push_back({});
    lines.push_back({plain("This installs Runix on a whole disk. Nothing is")});
    lines.push_back({plain("changed until you confirm on the last screen.")});
    lines.push_back({});
    lines.push_back({plain("Press "), span("Enter", Color::Accent, true), plain(" to begin")});
    lines.push_back({});
    lines.push_back(muted("A shell is waiting on tty2 (Alt+F2)."));
    int height = static_cast<int>(lines.size());
    Rect block = column(area, large ? logo_width : 50);
    block.y = area.y + std::max(0, (area.h - height) / 2);
    block.h = std::min(height, area.h);
    draw_lines(block, lines);
}

/// A selectable list. The selected row is drawn in the accent color.
void choice_list(Rect area, const std::vector<Line>& items, ListState& state) {
    if (area.h <= 0) return;
    auto rows = static_cast<std::size_t>(area.h);
    if (state.selected) {
        std::size_t selected = std::min(*state.selected, items.empty() ? 0 : items.size() - 1);
        if (selected < state.offset) state.offset = selected;
        if (selected >= state.offset + rows) state.offset = selected + 1 - rows;
    }
    if (state.offset > items.size()) state.offset = 0;
    for (std::size_t row = 0; row < rows && state.offset + row < items.size(); ++row) {
        std::size_t index = state.offset + row;
        int y = area.y + static_cast<int>(row);
        if (state.selected == index) {
            Line line{span("▌ ", Color::Accent, true)};
            for (const auto& part : items[index]) line.push_back(span(part.text, Color::Accent, true));
            draw_line(y, area.x, area.w, line);
        } else {
            Line line{plain("  ")};
            line.insert(line.end(), items[index].begin(), items[index].end());
            draw_line(y, area.x, area.w, line);
        }
    }
}

Line entry(const std::string& name, const std::string& detail, std::size_t width) {
    return {plain(util::pad_right(name, width)), span(detail, Color::Muted)};
}

void draw_network(App& app, Rect area) {
    Rect status = take_rows(area, 1);
    take_rows(area, 1);
    Line line;
    if (app.connecting) {
        line = {span(std::string(1, spinner(app)) + " Joining " + *app.connecting + "...", Color::Warn)};
    } else if (app.online == OnlineState::Online) {
        line = {span("■ Online", Color::Accent, true)};
    } else if (app.online == OnlineState::Checking) {
        line = {span(std::string(1, spinner(app)) + " Checking the connection...", Color::Warn)};
    } else {
        line = {span("■ Offline", Color::Error, true), span("  wired networks connect by themselves", Color::Muted)};
    }
    draw_lines(status, {line});

    if (!app.wireless) {
        draw_lines(area, {muted("No wireless card found.")});
        return;
    }
    if (app.networks.empty()) {
        draw_lines(area, {muted(app.scanning ? std::string(1, spinner(app)) + " Looking for Wi-Fi networks..."
                                             : "No Wi-Fi networks found. Press r to scan again.")});
        return;
    }
    std::vector<Line> items;
    for (const auto& network : app.networks) items.push_back(entry(network.ssid, network.secured ? "secured" : "open", 34));
    choice_list(area, items, app.network_list);
}

void draw_disks(App& app, Rect area) {
    if (app.disks.empty()) {
        std::vector<Line> lines{{span("No usable disk was found.", Color::Warn, true)}};
        auto more = wrapped("Runix needs a writable disk of at least " +
                                util::format_size(system_probe::minimum_disk_bytes) + ". Press r to look again.",
                            fg(Color::Muted), area.w);
        lines.insert(lines.end(), more.begin(), more.end());
        draw_lines(area, lines);
        return;
    }
    std::vector<Line> items;
    for (const auto& disk : app.disks) {
        items.push_back(entry(util::pad_right(disk.path, 14) + util::pad_left(util::format_size(disk.size), 10),
                              "  " + disk.model, 24));
    }
    choice_list(area, items, app.disk_list);
}

struct Segment {
    std::string label;
    /// What the bar itself shows: a role, a partition name, or "free".
    std::string short_label;
    std::string detail;
    std::uint64_t size = 0;
    Color color = Color::Muted;
    bool free = false;
};

/// Partitions without a role cycle through these; red is kept for errors.
constexpr std::array<Color, 6> other_colors{
    Color::Magenta, Color::Warn, Color::Cyan, Color::LightMagenta, Color::LightYellow, Color::LightCyan,
};
constexpr int bar_height = 3;

/// The label written inside a segment, or nothing when it does not fit.
std::string bar_label(const Segment& segment, std::uint64_t total, std::size_t cells) {
    std::size_t room = cells > 2 ? cells - 2 : 0;
    std::string full = segment.short_label + " " + util::percent(segment.size, total);
    if (util::width(full) <= room) return full;
    if (util::width(segment.short_label) <= room) return segment.short_label;
    return "";
}

std::uint64_t total_size(const std::vector<Segment>& segments) {
    std::uint64_t total = 0;
    for (const auto& segment : segments) total += segment.size;
    return total;
}

/// One bar for the whole disk, every segment labelled inside when it fits.
std::vector<Line> bar_lines(const std::vector<Segment>& segments, int width) {
    std::uint64_t total = total_size(segments);
    std::vector<std::uint64_t> sizes;
    for (const auto& segment : segments) sizes.push_back(segment.size);
    auto cells = segment_cells(sizes, static_cast<std::size_t>(std::max(width, 0)));
    std::vector<Line> lines;
    for (int row = 0; row < bar_height; ++row) {
        Line line;
        for (std::size_t index = 0; index < segments.size(); ++index) {
            const auto& segment = segments[index];
            std::string label = row == bar_height / 2 ? bar_label(segment, total, cells[index]) : "";
            std::size_t length = util::width(label);
            std::size_t left = (cells[index] - length) / 2;
            std::size_t right = cells[index] - length - left;
            if (segment.free) {
                line.push_back(span(util::repeat("░", left) + label + util::repeat("░", right), Color::Muted));
            } else {
                line.push_back({std::string(left, ' ') + label + std::string(right, ' '), bg(segment.color)});
            }
        }
        lines.push_back(line);
    }
    return lines;
}

std::vector<Line> legend_lines(const std::vector<Segment>& segments) {
    std::uint64_t total = total_size(segments);
    std::vector<Line> lines;
    for (const auto& segment : segments) {
        lines.push_back({
            span(segment.free ? "░░" : "██", segment.color),
            span(" " + util::pad_right(segment.label, 16), Color::Light),
            plain(util::pad_left(util::format_size(segment.size), 10)),
            span(util::pad_left(util::percent(segment.size, total), 8) + "  ", Color::Light, true),
            span(segment.detail, Color::Muted),
        });
    }
    return lines;
}

void disk_map(Rect area, const std::vector<Segment>& segments, bool legend) {
    auto lines = bar_lines(segments, area.w);
    if (legend) {
        lines.push_back({});
        auto more = legend_lines(segments);
        lines.insert(lines.end(), more.begin(), more.end());
    }
    draw_lines(area, lines);
}

/// The disk after an automatic install.
std::vector<Segment> automatic_segments(std::uint64_t disk_size) {
    std::uint64_t boot = std::min(install::boot_size, disk_size);
    return {
        {"boot", "boot", "FAT32, kernels and the boot loader", boot, Color::Blue, false},
        {"root", "root", "the system, your files and the Nix store", disk_size - boot, Color::Accent, false},
    };
}

const char* role(const App& app, const system_probe::Partition& partition, Color& color) {
    if (app.boot_partition == partition.path) {
        color = Color::Blue;
        return "boot";
    }
    if (app.root_partition == partition.path) {
        color = Color::Accent;
        return "root";
    }
    return nullptr;
}

std::string describe(const system_probe::Partition& partition) {
    std::string fstype = partition.fstype.value_or("empty");
    return partition.kind ? fstype + ", " + *partition.kind : fstype;
}

std::string base_name(const std::string& path) {
    auto slash = path.rfind('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

/// The disk as it is now, colored by the roles chosen so far.
std::vector<Segment> manual_segments(const App& app, std::uint64_t disk_size) {
    std::vector<Segment> segments;
    std::size_t next_color = 0;
    std::uint64_t used = 0;
    for (const auto& partition : app.partitions) {
        used += partition.size;
        std::string name = base_name(partition.path);
        Color color = Color::Magenta;
        Segment segment;
        if (const char* chosen = role(app, partition, color)) {
            segment.label = name + " " + chosen;
            segment.short_label = chosen;
        } else {
            color = other_colors[next_color++ % other_colors.size()];
            segment.label = name;
            segment.short_label = name;
        }
        segment.detail = describe(partition);
        segment.size = partition.size;
        segment.color = color;
        segments.push_back(segment);
    }
    std::uint64_t free = disk_size > used ? disk_size - used : 0;
    // GPT and alignment always leave a few MiB, which is not worth showing.
    if (free > 16ull * 1024 * 1024) {
        segments.push_back({"unallocated", "free", "create partitions here with cfdisk", free, Color::Muted, true});
    }
    return segments;
}

std::uint64_t disk_size(const App& app) {
    const auto* disk = app.disk();
    return disk ? disk->size : 0;
}

void draw_partitioning(App& app, Rect area) {
    Rect list = take_rows(area, 2);
    take_rows(area, 1);
    choice_list(list,
                {entry("Automatic", "erase the whole disk and partition it for you", 12),
                 entry("Manual", "use existing partitions, or make them in cfdisk", 12)},
                app.partitioning_list);
    disk_map(area, app.manual() ? manual_segments(app, disk_size(app)) : automatic_segments(disk_size(app)), true);
}

void draw_partitions(App& app, Rect area) {
    auto segments = manual_segments(app, disk_size(app));
    Rect map = take_rows(area, bar_height);
    take_rows(area, 1);
    Rect status{area.x, area.y + std::max(0, area.h - 2), area.w, std::min(2, area.h)};
    area.h = std::max(0, area.h - 2);
    // Only the bar here: the list below already names every partition.
    disk_map(map, segments, false);

    if (app.partitions.empty()) {
        draw_lines(area, {muted("This disk has no partitions yet. Press e to create them in cfdisk.")});
    } else {
        std::vector<Line> items;
        for (const auto& partition : app.partitions) {
            Line line{plain(util::pad_right(partition.path, 16) + util::pad_left(util::format_size(partition.size), 10) + "  "),
                      span(util::fit(describe(partition), 28), Color::Muted)};
            Color color = Color::Muted;
            if (const char* chosen = role(app, partition, color)) {
                std::string tag = std::string(chosen) == "boot"
                                      ? std::string("boot, ") + (app.format_boot ? "format" : "keep")
                                      : "root, format";
                line.push_back(span(tag, color, true));
            } else if (partition.mounted) {
                line.push_back(span("mounted", Color::Warn));
            }
            items.push_back(line);
        }
        choice_list(area, items, app.partition_list);
    }

    const auto* root = app.partition(app.root_partition);
    if (app.partition_error) {
        draw_lines(status, wrapped(*app.partition_error, fg(Color::Error), status.w));
    } else if (root && root->fstype) {
        draw_lines(status, wrapped(root->path + " holds " + *root->fstype + " data. It will be erased.",
                                   fg(Color::Warn, true), status.w));
    } else {
        draw_lines(status, {muted("Only the boot and root partitions are touched.")});
    }
}

void draw_bootloader(App& app, Rect area) {
    std::vector<Line> items;
    for (auto loader : config::loaders) items.push_back(entry(config::name(loader), config::description(loader), 10));
    choice_list(area, items, app.bootloader_list);
}

void draw_filesystem(App& app, Rect area) {
    std::vector<Line> items;
    for (auto filesystem : config::filesystems) {
        items.push_back(entry(config::name(filesystem), config::description(filesystem), 10));
    }
    choice_list(area, items, app.filesystem_list);
}

void draw_desktop(App& app, Rect area) {
    std::vector<Line> items;
    for (auto desktop : config::desktops) items.push_back({plain(config::name(desktop))});
    choice_list(area, items, app.desktop_list);
}

void draw_connection(App& app, Rect area) {
    std::vector<Line> items;
    for (auto network : config::networks) items.push_back({plain(config::name(network))});
    choice_list(area, items, app.connection_list);
}

Line field(const std::string& label, const Input& input, bool focused) {
    Line line{
        span(focused ? "▌ " : "  ", Color::Accent),
        focused ? span(util::pad_right(label, 18), Color::Accent, true) : span(util::pad_right(label, 18), Color::Muted),
        span(input.display(), Color::Light),
    };
    if (focused) line.push_back({"_", fg(Color::Accent) | A_BLINK});
    return line;
}

void draw_account(App& app, Rect area) {
    std::vector<Line> lines{
        field("Host name", app.host, app.focus == 0), {},
        field("User name", app.user, app.focus == 1), {},
        field("Password", app.password, app.focus == 2), {},
        field("Confirm password", app.confirm, app.focus == 3), {},
    };
    if (app.form_error) {
        auto error = wrapped(*app.form_error, fg(Color::Error), area.w);
        lines.insert(lines.end(), error.begin(), error.end());
    }
    draw_lines(area, lines);
}

void draw_timezone(App& app, Rect area) {
    Rect search = take_rows(area, 1);
    take_rows(area, 1);
    draw_lines(search, {field("Search", app.zone_filter, true)});
    std::vector<Line> items;
    for (const auto& zone : app.visible_zones()) items.push_back({plain(zone)});
    if (items.empty()) {
        draw_lines(area, {muted("No time zone matches.")});
        return;
    }
    choice_list(area, items, app.zone_list);
}

void draw_review(App& app, Rect area) {
    std::vector<Line> lines;
    for (const auto& [label, value] : app.summary()) {
        lines.push_back({span("  " + util::pad_right(label, 14), Color::Muted), span(value, Color::Light)});
    }
    lines.push_back({});
    auto layout = app.layout();
    std::string warning;
    if (layout.kind == install::DiskLayout::Kind::Automatic) {
        warning = "All data on this disk will be destroyed.";
    } else if (layout.format_boot) {
        warning = "All data on " + layout.boot + " and " + layout.root + " will be destroyed.";
    } else {
        warning = "All data on " + layout.root + " will be destroyed.";
    }
    lines.push_back({span("  " + warning, Color::Error, true)});
    lines.push_back({});
    lines.push_back(field("Type ERASE", app.confirmation, true));
    if (app.confirmation.value == confirmation_word) {
        lines.push_back({});
        lines.push_back({span("  Press Enter to install.", Color::Accent, true)});
    }
    draw_lines(area, lines);
}

std::string format_elapsed(const App& app) {
    App::Clock::duration elapsed{};
    if (app.finished) {
        elapsed = *app.finished;
    } else if (app.started) {
        elapsed = App::Clock::now() - *app.started;
    }
    auto seconds = std::chrono::duration_cast<std::chrono::seconds>(elapsed).count();
    char buffer[32];
    std::snprintf(buffer, sizeof buffer, "%02lld:%02lld", static_cast<long long>(seconds / 60),
                  static_cast<long long>(seconds % 60));
    return buffer;
}

std::vector<Line> phase_lines(const App& app) {
    std::vector<Line> lines;
    for (std::size_t index = 0; index < install::phases.size(); ++index) {
        std::string name = install::phases[index];
        if (index < app.phase || app.phase_done) {
            lines.push_back({span("■ " + name, Color::Accent)});
        } else if (index == app.phase && app.error) {
            lines.push_back({span("x " + name, Color::Error, true)});
        } else if (index == app.phase) {
            lines.push_back({span(std::string(1, spinner(app)) + " " + name, Color::Light, true)});
        } else {
            lines.push_back({span("· " + name, Color::Muted)});
        }
    }
    return lines;
}

Line progress_bar(const App& app, int width) {
    double fraction = app.overall_progress();
    char label[48];
    std::snprintf(label, sizeof label, " %3d%%  %s", static_cast<int>(fraction * 100), format_elapsed(app).c_str());
    std::size_t cells = static_cast<std::size_t>(std::max(0, width - static_cast<int>(util::width(label))));
    auto filled = static_cast<std::size_t>(static_cast<double>(cells) * fraction);
    return {span(util::repeat("█", filled), Color::Accent), span(util::repeat("░", cells - filled), Color::Muted),
            span(label, Color::Light)};
}

/// Nix's own counts while the system is built, for example "3/12 built".
std::vector<Line> nix_lines(const App& app) {
    if (app.nix.summary.empty() && app.nix.current.empty()) return {{}, {}};
    return {{span(app.nix.summary, Color::Light, true)}, {span(app.nix.current, Color::Muted)}};
}

void draw_log(const App& app, Rect area) {
    auto height = static_cast<std::size_t>(std::max(area.h, 0));
    std::size_t end = app.log.size() > app.scroll ? app.log.size() - app.scroll : 0;
    std::size_t start = end > height ? end - height : 0;
    std::vector<Line> lines;
    for (std::size_t index = start; index < end; ++index) lines.push_back(muted(app.log[index]));
    draw_lines(area, lines);
}

void draw_installing(App& app, Rect area) {
    draw_lines(take_rows(area, static_cast<int>(install::phases.size())), phase_lines(app));
    take_rows(area, 1);
    draw_lines(take_rows(area, 1), {progress_bar(app, area.w)});
    if (app.phase == 4 || !app.nix.summary.empty()) {
        draw_lines(take_rows(area, 2), nix_lines(app));
    }
    take_rows(area, 1);
    draw_log(app, area);
}

void draw_failed(App& app, Rect area) {
    std::vector<Line> message = wrapped(app.error.value_or("The installation failed."), fg(Color::Error, true), area.w);
    message.push_back(muted(std::string("Full log: ") + install::log_path));
    if (app.uploading) {
        message.push_back({span(std::string(1, spinner(app)) + " Uploading the log...", Color::Warn)});
    } else if (app.upload_url) {
        message.push_back({span("Log uploaded: ", Color::Light), span(*app.upload_url, Color::Accent, true)});
        auto next = wrapped(std::string("Open an issue at ") + report::issues_url + " and include this link.",
                            fg(Color::Muted), area.w);
        message.insert(message.end(), next.begin(), next.end());
    } else if (app.upload_error) {
        auto failed = wrapped("Upload failed: " + *app.upload_error, fg(Color::Error), area.w);
        message.insert(message.end(), failed.begin(), failed.end());
    } else {
        message.push_back(muted("Press u to upload the log for a bug report."));
    }
    draw_lines(take_rows(area, static_cast<int>(message.size())), message);
    take_rows(area, 1);
    draw_lines(take_rows(area, static_cast<int>(install::phases.size())), phase_lines(app));
    if (!app.nix.summary.empty()) draw_lines(take_rows(area, 1), {muted(app.nix.summary)});
    take_rows(area, 1);
    draw_log(app, area);
}

void draw_done(App& app, Rect area) {
    draw_lines(take_rows(area, 2), {{span("Runix is installed.", Color::Accent, true)},
                                    muted("Finished in " + format_elapsed(app) + ".")});
    take_rows(area, 1);
    std::vector<Line> items;
    for (const char* action : done_actions) items.push_back({plain(action)});
    choice_list(area, items, app.done_list);
}

void draw_modal(const App& app) {
    if (!app.modal) return;
    const Modal& modal = *app.modal;
    std::string heading;
    std::vector<Line> lines;
    int width = std::min(60, COLS);
    int inner = std::max(1, width - 4);
    switch (modal.kind) {
        case Modal::Kind::Quit:
            heading = "Exit installer";
            lines = {{plain("Exit to a shell?")}, muted("Run runix-installer to start again.")};
            break;
        case Modal::Kind::WifiName:
            heading = "Other network";
            lines = {field("Network name", modal.input, true)};
            break;
        case Modal::Kind::WifiPassword:
            heading = "Join Wi-Fi";
            lines = {{plain("Password for " + modal.ssid)}, muted("Leave it empty for an open network."), {},
                     field("Password", modal.input, true)};
            break;
        case Modal::Kind::UploadLog: {
            heading = "Upload log";
            std::string service = app.options.paste_url;
            if (auto scheme = service.find("://"); scheme != std::string::npos) service = service.substr(scheme + 3);
            if (!service.empty() && service.back() == '/') service.pop_back();
            lines = wrapped("Upload the install log to " + service +
                                "? Anyone with the link can read it. Your host and user names are replaced; "
                                "disk names and package versions stay.",
                            A_NORMAL, inner);
            lines.push_back({});
            lines.push_back({span("enter", Color::Light, true), span(" upload  ·  ", Color::Muted),
                             span("esc", Color::Light, true), span(" cancel", Color::Muted)});
            break;
        }
        case Modal::Kind::Notice:
            heading = "Notice";
            lines = wrapped(modal.text, A_NORMAL, inner);
            break;
    }
    int height = std::min(static_cast<int>(lines.size()) + 4, LINES);
    int x = (COLS - width) / 2;
    int y = (LINES - height) / 2;
    attr_t border = fg(Color::Accent);
    for (int row = 0; row < height; ++row) {
        std::string text;
        if (row == 0) {
            text = "┌" + util::repeat("─", static_cast<std::size_t>(width - 2)) + "┐";
        } else if (row == height - 1) {
            text = "└" + util::repeat("─", static_cast<std::size_t>(width - 2)) + "┘";
        } else {
            text = "│" + std::string(static_cast<std::size_t>(width - 2), ' ') + "│";
        }
        put(y + row, x, text, border, width);
    }
    put(y, x + 2, " " + heading + " ", fg(Color::Light, true), width - 4);
    draw_lines({x + 2, y + 2, inner, height - 4}, lines);
}

}  // namespace

std::vector<std::size_t> segment_cells(const std::vector<std::uint64_t>& sizes, std::size_t width) {
    unsigned __int128 total = 0;
    for (auto size : sizes) total += size;
    std::vector<std::size_t> cells(sizes.size(), 0);
    if (total == 0 || width == 0) return cells;
    for (std::size_t index = 0; index < sizes.size(); ++index) {
        auto share = static_cast<std::size_t>(static_cast<unsigned __int128>(sizes[index]) * width / total);
        cells[index] = sizes[index] > 0 ? std::max<std::size_t>(share, 1) : 0;
    }
    auto sum = [&] {
        std::size_t total_cells = 0;
        for (auto value : cells) total_cells += value;
        return total_cells;
    };
    while (sum() < width) {
        std::size_t largest = 0;
        for (std::size_t index = 1; index < sizes.size(); ++index) {
            if (std::pair(sizes[index], cells[index]) > std::pair(sizes[largest], cells[largest])) largest = index;
        }
        ++cells[largest];
    }
    while (sum() > width) {
        std::size_t biggest = sizes.size();
        for (std::size_t index = 0; index < sizes.size(); ++index) {
            if (cells[index] > 1 && (biggest == sizes.size() || cells[index] >= cells[biggest])) biggest = index;
        }
        if (biggest == sizes.size()) break;
        --cells[biggest];
    }
    return cells;
}

void init_colors() {
    if (!has_colors()) return;
    start_color();
    use_default_colors();
    many_colors = COLORS >= 16;
    for (int index = 0; index < color_count; ++index) {
        auto color = static_cast<Color>(index);
        init_pair(static_cast<short>(1 + index), number(color), -1);
        init_pair(static_cast<short>(background_pairs + index), COLOR_BLACK, spec(color).number);
    }
}

void draw(App& app) {
    erase();
    Rect screen{0, 0, COLS, LINES};
    Rect body{0, 0, COLS, std::max(0, LINES - 1)};
    Rect footer{0, LINES - 1, COLS, 1};

    if (app.screen == Screen::Welcome) {
        draw_welcome(body);
    } else {
        Rect content = draw_frame(app, body);
        switch (app.screen) {
            case Screen::Welcome: break;
            case Screen::Network: draw_network(app, content); break;
            case Screen::Disk: draw_disks(app, content); break;
            case Screen::Bootloader: draw_bootloader(app, content); break;
            case Screen::Partitioning: draw_partitioning(app, content); break;
            case Screen::Partitions: draw_partitions(app, content); break;
            case Screen::Filesystem: draw_filesystem(app, content); break;
            case Screen::Account: draw_account(app, content); break;
            case Screen::Timezone: draw_timezone(app, content); break;
            case Screen::Desktop: draw_desktop(app, content); break;
            case Screen::Connection: draw_connection(app, content); break;
            case Screen::Review: draw_review(app, content); break;
            case Screen::Installing: draw_installing(app, content); break;
            case Screen::Failed: draw_failed(app, content); break;
            case Screen::Done: draw_done(app, content); break;
        }
    }
    draw_footer(app, footer);
    if (app.options.demo) {
        std::string label = " DEMO · no disks will be changed ";
        int width = std::min(static_cast<int>(util::width(label)), screen.w);
        put(0, screen.w - width, label, bg(Color::Warn), width);
    }
    draw_modal(app);
    refresh();
}

}  // namespace ui
