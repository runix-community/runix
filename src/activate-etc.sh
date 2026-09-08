set -euo pipefail

source=$1
root=$2
preserve_fstab=$3
mkdir -p "$root/etc" "$root/var/lib/runix"
manifest="$root/var/lib/runix/etc-files"
discovered="$root/var/lib/runix/installer-fstab"
if [ ! -e "$manifest" ] && [ -f "$root/etc/fstab" ] && [ ! -e "$discovered" ]; then
  cp "$root/etc/fstab" "$discovered"
fi
next=$(mktemp "$root/var/lib/runix/etc-files.XXXXXX")
trap 'rm -f "$next"' EXIT

# Only generated leaf files belong to Runix; never recursively remove /etc.
while IFS= read -r -d '' file; do
  relative=${file#"$source/"}
  if [ "$relative" = fstab ] && [ "$preserve_fstab" = 1 ] && [ -e "$root/etc/fstab" ]; then
    continue
  fi
  destination="$root/etc/$relative"
  mkdir -p "${destination%/*}"
  temporary=$(mktemp "${destination%/*}/.runix.XXXXXX")
  cp -a --remove-destination "$file" "$temporary"
  if [ "$relative" = fstab ] && [ -f "$discovered" ]; then
    chmod u+w "$temporary"
    declare -A declared_mounts=()
    while read -r device mount_point _; do
      [ -n "$mount_point" ] || continue
      declared_mounts["$mount_point"]=1
    done < "$file"
    # Preserve installer mounts, not removed declarative entries.
    while IFS= read -r line; do
      read -r device mount_point _ <<< "$line"
      case "$device" in ''|\#*) continue ;; esac
      [ -n "$mount_point" ] || continue
      if [ -z "${declared_mounts[$mount_point]-}" ]; then
        printf '%s\n' "$line" >> "$temporary"
      fi
    done < "$discovered"
  fi
  if [ ! -L "$temporary" ]; then
    case "$relative" in
      shadow|gshadow) chmod 0600 "$temporary" ;;
      runit/stopit|runit/reboot) chmod 0000 "$temporary" ;;
      *) chmod u+w "$temporary" ;;
    esac
  fi
  mv -fT "$temporary" "$destination"
  printf '%s\n' "$relative" >> "$next"
done < <(find "$source" -type f -print0 -o -type l -print0)

if [ -f "$manifest" ]; then
  while IFS= read -r relative; do
    case "$relative" in
      ''|/*|..|../*|*/../*|*/..) exit 1 ;;
      fstab) [ "$preserve_fstab" != 1 ] || continue ;;
    esac
    if ! grep -Fxq -- "$relative" "$next"; then
      rm -f -- "$root/etc/$relative"
    fi
  done < "$manifest"
fi
mv -f "$next" "$manifest"
