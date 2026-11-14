//! Renders the flake written to /etc/runix. Callers validate every value with
//! `valid_host` and `valid_user`, or take it from a fixed list, so nothing here
//! needs Nix string escaping.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Filesystem {
    Ext4,
    Btrfs,
}

impl Filesystem {
    pub const ALL: [Self; 2] = [Self::Ext4, Self::Btrfs];

    pub fn name(self) -> &'static str {
        match self {
            Self::Ext4 => "ext4",
            Self::Btrfs => "btrfs",
        }
    }

    pub fn description(self) -> &'static str {
        match self {
            Self::Ext4 => "Simple and reliable",
            Self::Btrfs => "Checksums and compression support",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Desktop {
    None,
    Hyprland,
    Labwc,
    Niri,
    Zwwm,
    Shojiwm,
    Driftwm,
}

impl Desktop {
    pub const ALL: [Self; 7] = [
        Self::None,
        Self::Hyprland,
        Self::Labwc,
        Self::Niri,
        Self::Zwwm,
        Self::Shojiwm,
        Self::Driftwm,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Self::None => "Console only",
            Self::Hyprland => "Hyprland",
            Self::Labwc => "Labwc",
            Self::Niri => "Niri",
            Self::Zwwm => "zwwm",
            Self::Shojiwm => "ShojiWM",
            Self::Driftwm => "driftwm",
        }
    }

    fn program(self) -> Option<&'static str> {
        match self {
            Self::None | Self::Hyprland => None,
            Self::Labwc => Some("labwc"),
            Self::Niri => Some("niri"),
            Self::Zwwm => Some("zwwm"),
            Self::Shojiwm => Some("shojiwm"),
            Self::Driftwm => Some("driftwm"),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Network {
    Wifi,
    Dhcpcd,
}

impl Network {
    pub const ALL: [Self; 2] = [Self::Wifi, Self::Dhcpcd];

    pub fn name(self) -> &'static str {
        match self {
            Self::Wifi => "Wi-Fi with runix-network",
            Self::Dhcpcd => "Wired with dhcpcd",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BootMode {
    Bios,
    Efi,
}

impl BootMode {
    pub fn name(self) -> &'static str {
        match self {
            Self::Bios => "bios",
            Self::Efi => "efi",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BootLoader {
    Limine,
    Grub,
}

impl BootLoader {
    pub const ALL: [Self; 2] = [Self::Limine, Self::Grub];

    pub fn name(self) -> &'static str {
        match self {
            Self::Limine => "Limine",
            Self::Grub => "GRUB",
        }
    }

    pub fn description(self) -> &'static str {
        match self {
            Self::Limine => "small and fast, with a simple menu",
            Self::Grub => "the most widely used, with the broadest hardware support",
        }
    }

    fn option(self) -> &'static str {
        match self {
            Self::Limine => "limine",
            Self::Grub => "grub",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cpu {
    Amd,
    Intel,
    Other,
}

#[derive(Clone, Debug)]
pub struct Settings {
    pub flake: String,
    pub host: String,
    pub user: String,
    pub timezone: String,
    pub desktop: Desktop,
    pub network: Network,
    pub root_uuid: String,
    pub root_fs: Filesystem,
    pub boot_uuid: String,
    pub boot_mode: BootMode,
    pub loader: BootLoader,
    pub disk: String,
    pub cpu: Cpu,
}

pub fn valid_host(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 63
        && value.starts_with(|c: char| c.is_ascii_alphanumeric())
        && value.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

pub fn valid_user(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 32
        && value != "root"
        && value.starts_with(|c: char| c.is_ascii_lowercase() || c == '_')
        && value
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

pub fn password_hash_path(user: &str) -> String {
    format!("/var/lib/runix/secrets/{user}.hash")
}

pub fn flake(settings: &Settings) -> String {
    format!(
        r#"{{
  description = "Runix configuration for {host}";

  nixConfig = {{
    extra-substituters = [ "https://runix-community.cachix.org" ];
    extra-trusted-public-keys = [
      "runix-community.cachix.org-1:sENfG2mPWobsz1MKahUs+HOGfVt2L3OvG5oHHD5/coE="
    ];
  }};

  inputs.runix.url = "{flake}";

  outputs =
    {{ runix, ... }}:
    {{
      runixConfigurations.{host} = runix.lib.runixSystem {{
        system = "x86_64-linux";
        modules = [
          ./hardware.nix
          ./configuration.nix
        ];
      }};
    }};
}}
"#,
        host = settings.host,
        flake = settings.flake,
    )
}

pub fn hardware(settings: &Settings) -> String {
    let microcode = match settings.cpu {
        Cpu::Amd => "  hardware.cpu.amd.updateMicrocode = true;\n",
        Cpu::Intel => "  hardware.cpu.intel.updateMicrocode = true;\n",
        Cpu::Other => "",
    };
    let device = match settings.boot_mode {
        BootMode::Bios => format!("    device = \"{}\";\n", settings.disk),
        BootMode::Efi => String::new(),
    };
    format!(
        r#"# Generated by runix-installer for this machine.
{{
  fileSystems = {{
    "/" = {{
      device = "UUID={root_uuid}";
      fsType = "{root_fs}";
    }};
    "/boot" = {{
      device = "UUID={boot_uuid}";
      fsType = "vfat";
    }};
  }};

  runix.initrd = {{
    modules = [
      "ahci"
      "nvme"
      "sd_mod"
      "uas"
      "usb_storage"
      "virtio_blk"
      "virtio_pci"
      "virtio_scsi"
      "xhci_pci"
    ];
    loadModules = [
      "ahci"
      "nvme"
      "sd_mod"
      "virtio_blk"
      "virtio_pci"
      "virtio_scsi"
    ];
  }};

  hardware.enableRedistributableFirmware = true;
{microcode}  runix.boot.loader.{loader} = {{
    enable = true;
    mode = "{mode}";
{device}  }};
}}
"#,
        root_uuid = settings.root_uuid,
        root_fs = settings.root_fs.name(),
        boot_uuid = settings.boot_uuid,
        mode = settings.boot_mode.name(),
        loader = settings.loader.option(),
    )
}

pub fn configuration(settings: &Settings) -> String {
    let network = match settings.network {
        Network::Wifi => "  runix.systemServices.wifi.enable = true;\n",
        Network::Dhcpcd => "  runix.systemServices.dhcpcd.enable = true;\n",
    };
    let desktop = match (settings.desktop, settings.desktop.program()) {
        (Desktop::None, _) => String::new(),
        (_, None) => "  runix.desktop.enable = true;\n".to_string(),
        (_, Some(program)) => format!(
            "  runix.desktop.enable = true;\n  programs.hyprland.enable = false;\n  programs.{program}.enable = true;\n"
        ),
    };
    format!(
        r#"{{ pkgs, ... }}:
{{
  runix.hostName = "{host}";
  time.timeZone = "{timezone}";

  runix.groups.wheel.gid = 1;
  runix.users.{user} = {{
    uid = 1000;
    gid = 100;
    passwordHashFile = "{hash}";
    extraGroups = [
      "wheel"
      "audio"
      "input"
      "render"
      "video"
    ];
  }};

  programs.sudo.enable = true;
  runix.services.getty.command = "${{pkgs.busybox}}/bin/getty 38400 tty1";

{network}{desktop}}}
"#,
        host = settings.host,
        timezone = settings.timezone,
        user = settings.user,
        hash = password_hash_path(&settings.user),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings() -> Settings {
        Settings {
            flake: "github:runix-community/runix".into(),
            host: "testhost".into(),
            user: "alice".into(),
            timezone: "Europe/Paris".into(),
            desktop: Desktop::None,
            network: Network::Wifi,
            root_uuid: "1111-root".into(),
            root_fs: Filesystem::Ext4,
            boot_uuid: "ABCD-1234".into(),
            boot_mode: BootMode::Efi,
            loader: BootLoader::Limine,
            disk: "/dev/sda".into(),
            cpu: Cpu::Amd,
        }
    }

    #[test]
    fn efi_hardware_has_no_install_device() {
        let text = hardware(&settings());
        assert!(text.contains("mode = \"efi\";"));
        assert!(!text.contains("/dev/sda"));
        assert!(text.contains("device = \"UUID=ABCD-1234\";"));
        assert!(text.contains("hardware.cpu.amd.updateMicrocode = true;"));
    }

    #[test]
    fn bios_hardware_names_the_install_device() {
        let text = hardware(&Settings {
            boot_mode: BootMode::Bios,
            cpu: Cpu::Other,
            ..settings()
        });
        assert!(text.contains("mode = \"bios\";"));
        assert!(text.contains("device = \"/dev/sda\";"));
        assert!(!text.contains("updateMicrocode"));
    }

    #[test]
    fn the_chosen_boot_loader_is_enabled() {
        let text = hardware(&settings());
        assert!(text.contains("runix.boot.loader.limine = {"));
        let text = hardware(&Settings {
            loader: BootLoader::Grub,
            boot_mode: BootMode::Bios,
            ..settings()
        });
        assert!(text.contains("runix.boot.loader.grub = {"));
        assert!(!text.contains("limine"));
        assert!(text.contains("mode = \"bios\";"));
        assert!(text.contains("device = \"/dev/sda\";"));
    }

    #[test]
    fn flake_exposes_the_host() {
        let text = flake(&settings());
        assert!(text.contains("runixConfigurations.testhost"));
        assert!(text.contains("inputs.runix.url = \"github:runix-community/runix\";"));
    }

    #[test]
    fn configuration_uses_runix_networking() {
        let text = configuration(&settings());
        assert!(text.contains("runix.systemServices.wifi.enable = true;"));
        assert!(!text.contains("networkManager"));
        assert!(!text.contains("runix.desktop.enable"));
        assert!(text.contains("passwordHashFile = \"/var/lib/runix/secrets/alice.hash\";"));
        assert!(text.contains("${pkgs.busybox}/bin/getty"));
    }

    #[test]
    fn other_compositors_replace_hyprland() {
        let text = configuration(&Settings {
            desktop: Desktop::Niri,
            network: Network::Dhcpcd,
            ..settings()
        });
        assert!(text.contains("programs.hyprland.enable = false;"));
        assert!(text.contains("programs.niri.enable = true;"));
        assert!(text.contains("runix.systemServices.dhcpcd.enable = true;"));
    }

    #[test]
    fn hyprland_uses_the_desktop_default() {
        let text = configuration(&Settings {
            desktop: Desktop::Hyprland,
            ..settings()
        });
        assert!(text.contains("runix.desktop.enable = true;"));
        assert!(!text.contains("programs.hyprland.enable"));
    }

    #[test]
    fn names_that_could_break_nix_are_rejected() {
        assert!(valid_host("my-host1"));
        assert!(!valid_host(""));
        assert!(!valid_host("-host"));
        assert!(!valid_host("a\"b"));
        assert!(!valid_host("host.name"));
        assert!(valid_user("alice_1"));
        assert!(!valid_user("root"));
        assert!(!valid_user("Alice"));
        assert!(!valid_user("1alice"));
        assert!(!valid_user("a b"));
    }
}
