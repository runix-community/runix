set -euo pipefail
script=${1:-src/activate-etc.sh}
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
source="$temporary/source"
root="$temporary/root"
mkdir -p "$source/runit" "$root/etc/runix" "$root/etc/NetworkManager/system-connections"
printf 'configuration\n' > "$root/etc/runix/flake.nix"
printf 'credentials\n' > "$root/etc/NetworkManager/system-connections/home"
printf 'discovered\n' > "$root/etc/fstab"
printf 'declared\n' > "$source/fstab"
printf 'root:!\n' > "$source/shadow"
printf 'old\n' > "$source/obsolete"
touch "$source/runit/stopit"
ln -s /nix/store/example "$source/runit/1"
bash "$script" "$source" "$root" 1
test "$(stat -c %a "$root/etc/shadow")" = 600
test "$(stat -c %a "$root/etc/runit/stopit")" = 0
test "$(readlink "$root/etc/runit/1")" = /nix/store/example
test "$(< "$root/etc/fstab")" = discovered
rm "$source/obsolete"
printf 'new\n' > "$source/hostname"
bash "$script" "$source" "$root" 0
test ! -e "$root/etc/obsolete"
test "$(< "$root/etc/fstab")" = declared
test "$(< "$root/etc/hostname")" = new
test "$(< "$root/etc/runix/flake.nix")" = configuration
test "$(< "$root/etc/NetworkManager/system-connections/home")" = credentials
bash "$script" "$source" "$root" 0
other="$temporary/with-esp"
mkdir -p "$other/etc"
printf 'UUID=root / ext4 defaults 0 1\nUUID=esp /boot vfat defaults 0 2\n' > "$other/etc/fstab"
printf 'rpool/root / zfs defaults 0 0\n' > "$source/fstab"
bash "$script" "$source" "$other" 0
grep -Fxq 'rpool/root / zfs defaults 0 0' "$other/etc/fstab"
grep -Fxq 'UUID=esp /boot vfat defaults 0 2' "$other/etc/fstab"
test "$(wc -l < "$other/etc/fstab")" = 2
printf 'Activation file preservation tests passed\n'
