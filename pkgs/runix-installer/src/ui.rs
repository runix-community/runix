//! Drawing only. One centered column under the Runix mark, one question per
//! screen. Glyphs stay inside the Linux console's built-in font (box drawing,
//! blocks, `·`, `■`) so nothing breaks if the larger console font fails to load.

use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Clear, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Frame;

use crate::app::{App, Input, Modal, OnlineState, Screen, CONFIRMATION, DONE_ACTIONS};
use crate::config::{BootLoader, Desktop, Filesystem, Network};
use crate::install::{DiskLayout, BOOT_SIZE, LOG_PATH, PHASES};
use crate::system::{self, Partition};

// Named colors, so the console palette in main.rs decides the actual shades.
const ACCENT: Color = Color::Green;
const LIGHT: Color = Color::White;
const MUTED: Color = Color::DarkGray;
const WARN: Color = Color::Yellow;
const ERROR: Color = Color::Red;

const COLUMN_WIDTH: u16 = 76;
const SPINNER: [char; 4] = ['|', '/', '-', '\\'];

#[derive(Clone, Copy)]
enum Tone {
    Light,
    Green,
}

/// The Runix snowflake from assets/runix-logo-fastfetch.txt.
const MARK: [&[(Tone, &str)]; 7] = [
    &[(Tone::Light, "  \\  "), (Tone::Green, "\\ //")],
    &[(Tone::Light, " ==\\__"), (Tone::Green, "\\/ "), (Tone::Light, "//")],
    &[(Tone::Green, "   //   \\"), (Tone::Light, "//")],
    &[(Tone::Green, "==//     "), (Tone::Light, "//==")],
    &[(Tone::Green, " //"), (Tone::Light, "\\ "), (Tone::Green, "___"), (Tone::Light, "//")],
    &[(Tone::Green, "// "), (Tone::Light, "/\\  "), (Tone::Green, "\\==")],
    &[(Tone::Light, "  // \\  "), (Tone::Green, "\\===")],
];
const MARK_WIDTH: usize = 13;

const WORDMARK: [&str; 5] = [
    "████▄  █   █  █▄  █  ███  █   █",
    "█   █  █   █  █▀▄ █   █   ▀▄ ▄▀",
    "████▀  █   █  █ ▀▄█   █     █  ",
    "█  ▀▄  █   █  █  ▀█   █   ▄▀ ▀▄",
    "█   █  ▀▄▄▄▀  █   █  ███  █   █",
];

const LOGO_WIDTH: u16 = (MARK_WIDTH + 3 + 31) as u16;
const LOGO_HEIGHT: u16 = 7;
/// Below this height the mark is replaced by a one-line header.
const LOGO_MIN_ROWS: u16 = 30;

fn logo() -> Vec<Line<'static>> {
    (0..LOGO_HEIGHT as usize)
        .map(|row| {
            let mut spans = Vec::new();
            let mut width = 0;
            for (tone, text) in MARK[row] {
                width += text.chars().count();
                let color = match tone {
                    Tone::Light => LIGHT,
                    Tone::Green => ACCENT,
                };
                spans.push(Span::styled(*text, Style::new().fg(color).bold()));
            }
            spans.push(Span::raw(" ".repeat(MARK_WIDTH - width + 3)));
            if let Some(word) = row.checked_sub(1).and_then(|index| WORDMARK.get(index)) {
                spans.push(Span::styled(*word, Style::new().fg(LIGHT).bold()));
            }
            Line::from(spans)
        })
        .collect()
}

fn compact_header() -> Line<'static> {
    Line::from(vec![
        Span::styled("runix", Style::new().fg(ACCENT).bold()),
        Span::styled("  installer", Style::new().fg(MUTED)),
    ])
}

fn spinner(app: &App) -> char {
    SPINNER[app.frame / 2 % SPINNER.len()]
}

fn muted(text: impl Into<String>) -> Line<'static> {
    Line::styled(text.into(), Style::new().fg(MUTED))
}

/// A centered column of at most `width`, with a little margin on small screens.
fn column(area: Rect, width: u16) -> Rect {
    let width = width.min(area.width.saturating_sub(4)).max(area.width.min(20));
    Rect {
        x: area.x + (area.width - width) / 2,
        width,
        ..area
    }
}

pub fn draw(frame: &mut Frame, app: &mut App) {
    let [body, footer] =
        Layout::vertical([Constraint::Min(0), Constraint::Length(1)]).areas(frame.area());

    if app.screen == Screen::Welcome {
        draw_welcome(frame, body);
    } else {
        let content = draw_frame(frame, app, body);
        match app.screen {
            Screen::Welcome => {}
            Screen::Network => draw_network(frame, app, content),
            Screen::Disk => draw_disks(frame, app, content),
            Screen::Bootloader => draw_bootloader(frame, app, content),
            Screen::Partitioning => draw_partitioning(frame, app, content),
            Screen::Partitions => draw_partitions(frame, app, content),
            Screen::Filesystem => draw_filesystem(frame, app, content),
            Screen::Account => draw_account(frame, app, content),
            Screen::Timezone => draw_timezone(frame, app, content),
            Screen::Desktop => draw_desktop(frame, app, content),
            Screen::Connection => draw_connection(frame, app, content),
            Screen::Review => draw_review(frame, app, content),
            Screen::Installing => draw_installing(frame, app, content),
            Screen::Failed => draw_failed(frame, app, content),
            Screen::Done => draw_done(frame, app, content),
        }
    }

    draw_footer(frame, app, footer);
    if app.options.demo {
        let label = " DEMO · no disks will be changed ";
        let width = (label.chars().count() as u16).min(frame.area().width);
        let area = Rect {
            x: frame.area().width.saturating_sub(width),
            y: 0,
            width,
            height: 1.min(frame.area().height),
        };
        frame.render_widget(Span::styled(label, Style::new().fg(Color::Black).bg(WARN)), area);
    }
    draw_modal(frame, app);
}

fn subtitle(app: &App) -> String {
    match app.screen {
        Screen::Network => "Runix downloads its packages while installing.".into(),
        Screen::Disk => "Choose the disk to install Runix on.".into(),
        Screen::Bootloader => match app.boot_mode {
            crate::config::BootMode::Efi => "This machine boots with UEFI. Both loaders list every Runix generation.".into(),
            crate::config::BootMode::Bios => "This machine boots with legacy BIOS. Both loaders list every Runix generation.".into(),
        },
        Screen::Partitioning => "Let the installer partition the disk, or pick partitions yourself.".into(),
        Screen::Partitions => "Mark a boot and a root partition. Others are left alone.".into(),
        Screen::Filesystem => "Choose a filesystem for the root partition.".into(),
        Screen::Account => "Name this computer and create your administrator account.".into(),
        Screen::Timezone => "Type to search, then pick yours.".into(),
        Screen::Desktop => "Desktops take longer to install.".into(),
        Screen::Connection => "Wi-Fi keeps the network you joined here.".into(),
        Screen::Review => "Last chance to go back. Nothing has changed yet.".into(),
        Screen::Installing => "This takes a while. Keep the computer powered on.".into(),
        Screen::Failed => "Nothing past the failed step was run.".into(),
        Screen::Done => "Remove the installation medium, then reboot.".into(),
        Screen::Welcome => String::new(),
    }
}

fn progress(app: &App) -> Line<'static> {
    let steps: Vec<Screen> = Screen::WIZARD
        .iter()
        .copied()
        .filter(|screen| app.applicable(*screen))
        .collect();
    let current = steps.iter().position(|screen| *screen == app.screen);
    let mut spans = Vec::new();
    for index in 0..steps.len() {
        let span = match current {
            Some(current) if index == current => Span::styled("■", Style::new().fg(LIGHT).bold()),
            Some(current) if index > current => Span::styled("·", Style::new().fg(MUTED)),
            _ => Span::styled("■", Style::new().fg(ACCENT)),
        };
        spans.push(span);
        spans.push(Span::raw(" "));
    }
    if let Some(current) = current {
        spans.push(Span::styled(
            format!(" {}/{}", current + 1, steps.len()),
            Style::new().fg(MUTED),
        ));
    }
    Line::from(spans)
}

/// Draws the shared header and returns the area left for the screen itself.
fn draw_frame(frame: &mut Frame, app: &App, body: Rect) -> Rect {
    let area = column(body, COLUMN_WIDTH.max(LOGO_WIDTH));
    let large = body.height >= LOGO_MIN_ROWS && area.width >= LOGO_WIDTH;
    let header_height = if large { LOGO_HEIGHT } else { 1 };
    let [_, header, _, steps, title, subtitle_area, _, content] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(header_height),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(0),
    ])
    .areas(area);

    if large {
        frame.render_widget(Paragraph::new(logo()), header);
    } else {
        frame.render_widget(compact_header(), header);
    }
    frame.render_widget(progress(app), steps);
    let title_color = if app.screen == Screen::Failed { ERROR } else { LIGHT };
    frame.render_widget(
        Line::styled(app.screen.title(), Style::new().fg(title_color).bold()),
        title,
    );
    frame.render_widget(muted(subtitle(app)), subtitle_area);
    content
}

fn draw_footer(frame: &mut Frame, app: &App, area: Rect) {
    let mut spans = Vec::new();
    for (index, (key, action)) in app.hints().into_iter().enumerate() {
        if index > 0 {
            spans.push(Span::styled("  ·  ", Style::new().fg(MUTED)));
        }
        spans.push(Span::styled(key, Style::new().fg(LIGHT).bold()));
        spans.push(Span::styled(format!(" {action}"), Style::new().fg(MUTED)));
    }
    frame.render_widget(Line::from(spans).centered(), area);
}

fn draw_welcome(frame: &mut Frame, area: Rect) {
    let large = area.height >= LOGO_HEIGHT + 10 && area.width >= LOGO_WIDTH + 2;
    let mut lines = if large { logo() } else { vec![compact_header()] };
    lines.extend([
        Line::default(),
        muted("A NixOS that runs on runit."),
        Line::default(),
        Line::from("This installs Runix on a whole disk. Nothing is"),
        Line::from("changed until you confirm on the last screen."),
        Line::default(),
        Line::from(vec![
            Span::raw("Press "),
            Span::styled("Enter", Style::new().fg(ACCENT).bold()),
            Span::raw(" to begin"),
        ]),
        Line::default(),
        muted("A shell is waiting on tty2 (Alt+F2)."),
    ]);
    let height = lines.len() as u16;
    let width = if large { LOGO_WIDTH } else { 50 };
    let block = column(area, width);
    let top = area.y + area.height.saturating_sub(height) / 2;
    let target = Rect {
        y: top,
        height: height.min(area.height),
        ..block
    };
    frame.render_widget(Paragraph::new(lines), target);
}

fn choice_list(frame: &mut Frame, area: Rect, items: Vec<ListItem>, state: &mut ListState) {
    let widget = List::new(items)
        .highlight_style(Style::new().fg(ACCENT).add_modifier(Modifier::BOLD))
        .highlight_symbol("▌ ")
        .repeat_highlight_symbol(false);
    frame.render_stateful_widget(widget, area, state);
}

fn entry(name: impl Into<String>, detail: impl Into<String>, width: usize) -> ListItem<'static> {
    let name = name.into();
    ListItem::new(Line::from(vec![
        Span::raw(format!("{name:<width$}")),
        Span::styled(detail.into(), Style::new().fg(MUTED)),
    ]))
}

fn draw_network(frame: &mut Frame, app: &mut App, area: Rect) {
    let [status, _, list] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(0),
    ])
    .areas(area);
    let line = match (&app.connecting, app.online) {
        (Some(ssid), _) => Line::styled(
            format!("{} Joining {ssid}...", spinner(app)),
            Style::new().fg(WARN),
        ),
        (None, OnlineState::Online) => Line::styled("■ Online", Style::new().fg(ACCENT).bold()),
        (None, OnlineState::Checking) => Line::styled(
            format!("{} Checking the connection...", spinner(app)),
            Style::new().fg(WARN),
        ),
        (None, OnlineState::Offline) => Line::from(vec![
            Span::styled("■ Offline", Style::new().fg(ERROR).bold()),
            Span::styled("  wired networks connect by themselves", Style::new().fg(MUTED)),
        ]),
    };
    frame.render_widget(line, status);

    if !app.wireless {
        frame.render_widget(muted("No wireless card found."), list);
        return;
    }
    if app.networks.is_empty() {
        let text = if app.scanning {
            format!("{} Looking for Wi-Fi networks...", spinner(app))
        } else {
            "No Wi-Fi networks found. Press r to scan again.".to_string()
        };
        frame.render_widget(muted(text), list);
        return;
    }
    let items = app
        .networks
        .iter()
        .map(|network| {
            let security = if network.secured { "secured" } else { "open" };
            entry(network.ssid.clone(), security, 34)
        })
        .collect();
    choice_list(frame, list, items, &mut app.network_list);
}

fn draw_disks(frame: &mut Frame, app: &mut App, area: Rect) {
    if app.disks.is_empty() {
        let text = vec![
            Line::styled("No usable disk was found.", Style::new().fg(WARN).bold()),
            muted(format!(
                "Runix needs a writable disk of at least {}. Press r to look again.",
                system::format_size(system::MINIMUM_DISK_BYTES)
            )),
        ];
        frame.render_widget(Paragraph::new(text).wrap(Wrap { trim: false }), area);
        return;
    }
    let items = app
        .disks
        .iter()
        .map(|disk| {
            entry(
                format!("{:<14}{:>10}", disk.path, system::format_size(disk.size)),
                format!("  {}", disk.model),
                24,
            )
        })
        .collect();
    choice_list(frame, area, items, &mut app.disk_list);
}

struct Segment {
    label: String,
    /// What the bar itself shows: a role, a partition name, or "free".
    short: String,
    detail: String,
    size: u64,
    color: Color,
    free: bool,
}

/// Splits `width` cells between segments by size. Every non-empty segment gets
/// at least one cell, so a small boot partition never disappears.
fn segment_cells(sizes: &[u64], width: usize) -> Vec<usize> {
    let total: u128 = sizes.iter().map(|size| *size as u128).sum();
    if total == 0 || width == 0 {
        return vec![0; sizes.len()];
    }
    let mut cells: Vec<usize> = sizes
        .iter()
        .map(|size| {
            let share = (*size as u128 * width as u128 / total) as usize;
            if *size > 0 { share.max(1) } else { 0 }
        })
        .collect();
    let largest = |cells: &[usize]| {
        (0..cells.len()).max_by_key(|index| (sizes[*index], cells[*index])).unwrap_or(0)
    };
    while cells.iter().sum::<usize>() < width {
        let index = largest(&cells);
        cells[index] += 1;
    }
    while cells.iter().sum::<usize>() > width {
        let Some(index) = (0..cells.len()).filter(|index| cells[*index] > 1).max_by_key(|index| cells[*index]) else {
            break;
        };
        cells[index] -= 1;
    }
    cells
}

fn percent(size: u64, total: u64) -> String {
    if total == 0 {
        return "0%".into();
    }
    let permille = (size as u128 * 1000 / total as u128) as u64;
    if permille == 0 && size > 0 {
        "<0.1%".into()
    } else {
        format!("{}.{}%", permille / 10, permille % 10)
    }
}

/// Partitions without a role cycle through these; red is kept for errors.
const OTHER_COLORS: [Color; 6] = [
    Color::Magenta,
    Color::Yellow,
    Color::Cyan,
    Color::LightMagenta,
    Color::LightYellow,
    Color::LightCyan,
];
const BAR_HEIGHT: u16 = 3;

/// The label written inside a segment, or nothing when it does not fit.
fn bar_label(segment: &Segment, total: u64, cells: usize) -> String {
    let room = cells.saturating_sub(2);
    let full = format!("{} {}", segment.short, percent(segment.size, total));
    [full, segment.short.clone()]
        .into_iter()
        .find(|text| text.chars().count() <= room)
        .unwrap_or_default()
}

/// One bar for the whole disk, every segment labelled inside when it fits.
fn bar_lines(segments: &[Segment], width: u16) -> Vec<Line<'static>> {
    let total: u64 = segments.iter().map(|segment| segment.size).sum();
    let sizes: Vec<u64> = segments.iter().map(|segment| segment.size).collect();
    let cells = segment_cells(&sizes, width as usize);
    (0..BAR_HEIGHT)
        .map(|row| {
            let spans = segments
                .iter()
                .zip(&cells)
                .map(|(segment, cells)| {
                    let label = if row == BAR_HEIGHT / 2 {
                        bar_label(segment, total, *cells)
                    } else {
                        String::new()
                    };
                    let length = label.chars().count();
                    let left = (cells - length) / 2;
                    let right = cells - length - left;
                    if segment.free {
                        let text = format!("{}{label}{}", "░".repeat(left), "░".repeat(right));
                        Span::styled(text, Style::new().fg(MUTED))
                    } else {
                        let text = format!("{}{label}{}", " ".repeat(left), " ".repeat(right));
                        Span::styled(text, Style::new().fg(Color::Black).bg(segment.color).bold())
                    }
                })
                .collect::<Vec<_>>();
            Line::from(spans)
        })
        .collect()
}

fn legend_lines(segments: &[Segment]) -> Vec<Line<'static>> {
    let total: u64 = segments.iter().map(|segment| segment.size).sum();
    segments
        .iter()
        .map(|segment| {
            let glyph = if segment.free { "░░" } else { "██" };
            Line::from(vec![
                Span::styled(glyph, Style::new().fg(segment.color)),
                Span::styled(format!(" {:<16}", segment.label), Style::new().fg(LIGHT)),
                Span::raw(format!("{:>10}", system::format_size(segment.size))),
                Span::styled(
                    format!("{:>8}  ", percent(segment.size, total)),
                    Style::new().fg(LIGHT).bold(),
                ),
                Span::styled(segment.detail.clone(), Style::new().fg(MUTED)),
            ])
        })
        .collect()
}

fn disk_map(frame: &mut Frame, area: Rect, segments: &[Segment], legend: bool) {
    let mut lines = bar_lines(segments, area.width);
    if legend {
        lines.push(Line::default());
        lines.extend(legend_lines(segments));
    }
    frame.render_widget(Paragraph::new(lines), area);
}

/// The disk after an automatic install.
fn automatic_segments(disk_size: u64) -> Vec<Segment> {
    vec![
        Segment {
            label: "boot".into(),
            short: "boot".into(),
            detail: "FAT32, kernels and the boot loader".into(),
            size: BOOT_SIZE.min(disk_size),
            color: Color::Blue,
            free: false,
        },
        Segment {
            label: "root".into(),
            short: "root".into(),
            detail: "the system, your files and the Nix store".into(),
            size: disk_size.saturating_sub(BOOT_SIZE),
            color: ACCENT,
            free: false,
        },
    ]
}

fn role(app: &App, partition: &Partition) -> Option<(&'static str, Color)> {
    if app.boot_partition.as_deref() == Some(partition.path.as_str()) {
        Some(("boot", Color::Blue))
    } else if app.root_partition.as_deref() == Some(partition.path.as_str()) {
        Some(("root", ACCENT))
    } else {
        None
    }
}

fn describe(partition: &Partition) -> String {
    let fstype = partition.fstype.as_deref().unwrap_or("empty");
    match &partition.kind {
        Some(kind) => format!("{fstype}, {kind}"),
        None => fstype.to_string(),
    }
}

/// Pads or cuts `text` to exactly `width` characters.
fn fit(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        return format!("{text:<width$}");
    }
    let cut: String = text.chars().take(width.saturating_sub(4)).collect();
    format!("{cut}... ")
}

/// The disk as it is now, colored by the roles chosen so far.
fn manual_segments(app: &App, disk_size: u64) -> Vec<Segment> {
    let mut others = OTHER_COLORS.iter().cycle();
    let mut segments: Vec<Segment> = app
        .partitions
        .iter()
        .map(|partition| {
            let name = partition.path.rsplit('/').next().unwrap_or(&partition.path);
            let (label, short, color) = match role(app, partition) {
                Some((role, color)) => (format!("{name} {role}"), role.to_string(), color),
                None => (name.to_string(), name.to_string(), *others.next().unwrap_or(&Color::Magenta)),
            };
            Segment {
                label,
                short,
                detail: describe(partition),
                size: partition.size,
                color,
                free: false,
            }
        })
        .collect();
    let used: u64 = app.partitions.iter().map(|partition| partition.size).sum();
    let free = disk_size.saturating_sub(used);
    // GPT and alignment always leave a few MiB, which is not worth showing.
    if free > 16 * 1024 * 1024 {
        segments.push(Segment {
            label: "unallocated".into(),
            short: "free".into(),
            detail: "create partitions here with cfdisk".into(),
            size: free,
            color: MUTED,
            free: true,
        });
    }
    segments
}

fn draw_partitioning(frame: &mut Frame, app: &mut App, area: Rect) {
    let [list, _, map] = Layout::vertical([
        Constraint::Length(2),
        Constraint::Length(1),
        Constraint::Min(0),
    ])
    .areas(area);
    let items = vec![
        entry("Automatic", "erase the whole disk and partition it for you", 12),
        entry("Manual", "use existing partitions, or make them in cfdisk", 12),
    ];
    choice_list(frame, list, items, &mut app.partitioning_list);
    let disk_size = app.disk().map_or(0, |disk| disk.size);
    let segments = if app.manual() {
        manual_segments(app, disk_size)
    } else {
        automatic_segments(disk_size)
    };
    disk_map(frame, map, &segments, true);
}

fn draw_partitions(frame: &mut Frame, app: &mut App, area: Rect) {
    let disk_size = app.disk().map_or(0, |disk| disk.size);
    let segments = manual_segments(app, disk_size);
    let [map, _, list, status] = Layout::vertical([
        Constraint::Length(BAR_HEIGHT),
        Constraint::Length(1),
        Constraint::Min(0),
        Constraint::Length(2),
    ])
    .areas(area);
    // Only the bar here: the list below already names every partition.
    disk_map(frame, map, &segments, false);

    if app.partitions.is_empty() {
        frame.render_widget(
            muted("This disk has no partitions yet. Press e to create them in cfdisk."),
            list,
        );
    } else {
        let items = app
            .partitions
            .iter()
            .map(|partition| {
                let tag = match role(app, partition) {
                    Some(("boot", color)) => {
                        let action = if app.format_boot { "format" } else { "keep" };
                        Span::styled(format!("boot, {action}"), Style::new().fg(color).bold())
                    }
                    Some((_, color)) => Span::styled("root, format", Style::new().fg(color).bold()),
                    None if partition.mounted => Span::styled("mounted", Style::new().fg(WARN)),
                    None => Span::raw(""),
                };
                ListItem::new(Line::from(vec![
                    Span::raw(format!(
                        "{:<16}{:>10}  ",
                        partition.path,
                        system::format_size(partition.size)
                    )),
                    Span::styled(fit(&describe(partition), 28), Style::new().fg(MUTED)),
                    tag,
                ]))
            })
            .collect();
        choice_list(frame, list, items, &mut app.partition_list);
    }

    let existing = app
        .partition(app.root_partition.as_deref())
        .and_then(|root| Some((root.path.clone(), root.fstype.clone()?)));
    let line = match (&app.partition_error, existing) {
        (Some(error), _) => Line::styled(error.clone(), Style::new().fg(ERROR)),
        (None, Some((path, fstype))) => Line::styled(
            format!("{path} holds {fstype} data. It will be erased."),
            Style::new().fg(WARN).bold(),
        ),
        (None, None) => muted("Only the boot and root partitions are touched."),
    };
    frame.render_widget(Paragraph::new(line).wrap(Wrap { trim: false }), status);
}

fn draw_bootloader(frame: &mut Frame, app: &mut App, area: Rect) {
    let items = BootLoader::ALL
        .iter()
        .map(|loader| entry(loader.name(), loader.description(), 10))
        .collect();
    choice_list(frame, area, items, &mut app.bootloader_list);
}

fn draw_filesystem(frame: &mut Frame, app: &mut App, area: Rect) {
    let items = Filesystem::ALL
        .iter()
        .map(|filesystem| entry(filesystem.name(), filesystem.description(), 10))
        .collect();
    choice_list(frame, area, items, &mut app.filesystem_list);
}

fn draw_desktop(frame: &mut Frame, app: &mut App, area: Rect) {
    let items = Desktop::ALL
        .iter()
        .map(|desktop| ListItem::new(desktop.name()))
        .collect();
    choice_list(frame, area, items, &mut app.desktop_list);
}

fn draw_connection(frame: &mut Frame, app: &mut App, area: Rect) {
    let items = Network::ALL
        .iter()
        .map(|network| ListItem::new(network.name()))
        .collect();
    choice_list(frame, area, items, &mut app.connection_list);
}

fn field<'a>(label: &'a str, input: &Input, focused: bool) -> Line<'a> {
    let (marker, label_style) = if focused {
        ("▌ ", Style::new().fg(ACCENT).bold())
    } else {
        ("  ", Style::new().fg(MUTED))
    };
    let mut spans = vec![
        Span::styled(marker, Style::new().fg(ACCENT)),
        Span::styled(format!("{label:<18}"), label_style),
        Span::styled(input.display(), Style::new().fg(LIGHT)),
    ];
    if focused {
        spans.push(Span::styled("_", Style::new().fg(ACCENT).add_modifier(Modifier::SLOW_BLINK)));
    }
    Line::from(spans)
}

fn draw_account(frame: &mut Frame, app: &App, area: Rect) {
    let mut lines = vec![
        field("Host name", &app.host, app.focus == 0),
        Line::default(),
        field("User name", &app.user, app.focus == 1),
        Line::default(),
        field("Password", &app.password, app.focus == 2),
        Line::default(),
        field("Confirm password", &app.confirm, app.focus == 3),
        Line::default(),
    ];
    if let Some(error) = &app.form_error {
        lines.push(Line::styled(error.as_str(), Style::new().fg(ERROR)));
    }
    frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: false }), area);
}

fn draw_timezone(frame: &mut Frame, app: &mut App, area: Rect) {
    let [search, _, list] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(0),
    ])
    .areas(area);
    frame.render_widget(field("Search", &app.zone_filter, true), search);
    let items: Vec<ListItem> = app
        .visible_zones()
        .into_iter()
        .map(|zone| ListItem::new(zone.to_string()))
        .collect();
    if items.is_empty() {
        frame.render_widget(muted("No time zone matches."), list);
        return;
    }
    choice_list(frame, list, items, &mut app.zone_list);
}

fn draw_review(frame: &mut Frame, app: &App, area: Rect) {
    let mut lines: Vec<Line> = app
        .summary()
        .into_iter()
        .map(|(label, value)| {
            Line::from(vec![
                Span::styled(format!("  {label:<14}"), Style::new().fg(MUTED)),
                Span::styled(value, Style::new().fg(LIGHT)),
            ])
        })
        .collect();
    lines.extend([
        Line::default(),
        Line::styled(
            match app.layout() {
                DiskLayout::Automatic => "  All data on this disk will be destroyed.".to_string(),
                DiskLayout::Manual { root, format_boot, boot } => {
                    if format_boot {
                        format!("  All data on {boot} and {root} will be destroyed.")
                    } else {
                        format!("  All data on {root} will be destroyed.")
                    }
                }
            },
            Style::new().fg(ERROR).bold(),
        ),
        Line::default(),
        field("Type ERASE", &app.confirmation, true),
    ]);
    if app.confirmation.value == CONFIRMATION {
        lines.push(Line::default());
        lines.push(Line::styled(
            "  Press Enter to install.",
            Style::new().fg(ACCENT).bold(),
        ));
    }
    frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: false }), area);
}

fn format_elapsed(app: &App) -> String {
    let elapsed = app
        .finished
        .or_else(|| app.started.map(|started| started.elapsed()))
        .unwrap_or_default()
        .as_secs();
    format!("{:02}:{:02}", elapsed / 60, elapsed % 60)
}

fn phase_lines(app: &App) -> Vec<Line<'static>> {
    PHASES
        .iter()
        .enumerate()
        .map(|(index, name)| {
            if index < app.phase || app.phase_done {
                Line::styled(format!("■ {name}"), Style::new().fg(ACCENT))
            } else if index == app.phase && app.error.is_some() {
                Line::styled(format!("x {name}"), Style::new().fg(ERROR).bold())
            } else if index == app.phase {
                Line::styled(format!("{} {name}", spinner(app)), Style::new().fg(LIGHT).bold())
            } else {
                Line::styled(format!("· {name}"), Style::new().fg(MUTED))
            }
        })
        .collect()
}

fn bar(app: &App, width: u16) -> Line<'static> {
    let done = if app.phase_done { PHASES.len() } else { app.phase };
    let label = format!(" {:>3}%  {}", done * 100 / PHASES.len(), format_elapsed(app));
    let cells = (width as usize).saturating_sub(label.len());
    let filled = cells * done / PHASES.len();
    Line::from(vec![
        Span::styled("█".repeat(filled), Style::new().fg(ACCENT)),
        Span::styled("░".repeat(cells - filled), Style::new().fg(MUTED)),
        Span::styled(label, Style::new().fg(LIGHT)),
    ])
}

fn draw_log(frame: &mut Frame, app: &App, area: Rect) {
    let height = area.height as usize;
    let end = app.log.len().saturating_sub(app.scroll);
    let start = end.saturating_sub(height);
    let lines: Vec<Line> = app.log[start..end]
        .iter()
        .map(|line| Line::styled(line.clone(), Style::new().fg(MUTED)))
        .collect();
    frame.render_widget(Paragraph::new(lines), area);
}

fn draw_installing(frame: &mut Frame, app: &App, area: Rect) {
    let [phases, _, progress_bar, _, log] = Layout::vertical([
        Constraint::Length(PHASES.len() as u16),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(0),
    ])
    .areas(area);
    frame.render_widget(Paragraph::new(phase_lines(app)), phases);
    frame.render_widget(bar(app, progress_bar.width), progress_bar);
    draw_log(frame, app, log);
}

fn draw_failed(frame: &mut Frame, app: &App, area: Rect) {
    let [message, _, phases, _, log] = Layout::vertical([
        Constraint::Length(2),
        Constraint::Length(1),
        Constraint::Length(PHASES.len() as u16),
        Constraint::Length(1),
        Constraint::Min(0),
    ])
    .areas(area);
    let lines = vec![
        Line::styled(
            app.error.clone().unwrap_or_else(|| "The installation failed.".into()),
            Style::new().fg(ERROR).bold(),
        ),
        muted(format!("Full log: {LOG_PATH}")),
    ];
    frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: false }), message);
    frame.render_widget(Paragraph::new(phase_lines(app)), phases);
    draw_log(frame, app, log);
}

fn draw_done(frame: &mut Frame, app: &mut App, area: Rect) {
    let [message, _, list] = Layout::vertical([
        Constraint::Length(2),
        Constraint::Length(1),
        Constraint::Min(0),
    ])
    .areas(area);
    let lines = vec![
        Line::styled("Runix is installed.", Style::new().fg(ACCENT).bold()),
        muted(format!("Finished in {}.", format_elapsed(app))),
    ];
    frame.render_widget(Paragraph::new(lines), message);
    let items = DONE_ACTIONS.iter().map(|action| ListItem::new(*action)).collect();
    choice_list(frame, list, items, &mut app.done_list);
}

fn draw_modal(frame: &mut Frame, app: &App) {
    let Some(modal) = &app.modal else {
        return;
    };
    let (title, lines) = match modal {
        Modal::Quit => (
            "Exit installer",
            vec![
                Line::from("Exit to a shell?"),
                muted("Run runix-installer to start again."),
            ],
        ),
        Modal::WifiName(input) => ("Other network", vec![field("Network name", input, true)]),
        Modal::WifiPassword { ssid, input } => (
            "Join Wi-Fi",
            vec![
                Line::from(format!("Password for {ssid}")),
                muted("Leave it empty for an open network."),
                Line::default(),
                field("Password", input, true),
            ],
        ),
        Modal::Notice(text) => ("Notice", vec![Line::raw(text.clone())]),
    };
    let screen = frame.area();
    let width = 60.min(screen.width);
    let height = (lines.len() as u16 + 4).min(screen.height);
    let area = Rect {
        x: screen.x + (screen.width - width) / 2,
        y: screen.y + (screen.height - height) / 2,
        width,
        height,
    };
    let block = Block::bordered()
        .title(Span::styled(format!(" {title} "), Style::new().fg(LIGHT).bold()))
        .border_style(Style::new().fg(ACCENT))
        .padding(ratatui::widgets::Padding::horizontal(1));
    frame.render_widget(Clear, area);
    frame.render_widget(
        Paragraph::new(lines).block(block).wrap(Wrap { trim: false }),
        area,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::tests::{demo_app, fill_account};
    use crate::app::Message;
    use crate::install::Update;
    use crate::system::WifiNetwork;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    fn render(app: &mut App, width: u16, height: u16) -> String {
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        terminal.draw(|frame| draw(frame, app)).unwrap();
        let buffer = terminal.backend().buffer().clone();
        buffer
            .content()
            .chunks(width as usize)
            .map(|row| row.iter().map(|cell| cell.symbol()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn every_screen_draws_at_console_and_tiny_sizes() {
        for (width, height) in [(80, 25), (93, 34), (160, 50), (40, 10), (10, 3), (1, 1)] {
            let (mut app, _receiver) = demo_app();
            app.networks = vec![WifiNetwork {
                ssid: "Home".into(),
                secured: true,
            }];
            for screen in [
                Screen::Welcome,
                Screen::Network,
                Screen::Disk,
                Screen::Bootloader,
                Screen::Partitioning,
                Screen::Partitions,
                Screen::Filesystem,
                Screen::Account,
                Screen::Timezone,
                Screen::Desktop,
                Screen::Connection,
                Screen::Review,
                Screen::Installing,
                Screen::Failed,
                Screen::Done,
            ] {
                app.screen = screen;
                render(&mut app, width, height);
            }
        }
    }

    #[test]
    fn the_mark_lines_up() {
        for (row, segments) in MARK.iter().enumerate() {
            let width: usize = segments.iter().map(|(_, text)| text.chars().count()).sum();
            assert!(width <= MARK_WIDTH, "mark row {row} is {width} wide");
        }
        let width = WORDMARK[0].chars().count();
        assert!(WORDMARK.iter().all(|row| row.chars().count() == width));
        assert_eq!(MARK_WIDTH + 3 + width, LOGO_WIDTH as usize);
    }

    #[test]
    fn the_logo_needs_room() {
        let (mut app, _receiver) = demo_app();
        app.screen = Screen::Disk;
        assert!(render(&mut app, 93, 34).contains("████▄"));
        let small = render(&mut app, 80, 25);
        assert!(!small.contains("████▄"));
        assert!(small.contains("runix"));
    }

    #[test]
    fn the_disk_map_fills_its_width_and_keeps_small_partitions() {
        const GIB: u64 = 1024 * 1024 * 1024;
        let cells = segment_cells(&[GIB, 1023 * GIB], 60);
        assert_eq!(cells.iter().sum::<usize>(), 60);
        assert_eq!(cells[0], 1);
        let cells = segment_cells(&[GIB, GIB, GIB, 2 * GIB], 10);
        assert_eq!(cells.iter().sum::<usize>(), 10);
        assert!(cells.iter().all(|cell| *cell >= 1));
        assert_eq!(segment_cells(&[GIB, GIB], 0), [0, 0]);
        assert_eq!(segment_cells(&[], 10), Vec::<usize>::new());
    }

    #[test]
    fn every_partition_gets_its_own_color() {
        let (mut app, _receiver) = demo_app();
        app.disks = crate::system::disks(true);
        app.partitioning_list.select(Some(1));
        app.refresh_partitions();
        app.boot_partition = None;
        let segments = manual_segments(&app, app.disk().unwrap().size);
        let mut colors: Vec<String> = segments
            .iter()
            .filter(|segment| !segment.free)
            .map(|segment| format!("{:?}", segment.color))
            .collect();
        let count = colors.len();
        colors.sort();
        colors.dedup();
        assert_eq!(colors.len(), count);
        assert!(segments.iter().all(|segment| segment.color != ERROR));
    }

    #[test]
    fn the_bar_labels_segments_that_fit() {
        let segments = automatic_segments(512 * 1024 * 1024 * 1024);
        let lines = bar_lines(&segments, 60);
        assert_eq!(lines.len(), BAR_HEIGHT as usize);
        let middle: String = lines[1].spans.iter().map(|span| span.content.as_ref()).collect();
        assert_eq!(middle.chars().count(), 60);
        assert!(middle.contains("root 99.8%"));
        // One cell is too narrow for the boot label.
        assert!(!middle.contains("boot"));
    }

    #[test]
    fn long_text_is_cut_to_its_column() {
        assert_eq!(fit("ntfs", 8), "ntfs    ");
        let cut = fit("ntfs, Microsoft basic data", 12);
        assert_eq!(cut.chars().count(), 12);
        assert!(cut.ends_with("... "));
    }

    #[test]
    fn existing_data_on_root_is_called_out() {
        let (mut app, _receiver) = demo_app();
        app.disks = crate::system::disks(true);
        app.partitioning_list.select(Some(1));
        app.refresh_partitions();
        app.root_partition = Some("/dev/nvme0n1p2".into());
        app.screen = Screen::Partitions;
        let screen = render(&mut app, 93, 34);
        assert!(screen.contains("holds ntfs data"));
    }

    #[test]
    fn percentages_never_round_to_zero() {
        assert_eq!(percent(1, 1_000_000), "<0.1%");
        assert_eq!(percent(1, 4), "25.0%");
        assert_eq!(percent(0, 0), "0%");
    }

    #[test]
    fn partitioning_shows_the_planned_split() {
        let (mut app, _receiver) = demo_app();
        app.screen = Screen::Disk;
        app.disks = crate::system::disks(true);
        app.screen = Screen::Partitioning;
        let screen = render(&mut app, 93, 34);
        assert!(screen.contains("boot"));
        assert!(screen.contains("0.1%"));
        assert!(screen.contains("99.8%"));
    }

    #[test]
    fn passwords_are_never_drawn() {
        let (mut app, _receiver) = demo_app();
        fill_account(&mut app);
        let screen = render(&mut app, 80, 25);
        assert!(screen.contains("alice"));
        assert!(!screen.contains("secret"));
        assert!(screen.contains("******"));
    }

    #[test]
    fn demo_mode_is_always_labelled() {
        let (mut app, _receiver) = demo_app();
        assert!(render(&mut app, 80, 25).contains("DEMO"));
    }

    #[test]
    fn the_latest_log_lines_are_shown() {
        let (mut app, _receiver) = demo_app();
        app.screen = Screen::Installing;
        for index in 0..500 {
            app.on_message(Message::Install(Update::Line(format!("line {index}"))));
        }
        let screen = render(&mut app, 80, 25);
        assert!(screen.contains("line 499"));
        assert!(!screen.contains("line 0 "));
    }
}
