set -euo pipefail
root=$1
spec=$2
bootloader=$3
activate=$4

die() { printf 'runix-install: %s\n' "$*" >&2; exit 2; }
target_path() {
  local target
  target=$(readlink -m "$root$1")
  case "$target" in "$root"|"$root"/*) printf '%s\n' "$target" ;; *) die "path escapes installation root: $1" ;; esac
}

mountpoint -q "$root" || die "target root is not mounted: $root"
[ "$(stat -Lc '%d:%i' "$root")" != "$(stat -Lc '%d:%i' /)" ] || die "target is an alias of the running root"
[ -r "$spec" ] || die "system has no installation specification"
jq -e '.system and .fileSystems and .bootLoader and .passwordHashFiles' "$spec" >/dev/null || die "invalid installation specification"
for path in /etc /etc/fstab /nix /run /dev /proc /sys /var /home /usr /lib; do
  target_path "$path" >/dev/null
done
if [ -d "$root/nix" ] && [ -d /nix ]; then
  [ "$(stat -Lc '%d:%i' "$root/nix")" != "$(stat -Lc '%d:%i' /nix)" ] || die "target /nix is an alias of the live Nix store hierarchy"
fi
case "$(uname -m):$(jq -r .system "$spec")" in
  x86_64:x86_64-linux|aarch64:aarch64-linux) ;;
  *) die "target architecture must match the installation environment" ;;
esac

while IFS= read -r entry; do
  mount_point=$(jq -r .key <<< "$entry")
  type=$(jq -r .value.fsType <<< "$entry")
  case "$type" in tmpfs|proc|sysfs|devtmpfs|devpts|cgroup2|swap) continue ;; esac
  if jq -e '(.value.options | index("noauto") != null) and (.value.neededForBoot | not)' <<< "$entry" >/dev/null; then continue; fi
  target=$(target_path "$mount_point")
  mountpoint -q "$target" || die "mount configured filesystem $mount_point before installation"
  actual=$(findmnt --json --mountpoint "$target" -o SOURCE,FSTYPE,UUID,LABEL,PARTUUID,PARTLABEL,FSROOT)
  actual_type=$(jq -r '.filesystems[0].fstype' <<< "$actual")
  [ "$type" = auto ] || [ "$type" = "$actual_type" ] || die "filesystem type mismatch at $mount_point: expected $type, got $actual_type"
  expected=$(jq -r .value.device <<< "$entry")
  source=$(jq -r '.filesystems[0].source' <<< "$actual")
  case "$expected" in
    UUID=*) source="UUID=$(jq -r '.filesystems[0].uuid' <<< "$actual")" ;;
    LABEL=*) source="LABEL=$(jq -r '.filesystems[0].label' <<< "$actual")" ;;
    PARTUUID=*) source="PARTUUID=$(jq -r '.filesystems[0].partuuid' <<< "$actual")" ;;
    PARTLABEL=*) source="PARTLABEL=$(jq -r '.filesystems[0].partlabel' <<< "$actual")" ;;
    /dev/*) expected=$(readlink -f "$expected"); source=$(readlink -f "${source%%\[*}") ;;
  esac
  [ "$expected" = "$source" ] || die "device mismatch at $mount_point: expected $expected, got $source"
  while IFS= read -r subvolume; do
    actual_subvolume=$(jq -r '.filesystems[0].fsroot' <<< "$actual")
    [ "/${subvolume#/}" = "$actual_subvolume" ] || die "Btrfs subvolume mismatch at $mount_point"
  done < <(jq -r '.value.options[] | select(startswith("subvol=")) | ltrimstr("subvol=")' <<< "$entry")
done < <(jq -c '.fileSystems | to_entries[]' "$spec")

for mount_point in /nix /nix/store; do
  target=$(target_path "$mount_point")
  if mountpoint -q "$target"; then
    jq -e --arg path "$mount_point" '.fileSystems[$path].neededForBoot == true' "$spec" >/dev/null ||
      die "separate $mount_point requires fileSystems.\"$mount_point\".neededForBoot = true"
  fi
done

if [ "$bootloader" = 1 ]; then
  jq -e '.bootLoader.enabled' "$spec" >/dev/null || die "enable a bootloader in the configuration or pass --no-bootloader"
  boot=$(target_path "$(jq -r .bootLoader.mountPoint "$spec")")
  if [ "$(jq -r .bootLoader.mode "$spec")" = efi ]; then
    mountpoint -q "$boot" || die "mount the EFI system partition at $boot"
    [ "$(findmnt -n -o FSTYPE --mountpoint "$boot")" = vfat ] || die "EFI system partition must be FAT (vfat): $boot"
  fi
fi

if [ "$activate" = 1 ]; then
  while IFS= read -r path; do
    target=$(target_path "$path")
    [ -f "$target" ] && [ -r "$target" ] || die "provision password hash file before installation: $target"
    [ "$(stat -Lc %u "$target")" = 0 ] || die "password hash file must be owned by root: $target"
    mode=$(stat -Lc %a "$target")
    (( (8#$mode & 077) == 0 )) || die "password hash file must not be accessible by group or others: $target"
    hash=$(< "$target")
    case "$hash" in ''|*:*|*$'\n'*) die "invalid password hash file: $target" ;; esac
  done < <(jq -r '.passwordHashFiles[]' "$spec")
fi

printf 'runix-install: target matches the installation specification\n'
