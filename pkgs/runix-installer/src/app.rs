//! Installer state and key handling. Drawing lives in `ui`.

use std::fs::{File, OpenOptions};
use std::sync::mpsc::Sender;
use std::thread;
use std::time::{Duration, Instant};

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::widgets::ListState;

use crate::config::{self, BootLoader, BootMode, Desktop, Filesystem, Network};
use crate::install::{self, DiskLayout, Plan, Update};
use crate::system::{self, Disk, Partition, WifiNetwork};

const LOCK_PATH: &str = "/run/runix-installer.lock";
const RECHECK_INTERVAL: Duration = Duration::from_secs(5);
const MAX_LOG_LINES: usize = 5000;
pub const CONFIRMATION: &str = "ERASE";

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Screen {
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
}

impl Screen {
    pub const WIZARD: [Self; 12] = [
        Self::Welcome,
        Self::Network,
        Self::Disk,
        Self::Bootloader,
        Self::Partitioning,
        Self::Partitions,
        Self::Filesystem,
        Self::Account,
        Self::Timezone,
        Self::Desktop,
        Self::Connection,
        Self::Review,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Self::Welcome => "Welcome",
            Self::Network => "Network",
            Self::Disk => "Disk",
            Self::Bootloader => "Boot loader",
            Self::Partitioning => "Partitioning",
            Self::Partitions => "Partitions",
            Self::Filesystem => "Filesystem",
            Self::Account => "Account",
            Self::Timezone => "Time zone",
            Self::Desktop => "Desktop",
            Self::Connection => "Connection",
            Self::Review => "Review",
            Self::Installing => "Install",
            Self::Failed => "Install failed",
            Self::Done => "Done",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Exit {
    Shell,
    Reboot,
    Poweroff,
}

#[derive(Debug)]
pub enum Message {
    Online(bool),
    Scanned(Vec<WifiNetwork>),
    Connected(Result<(), String>),
    Install(Update),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OnlineState {
    Checking,
    Online,
    Offline,
}

#[derive(Default)]
pub struct Input {
    pub value: String,
    pub masked: bool,
}

impl Input {
    fn masked() -> Self {
        Self {
            value: String::new(),
            masked: true,
        }
    }

    fn with_value(value: &str) -> Self {
        Self {
            value: value.to_string(),
            masked: false,
        }
    }

    pub fn display(&self) -> String {
        if self.masked {
            "*".repeat(self.value.chars().count())
        } else {
            self.value.clone()
        }
    }

    /// Returns whether the value changed.
    fn handle(&mut self, key: KeyEvent) -> bool {
        match key.code {
            KeyCode::Backspace => self.value.pop().is_some(),
            KeyCode::Char(c)
                if !key.modifiers.contains(KeyModifiers::CONTROL) && self.value.len() < 128 =>
            {
                self.value.push(c);
                true
            }
            _ => false,
        }
    }
}

pub fn move_selection(state: &mut ListState, length: usize, forward: bool) {
    if length == 0 {
        state.select(None);
        return;
    }
    let current = state.selected().unwrap_or(0).min(length - 1);
    let next = if forward {
        (current + 1).min(length - 1)
    } else {
        current.saturating_sub(1)
    };
    state.select(Some(next));
}

fn selected() -> ListState {
    ListState::default().with_selected(Some(0))
}

/// Work that needs the real terminal, so the main loop suspends the UI for it.
pub enum External {
    EditPartitions(String),
    /// A shell inside the installed system, mounted at this path.
    Chroot(String),
}

/// Partitions smaller than this cannot hold a boot partition.
pub const MINIMUM_BOOT_BYTES: u64 = 256 * 1024 * 1024;
/// Partitions smaller than this cannot hold a root filesystem.
pub const MINIMUM_ROOT_BYTES: u64 = 12 * 1024 * 1024 * 1024;

pub enum Modal {
    Quit,
    WifiName(Input),
    WifiPassword { ssid: String, input: Input },
    Notice(String),
}

pub struct Options {
    pub demo: bool,
    pub demo_fail: bool,
    pub flake: String,
    pub zoneinfo: String,
}

pub struct App {
    pub options: Options,
    sender: Sender<Message>,
    pub screen: Screen,
    pub modal: Option<Modal>,
    pub exit: Option<Exit>,

    pub online: OnlineState,
    checking: bool,
    last_check: Option<Instant>,
    pub wireless: bool,
    pub networks: Vec<WifiNetwork>,
    pub network_list: ListState,
    pub scanning: bool,
    pub connecting: Option<String>,

    pub disks: Vec<Disk>,
    pub disk_list: ListState,
    pub bootloader_list: ListState,
    pub partitioning_list: ListState,
    pub partitions: Vec<Partition>,
    partitions_disk: String,
    pub partition_list: ListState,
    pub boot_partition: Option<String>,
    pub root_partition: Option<String>,
    pub format_boot: bool,
    pub partition_error: Option<String>,
    pub external: Option<External>,
    pub filesystem_list: ListState,

    pub host: Input,
    pub user: Input,
    pub password: Input,
    pub confirm: Input,
    pub focus: usize,
    pub form_error: Option<String>,

    pub zones: Vec<String>,
    pub zone_filter: Input,
    pub zone_list: ListState,

    pub desktop_list: ListState,
    pub connection_list: ListState,
    pub confirmation: Input,
    pub boot_mode: BootMode,

    pub phase: usize,
    pub phase_done: bool,
    pub log: Vec<String>,
    pub scroll: usize,
    pub error: Option<String>,
    pub started: Option<Instant>,
    pub finished: Option<Duration>,
    pub done_list: ListState,
    lock: Option<File>,
    pub frame: usize,
}

impl App {
    pub fn new(options: Options, sender: Sender<Message>) -> Self {
        let zones = system::timezones(&options.zoneinfo);
        let wireless = system::wireless_available(options.demo);
        Self {
            sender,
            screen: Screen::Welcome,
            modal: None,
            exit: None,
            online: OnlineState::Checking,
            checking: false,
            last_check: None,
            wireless,
            networks: Vec::new(),
            network_list: selected(),
            scanning: false,
            connecting: None,
            disks: Vec::new(),
            disk_list: selected(),
            bootloader_list: selected(),
            partitioning_list: selected(),
            partitions: Vec::new(),
            partitions_disk: String::new(),
            partition_list: selected(),
            boot_partition: None,
            root_partition: None,
            format_boot: true,
            partition_error: None,
            external: None,
            filesystem_list: selected(),
            host: Input::with_value("runix"),
            user: Input::default(),
            password: Input::masked(),
            confirm: Input::masked(),
            focus: 0,
            form_error: None,
            zones,
            zone_filter: Input::default(),
            zone_list: selected(),
            desktop_list: selected(),
            connection_list: selected(),
            confirmation: Input::default(),
            boot_mode: if options.demo {
                BootMode::Efi
            } else {
                system::boot_mode()
            },
            phase: 0,
            phase_done: false,
            log: Vec::new(),
            scroll: 0,
            error: None,
            started: None,
            finished: None,
            done_list: selected(),
            lock: None,
            frame: 0,
            options,
        }
    }

    pub fn visible_zones(&self) -> Vec<&str> {
        let filter = self.zone_filter.value.to_lowercase();
        self.zones
            .iter()
            .filter(|zone| zone.to_lowercase().contains(&filter))
            .map(String::as_str)
            .collect()
    }

    fn selected_zone(&self) -> Option<String> {
        let zones = self.visible_zones();
        let index = self.zone_list.selected()?;
        zones.get(index).map(|zone| (*zone).to_string())
    }

    pub fn timezone(&self) -> String {
        self.selected_zone().unwrap_or_else(|| "UTC".to_string())
    }

    pub fn disk(&self) -> Option<&Disk> {
        self.disks.get(self.disk_list.selected()?)
    }

    pub fn filesystem(&self) -> Filesystem {
        Filesystem::ALL[self.filesystem_list.selected().unwrap_or(0)]
    }

    pub fn desktop(&self) -> Desktop {
        Desktop::ALL[self.desktop_list.selected().unwrap_or(0)]
    }

    pub fn loader(&self) -> BootLoader {
        BootLoader::ALL[self.bootloader_list.selected().unwrap_or(0)]
    }

    pub fn connection(&self) -> Network {
        if self.wireless {
            Network::ALL[self.connection_list.selected().unwrap_or(0)]
        } else {
            Network::Dhcpcd
        }
    }

    pub fn summary(&self) -> Vec<(&'static str, String)> {
        let disk = self.disk().map_or_else(
            || "none".to_string(),
            |disk| {
                format!(
                    "{}  {}  {}",
                    disk.path,
                    system::format_size(disk.size),
                    disk.model
                )
            },
        );
        vec![
            ("Disk", disk),
            ("Layout", self.layout_summary()),
            ("Boot loader", self.loader().name().to_string()),
            ("Filesystem", self.filesystem().name().to_string()),
            ("Boot mode", self.boot_mode.name().to_string()),
            ("Host name", self.host.value.clone()),
            ("User", self.user.value.clone()),
            ("Time zone", self.timezone()),
            ("Desktop", self.desktop().name().to_string()),
            ("Connection", self.connection().name().to_string()),
        ]
    }

    fn check_online(&mut self) {
        if self.checking {
            return;
        }
        self.checking = true;
        self.last_check = Some(Instant::now());
        let sender = self.sender.clone();
        let demo = self.options.demo;
        thread::spawn(move || {
            let _ = sender.send(Message::Online(system::online(demo)));
        });
    }

    fn scan(&mut self) {
        if self.scanning || !self.wireless {
            return;
        }
        self.scanning = true;
        let sender = self.sender.clone();
        let demo = self.options.demo;
        thread::spawn(move || {
            let _ = sender.send(Message::Scanned(system::scan(demo)));
        });
    }

    fn connect(&mut self, ssid: String, password: Option<String>) {
        self.connecting = Some(ssid.clone());
        let sender = self.sender.clone();
        let demo = self.options.demo;
        thread::spawn(move || {
            let result = system::connect(demo, &ssid, password.as_deref());
            let _ = sender.send(Message::Connected(result));
        });
    }

    fn enter(&mut self, screen: Screen) {
        self.screen = screen;
        match screen {
            Screen::Network => {
                self.check_online();
                self.scan();
            }
            Screen::Disk => {
                self.disks = system::disks(self.options.demo);
                self.disk_list.select((!self.disks.is_empty()).then_some(0));
            }
            Screen::Partitioning | Screen::Partitions => self.refresh_partitions(),
            Screen::Review => self.confirmation.value.clear(),
            _ => {}
        }
    }

    pub fn applicable(&self, screen: Screen) -> bool {
        match screen {
            Screen::Connection => self.wireless,
            Screen::Partitions => self.manual(),
            _ => true,
        }
    }

    pub fn manual(&self) -> bool {
        self.partitioning_list.selected() == Some(1)
    }

    pub fn partition(&self, path: Option<&str>) -> Option<&Partition> {
        let path = path?;
        self.partitions.iter().find(|partition| partition.path == path)
    }

    pub fn layout(&self) -> DiskLayout {
        match (&self.boot_partition, &self.root_partition) {
            (Some(boot), Some(root)) if self.manual() => DiskLayout::Manual {
                boot: boot.clone(),
                root: root.clone(),
                format_boot: self.format_boot,
            },
            _ => DiskLayout::Automatic,
        }
    }

    fn layout_summary(&self) -> String {
        match self.layout() {
            DiskLayout::Automatic => "Automatic: erase the disk, 1 GiB boot, root on the rest".into(),
            DiskLayout::Manual {
                boot,
                root,
                format_boot,
            } => {
                let boot_action = if format_boot { "format" } else { "keep" };
                format!("Manual: boot {boot} ({boot_action}), root {root} (format)")
            }
        }
    }

    /// Reloads the selected disk's partitions, keeping choices that still exist.
    pub fn refresh_partitions(&mut self) {
        let Some(disk) = self.disk().map(|disk| disk.path.clone()) else {
            self.partitions.clear();
            return;
        };
        self.partitions = system::partitions(self.options.demo, &disk);
        if self.partitions_disk != disk {
            self.partitions_disk = disk;
            self.boot_partition = None;
            self.root_partition = None;
        }
        let exists = |choice: &Option<String>, partitions: &[Partition]| {
            choice
                .as_ref()
                .is_some_and(|path| partitions.iter().any(|partition| &partition.path == path))
        };
        if !exists(&self.boot_partition, &self.partitions) {
            self.boot_partition = None;
        }
        if !exists(&self.root_partition, &self.partitions) {
            self.root_partition = None;
        }
        // An existing ESP is the usual dual-boot choice, and keeping it is safe.
        if self.boot_partition.is_none() {
            if let Some(esp) = system::existing_esp(&self.partitions) {
                self.boot_partition = Some(esp.path.clone());
                self.format_boot = false;
            }
        }
        let length = self.partitions.len();
        let index = self.partition_list.selected().unwrap_or(0);
        self.partition_list
            .select((length > 0).then(|| index.min(length - 1)));
        self.partition_error = None;
    }

    fn selected_partition(&self) -> Option<Partition> {
        self.partition_list
            .selected()
            .and_then(|index| self.partitions.get(index))
            .cloned()
    }

    fn assign_boot(&mut self) {
        let Some(partition) = self.selected_partition() else {
            return;
        };
        if self.root_partition.as_deref() == Some(partition.path.as_str()) {
            self.root_partition = None;
        }
        // Only an existing FAT filesystem can be kept as it is.
        self.format_boot = !partition.is_vfat();
        self.boot_partition = Some(partition.path);
        self.partition_error = None;
    }

    fn assign_root(&mut self) {
        let Some(partition) = self.selected_partition() else {
            return;
        };
        if self.boot_partition.as_deref() == Some(partition.path.as_str()) {
            self.boot_partition = None;
        }
        self.root_partition = Some(partition.path);
        self.partition_error = None;
    }

    fn toggle_format_boot(&mut self) {
        let keepable = self
            .partition(self.boot_partition.as_deref())
            .is_some_and(Partition::is_vfat);
        if keepable {
            self.format_boot = !self.format_boot;
        }
    }

    pub fn check_manual(&self) -> Result<(), String> {
        let boot = self
            .partition(self.boot_partition.as_deref())
            .ok_or("Choose a boot partition with b.")?;
        let root = self
            .partition(self.root_partition.as_deref())
            .ok_or("Choose a root partition with r.")?;
        if boot.mounted || root.mounted {
            return Err("Unmount the chosen partitions first.".into());
        }
        if boot.size < MINIMUM_BOOT_BYTES {
            return Err(format!(
                "The boot partition needs at least {}.",
                system::format_size(MINIMUM_BOOT_BYTES)
            ));
        }
        if !self.format_boot && !boot.is_vfat() {
            return Err("Only a FAT boot partition can be kept; press f to format it.".into());
        }
        let needs_bios_boot = self.loader() == BootLoader::Grub && self.boot_mode == BootMode::Bios;
        if needs_bios_boot && !self.partitions.iter().any(Partition::is_bios_boot) {
            return Err(
                "GRUB on a BIOS machine needs a 1 MiB \"BIOS boot\" partition. Press e to create one.".into(),
            );
        }
        if root.size < MINIMUM_ROOT_BYTES {
            return Err(format!(
                "The root partition needs at least {}.",
                system::format_size(MINIMUM_ROOT_BYTES)
            ));
        }
        Ok(())
    }

    /// Called after cfdisk returns, since the partitions may have changed.
    pub fn after_external(&mut self, result: Result<(), String>) {
        self.refresh_partitions();
        if let Err(error) = result {
            self.modal = Some(Modal::Notice(error));
        }
    }

    fn advance(&mut self) {
        let position = Screen::WIZARD.iter().position(|screen| *screen == self.screen);
        let next = position.and_then(|position| {
            Screen::WIZARD[position + 1..]
                .iter()
                .copied()
                .find(|screen| self.applicable(*screen))
        });
        if let Some(screen) = next {
            self.enter(screen);
        }
    }

    fn back(&mut self) {
        let position = Screen::WIZARD.iter().position(|screen| *screen == self.screen);
        let previous = position.and_then(|position| {
            Screen::WIZARD[..position]
                .iter()
                .rev()
                .copied()
                .find(|screen| self.applicable(*screen))
        });
        if let Some(screen) = previous {
            self.enter(screen);
        }
    }

    fn submit_account(&mut self) {
        self.form_error = if !config::valid_host(&self.host.value) {
            Some("Host names use letters, digits, and hyphens, and cannot start with a hyphen.".to_string())
        } else if !config::valid_user(&self.user.value) {
            Some("User names use lowercase letters, digits, hyphens, and underscores, and cannot be root.".to_string())
        } else if self.password.value.is_empty() {
            Some("The password cannot be empty.".to_string())
        } else if self.password.value != self.confirm.value {
            Some("The passwords do not match.".to_string())
        } else {
            None
        };
        if self.form_error.is_none() {
            self.advance();
        }
    }

    fn take_lock(&mut self) -> bool {
        if self.options.demo || self.lock.is_some() {
            return true;
        }
        let Ok(file) = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(LOCK_PATH)
        else {
            return false;
        };
        if file.try_lock().is_err() {
            return false;
        }
        self.lock = Some(file);
        true
    }

    fn start_install(&mut self) {
        let Some(disk) = self.disk().map(|disk| disk.path.clone()) else {
            return;
        };
        if !self.take_lock() {
            self.modal = Some(Modal::Notice(
                "Another session is already installing.".to_string(),
            ));
            return;
        }
        let plan = Plan {
            layout: self.layout(),
            flake: self.options.flake.clone(),
            host: self.host.value.clone(),
            user: self.user.value.clone(),
            password: self.password.value.clone(),
            timezone: self.timezone(),
            desktop: self.desktop(),
            network: self.connection(),
            root_fs: self.filesystem(),
            boot_mode: self.boot_mode,
            loader: self.loader(),
            disk,
        };
        self.log.clear();
        self.scroll = 0;
        self.phase = 0;
        self.phase_done = false;
        self.error = None;
        self.started = Some(Instant::now());
        self.finished = None;
        self.screen = Screen::Installing;
        install::spawn(plan, self.options.demo, self.options.demo_fail, self.sender.clone());
    }

    pub fn on_message(&mut self, message: Message) {
        match message {
            Message::Online(online) => {
                self.checking = false;
                self.online = if online {
                    OnlineState::Online
                } else {
                    OnlineState::Offline
                };
            }
            Message::Scanned(networks) => {
                self.scanning = false;
                self.networks = networks;
                self.network_list
                    .select((!self.networks.is_empty()).then_some(0));
            }
            Message::Connected(result) => {
                self.connecting = None;
                match result {
                    Ok(()) => {
                        if self.options.demo {
                            self.online = OnlineState::Online;
                        } else {
                            self.check_online();
                        }
                    }
                    Err(error) => {
                        self.modal = Some(Modal::Notice(format!("Could not connect: {error}")));
                    }
                }
            }
            Message::Install(update) => self.on_install(update),
        }
    }

    fn on_install(&mut self, update: Update) {
        match update {
            Update::Phase(phase) => self.phase = phase,
            Update::Line(line) => {
                self.log.push(line);
                if self.log.len() > MAX_LOG_LINES {
                    self.log.remove(0);
                }
            }
            Update::Finished(result) => {
                self.finished = self.started.map(|started| started.elapsed());
                match result {
                    Ok(()) => {
                        self.phase_done = true;
                        self.password.value.clear();
                        self.confirm.value.clear();
                        self.screen = Screen::Done;
                    }
                    Err(error) => {
                        self.error = Some(error);
                        self.screen = Screen::Failed;
                    }
                }
            }
        }
    }

    pub fn tick(&mut self) {
        self.frame = self.frame.wrapping_add(1);
        let due = self
            .last_check
            .is_none_or(|checked| checked.elapsed() >= RECHECK_INTERVAL);
        if self.screen == Screen::Network && self.online != OnlineState::Online && due {
            self.check_online();
        }
    }

    pub fn hints(&self) -> Vec<(&'static str, &'static str)> {
        if self.modal.is_some() {
            return vec![("enter", "confirm"), ("esc", "cancel")];
        }
        match self.screen {
            Screen::Welcome => vec![("enter", "begin"), ("ctrl+c", "shell")],
            Screen::Network if self.wireless => vec![
                ("enter", "continue / join"),
                ("o", "other"),
                ("r", "rescan"),
                ("s", "skip"),
                ("esc", "back"),
            ],
            Screen::Network => vec![("enter", "continue"), ("s", "skip"), ("esc", "back")],
            Screen::Account => vec![("tab", "next"), ("enter", "continue"), ("esc", "back")],
            Screen::Timezone => vec![("type", "search"), ("enter", "continue"), ("esc", "back")],
            Screen::Partitions => vec![
                ("b", "boot"),
                ("r", "root"),
                ("f", "format boot"),
                ("e", "cfdisk"),
                ("enter", "continue"),
                ("esc", "back"),
            ],
            Screen::Review => vec![("enter", "install"), ("esc", "back")],
            Screen::Installing => vec![("pgup/pgdn", "scroll log")],
            Screen::Failed => vec![
                ("r", "retry"),
                ("b", "change settings"),
                ("s", "shell"),
                ("pgup/pgdn", "log"),
            ],
            Screen::Done => vec![("enter", "select")],
            _ => vec![("up/down", "select"), ("enter", "continue"), ("esc", "back")],
        }
    }

    pub fn on_key(&mut self, key: KeyEvent) {
        if let Some(modal) = self.modal.take() {
            self.on_modal_key(modal, key);
            return;
        }
        let interrupted =
            key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL);
        if interrupted {
            // The install thread is in the middle of writing to the disk.
            if self.screen != Screen::Installing {
                self.modal = Some(Modal::Quit);
            }
            return;
        }
        match self.screen {
            Screen::Welcome => {
                if key.code == KeyCode::Enter {
                    self.advance();
                }
            }
            Screen::Network => self.on_network_key(key),
            Screen::Disk => match key.code {
                KeyCode::Enter if self.disk().is_some() => self.advance(),
                KeyCode::Char('r') => self.enter(Screen::Disk),
                KeyCode::Esc => self.back(),
                _ => self.on_list_key(key, ListId::Disk),
            },
            Screen::Partitioning => match key.code {
                KeyCode::Up | KeyCode::Down | KeyCode::Char('j') | KeyCode::Char('k') => {
                    self.on_list_key(key, ListId::Partitioning);
                    self.refresh_partitions();
                }
                _ => self.on_wizard_list_key(key, ListId::Partitioning),
            },
            Screen::Partitions => self.on_partitions_key(key),
            Screen::Bootloader => self.on_wizard_list_key(key, ListId::Bootloader),
            Screen::Filesystem => self.on_wizard_list_key(key, ListId::Filesystem),
            Screen::Desktop => self.on_wizard_list_key(key, ListId::Desktop),
            Screen::Connection => self.on_wizard_list_key(key, ListId::Connection),
            Screen::Account => self.on_account_key(key),
            Screen::Timezone => self.on_timezone_key(key),
            Screen::Review => match key.code {
                KeyCode::Esc => self.back(),
                KeyCode::Enter if self.confirmation.value == CONFIRMATION => self.start_install(),
                _ => {
                    self.confirmation.handle(key);
                }
            },
            Screen::Installing => self.on_log_key(key),
            Screen::Failed => match key.code {
                KeyCode::Char('r') => self.start_install(),
                KeyCode::Char('b') => {
                    install::unmount(self.options.demo);
                    self.lock = None;
                    self.enter(Screen::Disk);
                }
                KeyCode::Char('s') => {
                    install::unmount(self.options.demo);
                    self.exit = Some(Exit::Shell);
                }
                _ => self.on_log_key(key),
            },
            Screen::Done => match key.code {
                KeyCode::Enter if self.done_list.selected() == Some(2) => {
                    if self.options.demo {
                        self.modal = Some(Modal::Notice(
                            "Demo mode does not open a chroot.".to_string(),
                        ));
                    } else {
                        self.external = Some(External::Chroot(install::TARGET.to_string()));
                    }
                }
                KeyCode::Enter => {
                    install::unmount(self.options.demo);
                    self.exit = Some(match self.done_list.selected() {
                        Some(0) => Exit::Reboot,
                        Some(1) => Exit::Poweroff,
                        _ => Exit::Shell,
                    });
                }
                _ => self.on_list_key(key, ListId::Done),
            },
        }
    }

    fn on_log_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::PageUp => {
                self.scroll = (self.scroll + 10).min(self.log.len());
            }
            KeyCode::PageDown => self.scroll = self.scroll.saturating_sub(10),
            _ => {}
        }
    }

    fn on_network_key(&mut self, key: KeyEvent) {
        if self.connecting.is_some() {
            return;
        }
        match key.code {
            KeyCode::Esc => self.back(),
            KeyCode::Enter if self.online == OnlineState::Online => self.advance(),
            KeyCode::Enter | KeyCode::Char('c') => self.join_selected(),
            KeyCode::Char('s') => self.advance(),
            KeyCode::Char('r') => self.scan(),
            KeyCode::Char('o') if self.wireless => {
                self.modal = Some(Modal::WifiName(Input::default()));
            }
            _ => self.on_list_key(key, ListId::Network),
        }
    }

    fn join_selected(&mut self) {
        let Some(network) = self
            .network_list
            .selected()
            .and_then(|index| self.networks.get(index))
            .cloned()
        else {
            return;
        };
        if network.secured {
            self.modal = Some(Modal::WifiPassword {
                ssid: network.ssid,
                input: Input::masked(),
            });
        } else {
            self.connect(network.ssid, None);
        }
    }

    fn on_modal_key(&mut self, modal: Modal, key: KeyEvent) {
        match modal {
            Modal::Quit => match key.code {
                KeyCode::Enter => self.exit = Some(Exit::Shell),
                KeyCode::Esc => {}
                _ => self.modal = Some(Modal::Quit),
            },
            Modal::Notice(_) => {}
            Modal::WifiName(mut input) => match key.code {
                KeyCode::Esc => {}
                KeyCode::Enter if input.value.is_empty() => {
                    self.modal = Some(Modal::WifiName(input));
                }
                KeyCode::Enter => {
                    self.modal = Some(Modal::WifiPassword {
                        ssid: input.value,
                        input: Input::masked(),
                    });
                }
                _ => {
                    input.handle(key);
                    self.modal = Some(Modal::WifiName(input));
                }
            },
            Modal::WifiPassword { ssid, mut input } => match key.code {
                KeyCode::Esc => {}
                KeyCode::Enter => {
                    let password = (!input.value.is_empty()).then_some(input.value);
                    self.connect(ssid, password);
                }
                _ => {
                    input.handle(key);
                    self.modal = Some(Modal::WifiPassword { ssid, input });
                }
            },
        }
    }

    fn on_wizard_list_key(&mut self, key: KeyEvent, list: ListId) {
        match key.code {
            KeyCode::Enter => self.advance(),
            KeyCode::Esc => self.back(),
            _ => self.on_list_key(key, list),
        }
    }

    fn on_list_key(&mut self, key: KeyEvent, list: ListId) {
        let forward = match key.code {
            KeyCode::Up | KeyCode::Char('k') => false,
            KeyCode::Down | KeyCode::Char('j') => true,
            _ => return,
        };
        let (state, length) = match list {
            ListId::Network => (&mut self.network_list, self.networks.len()),
            ListId::Disk => (&mut self.disk_list, self.disks.len()),
            ListId::Filesystem => (&mut self.filesystem_list, Filesystem::ALL.len()),
            ListId::Desktop => (&mut self.desktop_list, Desktop::ALL.len()),
            ListId::Connection => (&mut self.connection_list, Network::ALL.len()),
            ListId::Done => (&mut self.done_list, DONE_ACTIONS.len()),
            ListId::Bootloader => (&mut self.bootloader_list, BootLoader::ALL.len()),
            ListId::Partitioning => (&mut self.partitioning_list, 2),
            ListId::Partitions => (&mut self.partition_list, self.partitions.len()),
        };
        move_selection(state, length, forward);
    }

    fn on_partitions_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Esc => self.back(),
            KeyCode::Enter => match self.check_manual() {
                Ok(()) => self.advance(),
                Err(error) => self.partition_error = Some(error),
            },
            KeyCode::Char('b') => self.assign_boot(),
            KeyCode::Char('r') => self.assign_root(),
            KeyCode::Char('f') => self.toggle_format_boot(),
            KeyCode::Char('e') => {
                if self.options.demo {
                    self.modal = Some(Modal::Notice(
                        "Demo mode does not open cfdisk.".to_string(),
                    ));
                } else if let Some(disk) = self.disk().map(|disk| disk.path.clone()) {
                    self.external = Some(External::EditPartitions(disk));
                }
            }
            _ => self.on_list_key(key, ListId::Partitions),
        }
    }

    fn on_account_key(&mut self, key: KeyEvent) {
        const LAST_FIELD: usize = 3;
        match key.code {
            KeyCode::Esc => self.back(),
            KeyCode::Tab | KeyCode::Down => self.focus = (self.focus + 1).min(LAST_FIELD),
            KeyCode::BackTab | KeyCode::Up => self.focus = self.focus.saturating_sub(1),
            KeyCode::Enter if self.focus < LAST_FIELD => self.focus += 1,
            KeyCode::Enter => self.submit_account(),
            _ => {
                let field = match self.focus {
                    0 => &mut self.host,
                    1 => &mut self.user,
                    2 => &mut self.password,
                    _ => &mut self.confirm,
                };
                if field.handle(key) {
                    self.form_error = None;
                }
            }
        }
    }

    fn on_timezone_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Esc => self.back(),
            KeyCode::Enter if self.selected_zone().is_some() => self.advance(),
            KeyCode::Up | KeyCode::Down => {
                let length = self.visible_zones().len();
                move_selection(&mut self.zone_list, length, key.code == KeyCode::Down);
            }
            _ => {
                if self.zone_filter.handle(key) {
                    let empty = self.visible_zones().is_empty();
                    self.zone_list.select((!empty).then_some(0));
                }
            }
        }
    }
}

pub const DONE_ACTIONS: [&str; 4] = [
    "Reboot now",
    "Power off",
    "Open a shell in the installed system (chroot)",
    "Exit to shell",
];

#[derive(Clone, Copy)]
enum ListId {
    Network,
    Disk,
    Bootloader,
    Partitioning,
    Partitions,
    Filesystem,
    Desktop,
    Connection,
    Done,
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use std::sync::mpsc::{channel, Receiver};

    pub fn demo_app() -> (App, Receiver<Message>) {
        let (sender, receiver) = channel();
        let app = App::new(
            Options {
                demo: true,
                demo_fail: false,
                flake: "github:runix-community/runix".to_string(),
                zoneinfo: "/nonexistent".to_string(),
            },
            sender,
        );
        (app, receiver)
    }

    fn press(app: &mut App, code: KeyCode) {
        app.on_key(KeyEvent::new(code, KeyModifiers::NONE));
    }

    fn type_text(app: &mut App, text: &str) {
        for c in text.chars() {
            press(app, KeyCode::Char(c));
        }
    }

    pub fn fill_account(app: &mut App) {
        app.screen = Screen::Account;
        app.focus = 1;
        type_text(app, "alice");
        press(app, KeyCode::Tab);
        type_text(app, "secret");
        press(app, KeyCode::Tab);
        type_text(app, "secret");
    }

    fn at_review(app: &mut App) {
        app.enter(Screen::Disk);
        fill_account(app);
        press(app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Timezone);
        app.enter(Screen::Review);
    }

    #[test]
    fn install_needs_the_exact_confirmation() {
        let (mut app, _receiver) = demo_app();
        at_review(&mut app);
        type_text(&mut app, "erase");
        press(&mut app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Review);
        for _ in 0..5 {
            press(&mut app, KeyCode::Backspace);
        }
        type_text(&mut app, CONFIRMATION);
        press(&mut app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Installing);
    }

    #[test]
    fn going_back_clears_the_confirmation() {
        let (mut app, _receiver) = demo_app();
        at_review(&mut app);
        type_text(&mut app, CONFIRMATION);
        press(&mut app, KeyCode::Esc);
        app.enter(Screen::Review);
        assert!(app.confirmation.value.is_empty());
    }

    #[test]
    fn ctrl_c_cannot_interrupt_an_install() {
        let (mut app, _receiver) = demo_app();
        app.screen = Screen::Installing;
        app.on_key(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL));
        assert!(app.modal.is_none());
        assert!(app.exit.is_none());
    }

    #[test]
    fn mismatched_passwords_stay_on_the_form() {
        let (mut app, _receiver) = demo_app();
        fill_account(&mut app);
        type_text(&mut app, "x");
        press(&mut app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Account);
        assert!(app.form_error.is_some());
    }

    #[test]
    fn invalid_names_stay_on_the_form() {
        let (mut app, _receiver) = demo_app();
        fill_account(&mut app);
        app.user.value = "ro\"ot".to_string();
        press(&mut app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Account);
    }

    #[test]
    fn passwords_are_cleared_after_success() {
        let (mut app, _receiver) = demo_app();
        fill_account(&mut app);
        app.on_message(Message::Install(Update::Finished(Ok(()))));
        assert_eq!(app.screen, Screen::Done);
        assert!(app.password.value.is_empty());
        assert!(app.confirm.value.is_empty());
    }

    #[test]
    fn a_failed_install_offers_recovery() {
        let (mut app, _receiver) = demo_app();
        app.on_message(Message::Install(Update::Finished(Err("boom".to_string()))));
        assert_eq!(app.screen, Screen::Failed);
        assert_eq!(app.error.as_deref(), Some("boom"));
    }

    #[test]
    fn connection_screen_is_skipped_without_wifi() {
        let (mut app, _receiver) = demo_app();
        app.wireless = false;
        app.screen = Screen::Desktop;
        press(&mut app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Review);
        assert_eq!(app.connection(), Network::Dhcpcd);
        press(&mut app, KeyCode::Esc);
        assert_eq!(app.screen, Screen::Desktop);
    }

    fn at_partitions(app: &mut App) {
        app.enter(Screen::Disk);
        press(app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Bootloader);
        press(app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Partitioning);
        press(app, KeyCode::Down);
        assert!(app.manual());
        press(app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Partitions);
    }

    #[test]
    fn automatic_partitioning_skips_the_partition_picker() {
        let (mut app, _receiver) = demo_app();
        app.enter(Screen::Disk);
        press(&mut app, KeyCode::Enter);
        press(&mut app, KeyCode::Enter);
        press(&mut app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Filesystem);
        assert_eq!(app.layout(), DiskLayout::Automatic);
        press(&mut app, KeyCode::Esc);
        assert_eq!(app.screen, Screen::Partitioning);
    }

    #[test]
    fn an_existing_esp_is_kept_by_default() {
        let (mut app, _receiver) = demo_app();
        at_partitions(&mut app);
        assert_eq!(app.boot_partition.as_deref(), Some("/dev/nvme0n1p1"));
        assert!(!app.format_boot);
    }

    #[test]
    fn manual_partitioning_needs_a_root() {
        let (mut app, _receiver) = demo_app();
        at_partitions(&mut app);
        press(&mut app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Partitions);
        assert!(app.partition_error.is_some());
        press(&mut app, KeyCode::Down);
        press(&mut app, KeyCode::Down);
        press(&mut app, KeyCode::Char('r'));
        press(&mut app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Filesystem);
        assert_eq!(
            app.layout(),
            DiskLayout::Manual {
                boot: "/dev/nvme0n1p1".into(),
                root: "/dev/nvme0n1p3".into(),
                format_boot: false,
            }
        );
    }

    #[test]
    fn one_partition_cannot_be_boot_and_root() {
        let (mut app, _receiver) = demo_app();
        at_partitions(&mut app);
        press(&mut app, KeyCode::Char('r'));
        assert_eq!(app.root_partition.as_deref(), Some("/dev/nvme0n1p1"));
        assert_eq!(app.boot_partition, None);
    }

    #[test]
    fn only_fat_boot_partitions_can_be_kept() {
        let (mut app, _receiver) = demo_app();
        at_partitions(&mut app);
        press(&mut app, KeyCode::Down);
        press(&mut app, KeyCode::Down);
        press(&mut app, KeyCode::Char('b'));
        assert!(app.format_boot);
        press(&mut app, KeyCode::Char('f'));
        assert!(app.format_boot);
    }

    #[test]
    fn switching_back_to_automatic_ignores_manual_choices() {
        let (mut app, _receiver) = demo_app();
        at_partitions(&mut app);
        press(&mut app, KeyCode::Char('r'));
        app.partitioning_list.select(Some(0));
        assert_eq!(app.layout(), DiskLayout::Automatic);
    }

    #[test]
    fn grub_on_bios_needs_a_bios_boot_partition() {
        let (mut app, _receiver) = demo_app();
        app.boot_mode = BootMode::Bios;
        app.bootloader_list.select(Some(1));
        app.enter(Screen::Disk);
        app.partitioning_list.select(Some(1));
        app.enter(Screen::Partitions);
        app.root_partition = Some("/dev/nvme0n1p3".into());
        let error = app.check_manual().unwrap_err();
        assert!(error.contains("BIOS boot"));
        app.bootloader_list.select(Some(0));
        assert!(app.check_manual().is_ok());
    }

    #[test]
    fn the_finish_screen_can_open_a_chroot() {
        let (mut app, _receiver) = demo_app();
        app.options.demo = false;
        app.screen = Screen::Done;
        app.done_list.select(Some(2));
        press(&mut app, KeyCode::Enter);
        assert!(matches!(app.external, Some(External::Chroot(ref path)) if path == "/mnt"));
        assert!(app.exit.is_none());
    }

    #[test]
    fn time_zone_search_narrows_the_list() {
        let (mut app, _receiver) = demo_app();
        app.zones = vec!["UTC".into(), "Europe/Paris".into(), "Asia/Tokyo".into()];
        app.screen = Screen::Timezone;
        type_text(&mut app, "pari");
        assert_eq!(app.timezone(), "Europe/Paris");
        type_text(&mut app, "zzz");
        assert_eq!(app.selected_zone(), None);
        press(&mut app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Timezone);
    }
}
