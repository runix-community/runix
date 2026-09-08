set -euo pipefail
tree=$1
temporary=$(mktemp -d)
supervisor=
cleanup() {
  for service in "$temporary"/services/*; do
    sv -w 2 force-stop "$service" >/dev/null 2>&1 || true
    sv exit "$service" >/dev/null 2>&1 || true
  done
  if [ -n "$supervisor" ]; then
    kill "$supervisor" 2>/dev/null || true
    wait "$supervisor" 2>/dev/null || true
  fi
  rm -rf "$temporary"
}
trap cleanup EXIT
export TEST_ROOT="$temporary"
cp -R "$tree" "$temporary/services"
chmod -R u+w "$temporary/services"
runsvdir "$temporary/services" &
supervisor=$!
for _ in $(seq 1 100); do
  if [ -f "$temporary/never" ] && [ -f "$temporary/success" ] &&
    [ -f "$temporary/retry" ] && [ "$(wc -c < "$temporary/retry")" -ge 2 ]; then
    break
  fi
  sleep 0.1
done
# A runsv restart takes at least one second. Observe beyond that interval.
sleep 3
test "$(wc -c < "$temporary/never")" = 1
test "$(wc -c < "$temporary/success")" = 1
test "$(wc -c < "$temporary/retry")" = 2
printf 'Runit restart policy tests passed\n'
