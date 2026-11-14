mod app;
mod config;
mod install;
mod system;
mod ui;

use std::env;
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode};
use std::sync::mpsc::channel;
use std::time::Duration;

use ratatui::crossterm::event::{self, Event, KeyEventKind};
use ratatui::DefaultTerminal;

use app::{App, Exit, External, Options};

const USAGE: &str = "Usage: runix-installer [OPTIONS]

Options:
  --demo       Walk through the installer without changing anything
  --demo-fail  Like --demo, and end with a failed installation
  -h, --help   Show this help";

/// Runs an interactive tool on the real terminal while the UI is suspended.
/// Mounts the kernel filesystems in a private namespace, so they disappear
/// with the shell, and points /run/current-system at the new generation.
const CHROOT_SCRIPT: &str = r#"set -e
root=$1
for directory in dev proc sys run; do mkdir -p "$root/$directory"; done
mount --rbind /dev "$root/dev"
mount -t proc proc "$root/proc"
mount --rbind /sys "$root/sys"
mount -t tmpfs -o mode=0755 tmpfs "$root/run"
ln -s /nix/var/nix/profiles/system "$root/run/current-system"
printf '\nYou are in the installed Runix system. Type exit to return to the installer.\n\n'
exec chroot "$root" /nix/var/nix/profiles/system/sw/bin/bash --login
"#;

fn run_external(external: &External) -> Result<(), String> {
    match external {
        External::EditPartitions(disk) => Command::new("cfdisk")
            .arg(disk)
            .status()
            .map(|_| ())
            .map_err(|error| format!("Could not open cfdisk: {error}")),
        // The shell's exit status is the user's last command, so only a
        // failure to start counts as an error.
        External::Chroot(root) => Command::new("unshare")
            .args(["--mount", "--propagation", "private", "bash", "-c", CHROOT_SCRIPT])
            .args(["runix-chroot", root])
            .status()
            .map(|_| ())
            .map_err(|error| format!("Could not open the chroot: {error}")),
    }
}

fn run(terminal: &mut DefaultTerminal, options: Options) -> io::Result<Exit> {
    let (sender, receiver) = channel();
    let mut app = App::new(options, sender);
    loop {
        terminal.draw(|frame| ui::draw(frame, &mut app))?;
        if event::poll(Duration::from_millis(100))? {
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press {
                    app.on_key(key);
                }
            }
        }
        while let Ok(message) = receiver.try_recv() {
            app.on_message(message);
        }
        if let Some(external) = app.external.take() {
            ratatui::restore();
            let result = run_external(&external);
            *terminal = ratatui::init();
            app.after_external(result);
        }
        app.tick();
        if let Some(exit) = app.exit.take() {
            return Ok(exit);
        }
    }
}

/// The Linux console's 16 colors, redefined around the Runix green. Other
/// terminals keep their own theme, since the UI only uses named colors.
const CONSOLE_PALETTE: [&str; 16] = [
    "0e1110", "e0574f", "00a35a", "d9a441", "4f8fd1", "b07fd1", "3fb5a5", "c8ccc6",
    "4d5450", "f0736a", "2fd07f", "f0c060", "74aef0", "cc9ef0", "66d6c6", "f1f3ef",
];

fn set_console_palette(enabled: bool) {
    if env::var("TERM").as_deref() != Ok("linux") {
        return;
    }
    let mut sequence = String::new();
    if enabled {
        for (index, color) in CONSOLE_PALETTE.iter().enumerate() {
            sequence.push_str(&format!("\x1b]P{index:X}{color}"));
        }
        // Repaint with the new background before the first frame.
        sequence.push_str("\x1b[2J");
    } else {
        sequence.push_str("\x1b]R");
    }
    let mut stdout = io::stdout();
    let _ = stdout.write_all(sequence.as_bytes());
    let _ = stdout.flush();
}

/// The ISO sets RUNIX_ZONEINFO; elsewhere, NixOS hosts use TZDIR or
/// /etc/zoneinfo and most other systems /usr/share/zoneinfo.
fn find_zoneinfo(candidates: &[Option<String>]) -> String {
    candidates
        .iter()
        .flatten()
        .find(|path| Path::new(path).join("UTC").exists())
        .cloned()
        .unwrap_or_else(|| "/usr/share/zoneinfo".to_string())
}

fn is_root() -> bool {
    fs::metadata("/proc/self").is_ok_and(|metadata| metadata.uid() == 0)
}

fn main() -> ExitCode {
    let mut demo = false;
    let mut demo_fail = false;
    for argument in env::args().skip(1) {
        match argument.as_str() {
            "--demo" => demo = true,
            "--demo-fail" => {
                demo = true;
                demo_fail = true;
            }
            "-h" | "--help" => {
                println!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            other => {
                eprintln!("runix-installer: unknown argument: {other}\n{USAGE}");
                return ExitCode::from(2);
            }
        }
    }
    if !demo && !is_root() {
        eprintln!("runix-installer: run this as root, or use --demo to try the interface");
        return ExitCode::FAILURE;
    }

    let options = Options {
        demo,
        demo_fail,
        flake: env::var("RUNIX_INSTALL_FLAKE")
            .unwrap_or_else(|_| "github:runix-community/runix".to_string()),
        zoneinfo: find_zoneinfo(&[
            env::var("RUNIX_ZONEINFO").ok(),
            env::var("TZDIR").ok(),
            Some("/usr/share/zoneinfo".to_string()),
            Some("/etc/zoneinfo".to_string()),
        ]),
    };

    set_console_palette(true);
    let mut terminal = ratatui::init();
    let result = run(&mut terminal, options);
    ratatui::restore();
    set_console_palette(false);

    let power_command = match result {
        Ok(Exit::Shell) => return ExitCode::SUCCESS,
        Ok(Exit::Reboot) => "reboot",
        Ok(Exit::Poweroff) => "poweroff",
        Err(error) => {
            eprintln!("runix-installer: {error}");
            return ExitCode::FAILURE;
        }
    };
    if demo {
        println!("demo: would run {power_command}");
        return ExitCode::SUCCESS;
    }
    let error = Command::new(format!("/run/current-system/bin/{power_command}")).exec();
    eprintln!("runix-installer: could not {power_command}: {error}");
    ExitCode::FAILURE
}

#[cfg(test)]
mod tests {
    use super::find_zoneinfo;

    #[test]
    fn missing_zoneinfo_directories_are_skipped() {
        let directory = std::env::temp_dir().join(format!("runix-zoneinfo-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join("UTC"), "").unwrap();
        let found = directory.to_string_lossy().into_owned();
        assert_eq!(
            find_zoneinfo(&[None, Some("/nonexistent".into()), Some(found.clone())]),
            found
        );
        std::fs::remove_dir_all(&directory).unwrap();
    }
}
