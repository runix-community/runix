set -euo pipefail
root=$1
installer=$2
mounted=()
cleanup() {
  for ((index=${#mounted[@]} - 1; index >= 0; index--)); do
    umount -R "${mounted[index]}" || true
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for directory in dev proc sys; do
  mkdir -p "$root/$directory"
done
mount --rbind /dev "$root/dev"
mount --make-rslave "$root/dev"
mounted+=("$root/dev")
mount -t proc proc "$root/proc"
mounted+=("$root/proc")
mount --rbind /sys "$root/sys"
mount --make-rslave "$root/sys"
mounted+=("$root/sys")

chroot "$root" "$installer" /
