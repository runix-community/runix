# runix-mirrors: keeps Nix downloading when cache.nixos.org is blocked or
# throttled, as it is in some countries.
#
# It downloads a little of a real store path from cache.nixos.org. If that is
# slower than RUNIX_MIN_SPEED, it tries the mirrors in RUNIX_MIRRORS and writes
# the ones that do better, fastest first, to /run/nix/mirrors.conf, which
# nix.conf includes. Mirrors serve the same files signed by cache.nixos.org,
# so Nix still checks every download against cache.nixos.org's key; a mirror
# cannot change what you install.
#
# A proxy comes from RUNIX_PROXY or the runix.proxy=URL kernel parameter.

upstream=${RUNIX_UPSTREAM:-https://cache.nixos.org}
out=${RUNIX_MIRRORS_FILE:-/run/nix/mirrors.conf}
# The working mirrors, fastest first, for `run` to go through.
list_file=${out%.conf}.list
min_speed=${RUNIX_MIN_SPEED:-262144}
interval=${RUNIX_INTERVAL:-21600}

usage() {
  cat <<EOF
Usage: runix-mirrors COMMAND

  probe          test cache.nixos.org and the mirrors, write $out
  watch          probe now and again every ${interval}s, restarting nix-daemon on a change
  status         show what Nix uses now
  run CMD...     run a Nix command; if a download fails, retry it with the
                 next mirror, until one works or all have failed
  exec CMD...    run CMD with the proxy set, if there is one
EOF
}

load_proxy() {
  local proxy=${RUNIX_PROXY:-} word words
  if [ -z "$proxy" ] && [ -r /proc/cmdline ]; then
    read -ra words </proc/cmdline
    for word in "${words[@]}"; do
      case $word in runix.proxy=*) proxy=${word#runix.proxy=} ;; esac
    done
  fi
  if [ -n "$proxy" ]; then
    export http_proxy=$proxy https_proxy=$proxy HTTP_PROXY=$proxy HTTPS_PROXY=$proxy
  fi
}

human() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1048576) printf "%.1f MB/s", b / 1048576
    else if (b >= 1024) printf "%d KB/s", b / 1024
    else printf "%d B/s", b }'
}

# Prints a cache's download speed in bytes per second, 0 when it answers but
# barely moves data, or nothing when it cannot be reached.
speed() {
  local cache=$1 sample hash narinfo url status code
  # Nix asks for many paths a cache does not have. A cache must say so at
  # once (404); one that hangs instead makes every such query a timeout, and
  # the install fails.
  # Some hang only now and then, so ask three times.
  if [ "$cache" != "$upstream" ]; then
    for hash in 00000000000000000000000000000000 11111111111111111111111111111111 22222222222222222222222222222222; do
      code=$(curl -sS -o /dev/null --connect-timeout 3 --max-time 3 -w '%{http_code}' \
        "$cache/$hash.narinfo" 2>/dev/null)
      if [ "$code" != 404 ]; then return; fi
    done
  fi
  for sample in ${RUNIX_SAMPLES:-}; do
    hash=${sample#/nix/store/}
    hash=${hash%%-*}
    narinfo=$(curl -fsSL --connect-timeout 5 --max-time 10 "$cache/$hash.narinfo" 2>/dev/null)
    status=$?
    # 22 is an HTTP error such as 404: try another path. Anything else means
    # the cache itself is unreachable.
    if [ "$status" -eq 22 ]; then continue; fi
    if [ "$status" -ne 0 ]; then return; fi
    url=$(printf '%s\n' "$narinfo" | sed -n 's/^URL: //p')
    [ -n "$url" ] || continue
    curl -fsL -o /dev/null --connect-timeout 5 --max-time 10 --range 0-2097151 \
      -w '%{size_download} %{time_total}\n' "$cache/$url" 2>/dev/null |
      awk '{ if ($2 > 0) printf "%d\n", $1 / $2; else print 0 }'
    return
  done
  # None of the sample paths is in this cache; at least see that it answers.
  if curl -fsS --connect-timeout 5 --max-time 10 -o /dev/null "$cache/nix-cache-info" 2>/dev/null; then
    echo "$min_speed"
  fi
}

write() {
  mkdir -p "$(dirname "$out")"
  printf '%s' "$1" >"$out.tmp" && mv -f "$out.tmp" "$out"
}

probe() {
  local base ranked mirror s list priority=10
  base=$(speed "$upstream")
  rm -f "$list_file"
  if [ -n "$base" ] && [ "$base" -ge "$min_speed" ]; then
    echo "cache.nixos.org: $(human "$base"), no mirror needed"
    write "# cache.nixos.org works ($(human "$base")); written by runix-mirrors.
"
    return 0
  fi
  if [ -z "$base" ]; then
    echo "cache.nixos.org: unreachable, trying mirrors"
  else
    echo "cache.nixos.org: $(human "$base"), trying mirrors"
  fi

  ranked=$(
    for mirror in ${RUNIX_MIRRORS:-}; do
      s=$(speed "$mirror")
      if [ -n "$s" ] && [ "$s" -gt "${base:-0}" ]; then
        echo "  $mirror: $(human "$s")" >&2
        echo "$s $mirror"
      elif [ -n "$s" ]; then
        echo "  $mirror: $(human "$s"), not faster" >&2
      else
        echo "  $mirror: unreachable" >&2
      fi
    done | sort -rn
  )

  if [ -z "$ranked" ]; then
    echo "no mirror does better; Nix keeps cache.nixos.org"
    write "# No mirror did better than cache.nixos.org; written by runix-mirrors.
"
    [ -n "$base" ]
    return
  fi

  list=""
  while read -r s mirror; do
    list="$list $mirror?priority=$priority"
    priority=$((priority + 1))
  done <<<"$ranked"
  awk '{ print $2 }' <<<"$ranked" >"$list_file"
  # A slow cache.nixos.org stays as the last resort; an unreachable one only
  # adds timeouts.
  [ -n "$base" ] && printf '%s\n' "$upstream" >>"$list_file"
  echo "using:$list"
  use "$list${base:+ $upstream?priority=90}" "cache.nixos.org ${base:+gave $(human "$base")}${base:-was unreachable}"
}

# Writes the configuration for these substituters, next to the ones that are
# not cache.nixos.org mirrors.
use() {
  write "# $2; written by runix-mirrors.
substituters = $1 ${RUNIX_SUBSTITUTERS:-}
connect-timeout = 5
stalled-download-timeout = 30
download-attempts = 2
"
}

# Runs a Nix command with one mirror at a time. A download error moves on to
# the next mirror; any other failure is the command's own and ends it.
run() {
  local mirrors=() mirror log status=1
  [ -s "$list_file" ] && mapfile -t mirrors <"$list_file"
  if [ "${#mirrors[@]}" -le 1 ]; then
    "$@"
    return
  fi
  log=$(mktemp)
  for mirror in "${mirrors[@]}"; do
    use "$mirror" "trying $mirror alone"
    echo "runix-mirrors: downloading from $mirror" >&2
    # The daemon reads nix.conf only when it starts.
    if [ -d /run/runit/service/nix-daemon ]; then
      sv restart /run/runit/service/nix-daemon >/dev/null 2>&1 || true
    fi
    "$@" 2> >(tee "$log" >&2)
    status=$?
    wait
    if [ "$status" -eq 0 ]; then
      rm -f "$log"
      return 0
    fi
    if ! grep -qE "unable to download|Timeout was reached|Could not resolve|Connection (refused|reset|timed out)|HTTP error 5[0-9][0-9]|error: (cannot|unable to) (substitute|download)" "$log"; then
      rm -f "$log"
      return "$status"
    fi
    echo "runix-mirrors: $mirror failed, trying the next mirror" >&2
  done
  rm -f "$log"
  echo "runix-mirrors: every mirror failed" >&2
  return "$status"
}

watch() {
  local before after
  while :; do
    before=$(cat "$out" 2>/dev/null)
    if probe; then
      after=$(cat "$out" 2>/dev/null)
      if [ "$before" != "$after" ] && [ -d /run/runit/service/nix-daemon ]; then
        sv restart /run/runit/service/nix-daemon >/dev/null 2>&1 || true
      fi
      sleep "$interval"
    else
      # Probably no network yet.
      sleep 15
    fi
  done
}

load_proxy
case ${1:-} in
  probe) probe ;;
  watch) watch ;;
  status)
    [ -n "${http_proxy:-}" ] && echo "proxy: $http_proxy"
    cat "$out" 2>/dev/null || echo "not probed yet"
    ;;
  exec)
    shift
    exec "$@"
    ;;
  run)
    shift
    run "$@"
    ;;
  -h | --help) usage ;;
  *)
    usage >&2
    exit 1
    ;;
esac
