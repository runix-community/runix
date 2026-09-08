set -euo pipefail
root=$1
system=$2
mounted=()
cleanup() {
  for ((index=${#mounted[@]} - 1; index >= 0; index--)); do
    umount -R "${mounted[index]}" || true
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Private mounts: no host runtime tree, writable sysctls, or raw disks.
for directory in run dev; do
  mkdir -p "$root/$directory"
  mount -t tmpfs -o mode=0755,nosuid tmpfs "$root/$directory"
  mounted+=("$root/$directory")
done
for device in null zero random urandom; do
  touch "$root/dev/$device"
  mount --bind "/dev/$device" "$root/dev/$device"
done
ln -s /proc/self/fd "$root/dev/fd"
ln -s /proc/self/fd/0 "$root/dev/stdin"
ln -s /proc/self/fd/1 "$root/dev/stdout"
ln -s /proc/self/fd/2 "$root/dev/stderr"
mkdir -p "$root/proc"
mount -t proc -o ro,nosuid,nodev,noexec proc "$root/proc"
mounted+=("$root/proc")
chroot "$root" "$system/activate" --offline
