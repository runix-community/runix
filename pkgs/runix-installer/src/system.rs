//! Read-only probes of the live machine, plus Wi-Fi through runix-network.
//! Every function takes `demo` so `--demo` never touches real hardware.

use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};

use serde_json::Value;

use crate::config::{BootMode, Cpu};

pub const MINIMUM_DISK_BYTES: u64 = 16 * 1024 * 1024 * 1024;
const LIVE_MOUNT: &str = "/run/runix-live/iso";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Disk {
    pub path: String,
    pub size: u64,
    pub model: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Partition {
    pub path: String,
    pub size: u64,
    pub fstype: Option<String>,
    pub kind: Option<String>,
    pub mounted: bool,
}

impl Partition {
    pub fn is_vfat(&self) -> bool {
        self.fstype.as_deref() == Some("vfat")
    }

    pub fn is_bios_boot(&self) -> bool {
        self.kind.as_deref().is_some_and(|kind| kind.contains("BIOS boot"))
    }

    fn is_efi_system(&self) -> bool {
        self.is_vfat()
            && self
                .kind
                .as_deref()
                .is_some_and(|kind| kind.contains("EFI"))
    }
}

/// The partition a manual layout most likely boots from: an existing ESP.
pub fn existing_esp(partitions: &[Partition]) -> Option<&Partition> {
    partitions.iter().find(|partition| partition.is_efi_system())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WifiNetwork {
    pub ssid: String,
    pub secured: bool,
}

pub fn format_size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit + 1 < UNITS.len() {
        value /= 1024.0;
        unit += 1;
    }
    format!("{value:.1} {}", UNITS[unit])
}

fn stdout_of(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

/// lsblk prints sizes as numbers or strings depending on its version.
fn json_size(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
}

pub fn parse_disks(json: &str, live_disk: Option<&str>) -> Vec<Disk> {
    let Ok(root) = serde_json::from_str::<Value>(json) else {
        return Vec::new();
    };
    let Some(devices) = root["blockdevices"].as_array() else {
        return Vec::new();
    };
    devices
        .iter()
        .filter(|device| device["type"] == "disk" && device["ro"] != Value::Bool(true))
        .filter_map(|device| {
            let path = device["name"].as_str()?.to_string();
            let size = json_size(&device["size"])?;
            let model = device["model"]
                .as_str()
                .map_or("Unknown disk", str::trim)
                .to_string();
            Some(Disk { path, size, model })
        })
        .filter(|disk| disk.size >= MINIMUM_DISK_BYTES && Some(disk.path.as_str()) != live_disk)
        .collect()
}

/// The disk holding the running ISO must never be offered for erasing.
fn live_disk() -> Option<String> {
    let source = stdout_of("findmnt", &["-no", "SOURCE", LIVE_MOUNT])?;
    let source = source.trim();
    let parent = stdout_of("lsblk", &["-ndo", "PKNAME", source]).unwrap_or_default();
    let parent = parent.trim();
    let name = if parent.is_empty() {
        source.rsplit('/').next()?
    } else {
        parent
    };
    Some(format!("/dev/{name}"))
}

pub fn disks(demo: bool) -> Vec<Disk> {
    if demo {
        return vec![
            Disk {
                path: "/dev/nvme0n1".into(),
                size: 512 * 1024 * 1024 * 1024,
                model: "Demo NVMe SSD".into(),
            },
            Disk {
                path: "/dev/sda".into(),
                size: 2048 * 1024 * 1024 * 1024,
                model: "Demo SATA Disk".into(),
            },
        ];
    }
    let live = live_disk();
    stdout_of("lsblk", &["-Jbdpo", "NAME,SIZE,TYPE,RO,MODEL"])
        .map(|json| parse_disks(&json, live.as_deref()))
        .unwrap_or_default()
}

pub fn parse_partitions(json: &str) -> Vec<Partition> {
    let Ok(root) = serde_json::from_str::<Value>(json) else {
        return Vec::new();
    };
    let Some(children) = root["blockdevices"][0]["children"].as_array() else {
        return Vec::new();
    };
    children
        .iter()
        .filter(|child| child["type"] == "part")
        .filter_map(|child| {
            let text = |key: &str| child[key].as_str().map(str::to_string);
            Some(Partition {
                path: text("name")?,
                size: json_size(&child["size"])?,
                fstype: text("fstype"),
                kind: text("parttypename"),
                mounted: child["mountpoint"].is_string(),
            })
        })
        .collect()
}

pub fn partitions(demo: bool, disk: &str) -> Vec<Partition> {
    if demo {
        const GIB: u64 = 1024 * 1024 * 1024;
        let part = |number: u32, size: u64, fstype: &str, kind: &str| Partition {
            path: crate::install::partition_path(disk, number),
            size,
            fstype: Some(fstype.to_string()),
            kind: Some(kind.to_string()),
            mounted: false,
        };
        return vec![
            part(1, GIB / 2, "vfat", "EFI System"),
            part(2, 200 * GIB, "ntfs", "Microsoft basic data"),
            part(3, 120 * GIB, "ext4", "Linux filesystem"),
        ];
    }
    stdout_of(
        "lsblk",
        &["-Jbpo", "NAME,SIZE,TYPE,FSTYPE,PARTTYPENAME,MOUNTPOINT", disk],
    )
    .map(|json| parse_partitions(&json))
    .unwrap_or_default()
}

pub fn online(demo: bool) -> bool {
    if demo {
        return false;
    }
    Command::new("curl")
        .args([
            "-fsS",
            "--max-time",
            "5",
            "https://cache.nixos.org/nix-cache-info",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

pub fn wireless_available(demo: bool) -> bool {
    if demo {
        return true;
    }
    fs::read_dir("/sys/class/net").is_ok_and(|entries| {
        entries
            .flatten()
            .any(|entry| entry.path().join("wireless").is_dir())
    })
}

pub fn parse_scan(output: &str) -> Vec<WifiNetwork> {
    let mut networks: Vec<WifiNetwork> = Vec::new();
    for line in output.lines() {
        let fields: Vec<&str> = line.splitn(5, '\t').collect();
        let [bssid, _, _, flags, ssid] = fields[..] else {
            continue;
        };
        if ssid.is_empty() || !bssid.contains(':') {
            continue;
        }
        let secured = flags.contains("WPA") || flags.contains("SAE");
        match networks.iter_mut().find(|network| network.ssid == ssid) {
            Some(network) => network.secured |= secured,
            None => networks.push(WifiNetwork {
                ssid: ssid.to_string(),
                secured,
            }),
        }
    }
    networks
}

pub fn scan(demo: bool) -> Vec<WifiNetwork> {
    if demo {
        return vec![
            WifiNetwork {
                ssid: "Demo Home".into(),
                secured: true,
            },
            WifiNetwork {
                ssid: "Demo Cafe".into(),
                secured: false,
            },
        ];
    }
    stdout_of("runix-network", &["scan"])
        .map(|output| parse_scan(&output))
        .unwrap_or_default()
}

pub fn connect(demo: bool, ssid: &str, password: Option<&str>) -> Result<(), String> {
    if demo {
        std::thread::sleep(std::time::Duration::from_secs(1));
        return Ok(());
    }
    let mut command = Command::new("runix-network");
    command.arg("connect").arg(ssid);
    if let Some(password) = password {
        command.arg(password);
    }
    let output = command
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("could not run runix-network: {error}"))?;
    if output.status.success() {
        return Ok(());
    }
    let message = String::from_utf8_lossy(&output.stderr);
    Err(message.trim().lines().last().unwrap_or("connection failed").to_string())
}

fn walk_zones(directory: &Path, prefix: &str, zones: &mut Vec<String>) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let zone = format!("{prefix}/{name}");
        let path = entry.path();
        if path.is_dir() {
            walk_zones(&path, &zone, zones);
        } else {
            zones.push(zone);
        }
    }
}

pub fn timezones(zoneinfo: &str) -> Vec<String> {
    const REGIONS: [&str; 9] = [
        "Africa",
        "America",
        "Antarctica",
        "Asia",
        "Atlantic",
        "Australia",
        "Europe",
        "Indian",
        "Pacific",
    ];
    let mut zones = Vec::new();
    for region in REGIONS {
        walk_zones(&Path::new(zoneinfo).join(region), region, &mut zones);
    }
    zones.sort();
    zones.insert(0, "UTC".to_string());
    zones
}

pub fn boot_mode() -> BootMode {
    if Path::new("/sys/firmware/efi").is_dir() {
        BootMode::Efi
    } else {
        BootMode::Bios
    }
}

pub fn cpu_vendor() -> Cpu {
    let info = fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
    let vendor = info.lines().find(|line| line.starts_with("vendor_id"));
    match vendor {
        Some(line) if line.contains("AuthenticAMD") => Cpu::Amd,
        Some(line) if line.contains("GenuineIntel") => Cpu::Intel,
        _ => Cpu::Other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LSBLK: &str = r#"{"blockdevices": [
      {"name": "/dev/sda", "size": 512110190592, "type": "disk", "ro": false, "model": "Samsung SSD "},
      {"name": "/dev/sdb", "size": "32000000000", "type": "disk", "ro": false, "model": null},
      {"name": "/dev/sdc", "size": 8000000000, "type": "disk", "ro": false, "model": "Too small"},
      {"name": "/dev/sdd", "size": 512110190592, "type": "disk", "ro": true, "model": "Read only"},
      {"name": "/dev/sr0", "size": 512110190592, "type": "rom", "ro": false, "model": "CD"}
    ]}"#;

    #[test]
    fn only_usable_disks_are_offered() {
        let disks = parse_disks(LSBLK, None);
        let paths: Vec<_> = disks.iter().map(|disk| disk.path.as_str()).collect();
        assert_eq!(paths, ["/dev/sda", "/dev/sdb"]);
        assert_eq!(disks[0].model, "Samsung SSD");
        assert_eq!(disks[1].model, "Unknown disk");
    }

    #[test]
    fn the_live_medium_is_never_offered() {
        let disks = parse_disks(LSBLK, Some("/dev/sda"));
        assert!(disks.iter().all(|disk| disk.path != "/dev/sda"));
    }

    #[test]
    fn broken_lsblk_output_gives_no_disks() {
        assert!(parse_disks("not json", None).is_empty());
    }

    #[test]
    fn scan_results_are_merged_by_name() {
        let output = "bssid / frequency / signal level / flags / ssid\n\
            aa:bb:cc:dd:ee:01\t2412\t-40\t[WPA2-PSK-CCMP][ESS]\tHome Net\n\
            aa:bb:cc:dd:ee:02\t5180\t-60\t[ESS]\tHome Net\n\
            aa:bb:cc:dd:ee:03\t2437\t-70\t[ESS]\tCafe\n\
            aa:bb:cc:dd:ee:04\t2437\t-80\t[ESS]\t\n";
        assert_eq!(
            parse_scan(output),
            [
                WifiNetwork {
                    ssid: "Home Net".into(),
                    secured: true
                },
                WifiNetwork {
                    ssid: "Cafe".into(),
                    secured: false
                },
            ]
        );
    }

    #[test]
    fn partitions_are_read_from_lsblk() {
        let json = r#"{"blockdevices": [{"name": "/dev/sda", "size": 512110190592, "type": "disk",
          "fstype": null, "parttypename": null, "mountpoint": null, "children": [
            {"name": "/dev/sda1", "size": 536870912, "type": "part", "fstype": "vfat",
             "parttypename": "EFI System", "mountpoint": null},
            {"name": "/dev/sda2", "size": "100000000000", "type": "part", "fstype": null,
             "parttypename": "Linux filesystem", "mountpoint": "/home"}
        ]}]}"#;
        let partitions = parse_partitions(json);
        assert_eq!(partitions.len(), 2);
        assert_eq!(existing_esp(&partitions).map(|p| p.path.as_str()), Some("/dev/sda1"));
        assert!(!partitions[0].mounted);
        assert!(partitions[1].mounted);
        assert_eq!(partitions[1].fstype, None);
        assert!(parse_partitions("not json").is_empty());
    }

    #[test]
    fn sizes_are_readable() {
        assert_eq!(format_size(512 * 1024 * 1024 * 1024), "512.0 GiB");
    }
}
