//! The destructive part of the installer. It runs on its own thread and stops
//! at the first failed step; nothing here may continue past an error.

use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, OpenOptionsExt};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc::Sender;
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

use crate::app::Message;
use crate::config::{self, BootLoader, BootMode, Filesystem, Network, Settings};
use crate::system;

pub const LOG_PATH: &str = "/tmp/runix-install.log";
pub const TARGET: &str = "/mnt";
const WIFI_CONFIG: &str = "/var/lib/runix/wifi/wpa_supplicant.conf";

pub const PHASES: [&str; 6] = [
    "Prepare disk",
    "Format filesystems",
    "Mount target",
    "Write configuration",
    "Install system",
    "Finish",
];

#[derive(Debug)]
pub enum Update {
    Phase(usize),
    Line(String),
    Finished(Result<(), String>),
}

pub const BOOT_SIZE: u64 = 1024 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DiskLayout {
    /// Erase the whole disk: a 1 GiB boot partition, root on the rest, and a
    /// 1 MiB BIOS boot partition that GRUB needs on BIOS machines.
    Automatic,
    /// Use existing partitions. The partition table is never changed.
    Manual {
        boot: String,
        root: String,
        format_boot: bool,
    },
}

type Commands = Vec<Vec<String>>;

fn command(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|part| (*part).to_string()).collect()
}

/// Commands that rewrite the partition table. Manual layouts have none.
fn partition_commands(layout: &DiskLayout, disk: &str) -> Commands {
    match layout {
        DiskLayout::Automatic => vec![
            command(&["wipefs", "-af", disk]),
            command(&["sgdisk", "--zap-all", disk]),
            command(&[
                "sgdisk",
                "-n3:1MiB:+1MiB",
                "-t3:ef02",
                "-c3:RUNIX_BIOS",
                "-n1:2MiB:+1GiB",
                "-t1:ef00",
                "-c1:RUNIX_BOOT",
                "-n2:0:0",
                "-t2:8300",
                "-c2:RUNIX_ROOT",
                disk,
            ]),
        ],
        DiskLayout::Manual { .. } => Vec::new(),
    }
}

/// The boot and root partitions a layout installs to.
fn targets(layout: &DiskLayout, disk: &str) -> (String, String) {
    match layout {
        DiskLayout::Automatic => (partition_path(disk, 1), partition_path(disk, 2)),
        DiskLayout::Manual { boot, root, .. } => (boot.clone(), root.clone()),
    }
}

fn format_commands(layout: &DiskLayout, root_fs: Filesystem, boot: &str, root: &str) -> Commands {
    let mut commands = Vec::new();
    let format_boot = match layout {
        DiskLayout::Automatic => true,
        DiskLayout::Manual { format_boot, .. } => *format_boot,
    };
    if format_boot {
        commands.push(command(&["mkfs.fat", "-F32", "-n", "RUNIXBOOT", boot]));
    }
    // Old signatures on a reused partition would confuse blkid later.
    commands.push(command(&["wipefs", "-a", root]));
    commands.push(match root_fs {
        Filesystem::Ext4 => command(&["mkfs.ext4", "-q", "-F", "-L", "runix-root", root]),
        Filesystem::Btrfs => command(&["mkfs.btrfs", "-q", "-f", "-L", "runix-root", root]),
    });
    commands
}

/// Everything chosen in the UI. UUIDs are only known once the disk is formatted.
pub struct Plan {
    pub layout: DiskLayout,
    pub flake: String,
    pub host: String,
    pub user: String,
    pub password: String,
    pub timezone: String,
    pub desktop: config::Desktop,
    pub network: Network,
    pub root_fs: Filesystem,
    pub boot_mode: BootMode,
    pub loader: BootLoader,
    pub disk: String,
}

pub fn partition_path(disk: &str, number: u32) -> String {
    if disk.ends_with(|c: char| c.is_ascii_digit()) {
        format!("{disk}p{number}")
    } else {
        format!("{disk}{number}")
    }
}

/// Terminal control codes in build output would corrupt the screen.
fn clean_line(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .chars()
        .filter(|c| !c.is_control() || *c == '\t')
        .map(|c| if c == '\t' { ' ' } else { c })
        .collect()
}

struct Runner {
    sender: Sender<Message>,
    log: Mutex<Option<File>>,
}

impl Runner {
    fn send(&self, update: Update) {
        let _ = self.sender.send(Message::Install(update));
    }

    fn line(&self, text: String) {
        if let Ok(mut log) = self.log.lock() {
            if let Some(file) = log.as_mut() {
                let _ = writeln!(file, "{text}");
            }
        }
        self.send(Update::Line(text));
    }

    fn phase(&self, index: usize) {
        self.send(Update::Phase(index));
        self.line(format!("==> {}", PHASES[index]));
    }

    fn run_all(&self, commands: &Commands) -> Result<(), String> {
        for command in commands {
            let arguments: Vec<&str> = command[1..].iter().map(String::as_str).collect();
            self.run(&command[0], &arguments, &[])?;
        }
        Ok(())
    }

    fn stream<R: Read>(&self, reader: R) {
        for line in BufReader::new(reader).split(b'\n').map_while(Result::ok) {
            let text = clean_line(&line);
            if !text.is_empty() {
                self.line(text);
            }
        }
    }

    /// Runs a command, streaming its output, and fails on a non-zero exit.
    fn run(&self, program: &str, args: &[&str], environment: &[(&str, &str)]) -> Result<(), String> {
        self.line(format!("$ {program} {}", args.join(" ")));
        let mut child = Command::new(program)
            .args(args)
            .envs(environment.iter().copied())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| format!("could not start {program}: {error}"))?;
        let stdout = child.stdout.take().ok_or("stdout was not captured")?;
        let stderr = child.stderr.take().ok_or("stderr was not captured")?;
        thread::scope(|scope| {
            scope.spawn(|| self.stream(stdout));
            scope.spawn(|| self.stream(stderr));
        });
        let status = child
            .wait()
            .map_err(|error| format!("{program} did not finish: {error}"))?;
        if status.success() {
            Ok(())
        } else {
            Err(format!("{program} failed ({status})"))
        }
    }
}

fn capture(program: &str, args: &[&str]) -> Result<String, String> {
    let output = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("could not start {program}: {error}"))?;
    if !output.status.success() {
        return Err(format!("{program} failed ({})", output.status));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn hash_password(password: &str) -> Result<String, String> {
    let mut child = Command::new("mkpasswd")
        .args(["-m", "yescrypt", "--stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("could not start mkpasswd: {error}"))?;
    child
        .stdin
        .take()
        .ok_or("mkpasswd stdin was not captured")?
        .write_all(password.as_bytes())
        .map_err(|error| format!("could not send the password to mkpasswd: {error}"))?;
    let output = child
        .wait_with_output()
        .map_err(|error| format!("mkpasswd did not finish: {error}"))?;
    let hash = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !output.status.success() || hash.is_empty() {
        return Err("mkpasswd could not hash the password".to_string());
    }
    Ok(hash)
}

fn wait_for_block_device(path: &str) -> Result<(), String> {
    for _ in 0..100 {
        if fs::metadata(path).is_ok_and(|metadata| metadata.file_type().is_block_device()) {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err(format!("device did not appear: {path}"))
}

fn write_file(path: &str, contents: &str) -> Result<(), String> {
    fs::write(path, contents).map_err(|error| format!("could not write {path}: {error}"))
}

pub fn unmount(demo: bool) {
    if !demo {
        let _ = Command::new("umount")
            .args(["-R", TARGET])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

fn install(plan: &Plan, runner: &Runner) -> Result<(), String> {
    let disk = plan.disk.as_str();
    let (boot, root) = targets(&plan.layout, disk);

    runner.phase(0);
    unmount(false);
    // A manual layout only formats its own partitions, so other mounted
    // partitions on the same disk are fine there.
    let busy = match plan.layout {
        DiskLayout::Automatic => vec![disk],
        DiskLayout::Manual { .. } => vec![boot.as_str(), root.as_str()],
    };
    for device in busy {
        if !capture("lsblk", &["-nrpo", "MOUNTPOINT", device])?.trim().is_empty() {
            return Err(format!("{device} is in use; unmount it and try again"));
        }
    }
    let partitioning = partition_commands(&plan.layout, disk);
    runner.run_all(&partitioning)?;
    if !partitioning.is_empty() {
        // The partitions may already be visible, so a failure here is not fatal.
        let _ = runner.run("blockdev", &["--rereadpt", disk], &[]);
    }
    wait_for_block_device(&boot)?;
    wait_for_block_device(&root)?;

    runner.phase(1);
    runner.run_all(&format_commands(&plan.layout, plan.root_fs, &boot, &root))?;

    runner.phase(2);
    fs::create_dir_all(TARGET).map_err(|error| format!("could not create {TARGET}: {error}"))?;
    runner.run("mount", &[&root, TARGET], &[])?;
    let boot_target = format!("{TARGET}/boot");
    fs::create_dir_all(&boot_target).map_err(|error| format!("could not create {boot_target}: {error}"))?;
    runner.run("mount", &[&boot, &boot_target], &[])?;

    runner.phase(3);
    let secrets = format!("{TARGET}/var/lib/runix/secrets");
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&secrets)
        .map_err(|error| format!("could not create {secrets}: {error}"))?;
    let hash_file = format!("{TARGET}{}", config::password_hash_path(&plan.user));
    let hash = hash_password(&plan.password)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&hash_file)
        .map_err(|error| format!("could not create {hash_file}: {error}"))?;
    file.write_all(hash.as_bytes())
        .map_err(|error| format!("could not write {hash_file}: {error}"))?;

    let settings = Settings {
        flake: plan.flake.clone(),
        host: plan.host.clone(),
        user: plan.user.clone(),
        timezone: plan.timezone.clone(),
        desktop: plan.desktop,
        network: plan.network,
        root_uuid: capture("blkid", &["-s", "UUID", "-o", "value", &root])?,
        root_fs: plan.root_fs,
        boot_uuid: capture("blkid", &["-s", "UUID", "-o", "value", &boot])?,
        boot_mode: plan.boot_mode,
        loader: plan.loader,
        disk: plan.disk.clone(),
        cpu: system::cpu_vendor(),
    };
    if settings.root_uuid.is_empty() || settings.boot_uuid.is_empty() {
        return Err("blkid returned no filesystem UUID".to_string());
    }
    let flake_directory = format!("{TARGET}/etc/runix");
    fs::create_dir_all(&flake_directory)
        .map_err(|error| format!("could not create {flake_directory}: {error}"))?;
    write_file(&format!("{flake_directory}/flake.nix"), &config::flake(&settings))?;
    write_file(&format!("{flake_directory}/hardware.nix"), &config::hardware(&settings))?;
    write_file(
        &format!("{flake_directory}/configuration.nix"),
        &config::configuration(&settings),
    )?;

    // Keep the network joined in the live session for the first boot.
    if plan.network == Network::Wifi && Path::new(WIFI_CONFIG).is_file() {
        runner.run(
            "install",
            &["-D", "-m0600", WIFI_CONFIG, &format!("{TARGET}{WIFI_CONFIG}")],
            &[],
        )?;
    }

    runner.phase(4);
    // The live system runs from RAM, so builds must use the target disk.
    let build_directory = format!("{TARGET}/var/tmp");
    fs::create_dir_all(&build_directory)
        .map_err(|error| format!("could not create {build_directory}: {error}"))?;
    let flake_reference = format!("{flake_directory}#{}", plan.host);
    runner.run(
        "runix-install",
        &[
            "--flake",
            &flake_reference,
            "--root",
            TARGET,
            "--",
            "--accept-flake-config",
        ],
        &[("TMPDIR", &build_directory)],
    )?;

    runner.phase(5);
    if let Ok(entries) = fs::read_dir(&build_directory) {
        for entry in entries.flatten() {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
    runner.run("sync", &[], &[])?;
    Ok(())
}

fn demo(fail: bool, runner: &Runner) -> Result<(), String> {
    for (index, name) in PHASES.iter().enumerate() {
        runner.phase(index);
        for step in 1..=12 {
            runner.line(format!("demo: {name} step {step} of 12"));
            thread::sleep(Duration::from_millis(120));
        }
        if fail && index == 4 {
            return Err("demo: simulated failure".to_string());
        }
    }
    Ok(())
}

pub fn spawn(plan: Plan, demo_mode: bool, demo_fail: bool, sender: Sender<Message>) {
    thread::spawn(move || {
        let log = if demo_mode { None } else { File::create(LOG_PATH).ok() };
        let runner = Runner {
            sender,
            log: Mutex::new(log),
        };
        let result = if demo_mode {
            demo(demo_fail, &runner)
        } else {
            install(&plan, &runner)
        };
        if let Err(error) = &result {
            runner.line(format!("error: {error}"));
        }
        runner.send(Update::Finished(result));
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partition_names_follow_kernel_rules() {
        assert_eq!(partition_path("/dev/sda", 1), "/dev/sda1");
        assert_eq!(partition_path("/dev/vdb", 2), "/dev/vdb2");
        assert_eq!(partition_path("/dev/nvme0n1", 2), "/dev/nvme0n1p2");
        assert_eq!(partition_path("/dev/mmcblk0", 1), "/dev/mmcblk0p1");
    }

    fn manual(format_boot: bool) -> DiskLayout {
        DiskLayout::Manual {
            boot: "/dev/sda1".into(),
            root: "/dev/sda3".into(),
            format_boot,
        }
    }

    #[test]
    fn manual_layouts_never_touch_the_partition_table() {
        assert!(partition_commands(&manual(true), "/dev/sda").is_empty());
        for format_boot in [true, false] {
            for filesystem in Filesystem::ALL {
                let commands =
                    format_commands(&manual(format_boot), filesystem, "/dev/sda1", "/dev/sda3");
                assert!(
                    commands.iter().flatten().all(|argument| argument != "/dev/sda"),
                    "a manual layout touched the whole disk: {commands:?}"
                );
            }
        }
    }

    #[test]
    fn a_kept_boot_partition_is_not_formatted() {
        let commands = format_commands(&manual(false), Filesystem::Ext4, "/dev/sda1", "/dev/sda3");
        assert!(commands.iter().flatten().all(|argument| argument != "/dev/sda1"));
        let commands = format_commands(&manual(true), Filesystem::Ext4, "/dev/sda1", "/dev/sda3");
        assert!(commands.iter().any(|command| command[0] == "mkfs.fat"));
    }

    #[test]
    fn automatic_layouts_use_the_new_partitions() {
        assert_eq!(
            targets(&DiskLayout::Automatic, "/dev/nvme0n1"),
            ("/dev/nvme0n1p1".to_string(), "/dev/nvme0n1p2".to_string())
        );
        let commands = partition_commands(&DiskLayout::Automatic, "/dev/sda");
        assert_eq!(commands.len(), 3);
        assert!(commands[2].iter().any(|argument| argument == "-t3:ef02"));
    }

    #[test]
    fn control_codes_are_removed_from_output() {
        assert_eq!(clean_line(b"\x1b[31mbad\tline\r"), "[31mbad line");
    }

    #[test]
    fn a_failing_command_stops_with_an_error() {
        let (sender, _receiver) = std::sync::mpsc::channel();
        let runner = Runner {
            sender,
            log: Mutex::new(None),
        };
        assert!(runner.run("false", &[], &[]).is_err());
        assert!(runner.run("true", &[], &[]).is_ok());
        assert!(runner.run("runix-no-such-program", &[], &[]).is_err());
    }
}
