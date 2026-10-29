#!/usr/bin/env bash
# Build one controller CLI and query each already-running Ubuntu VM over SSH.
# Usage: bash tests/e2e/multi-vm-smoke.sh [jammy noble resolute]
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
releases=("$@")
if (( ${#releases[@]} == 0 )); then
    releases=(jammy noble resolute)
fi
seen=" "
for release in "${releases[@]}"; do
    case "$release" in
        jammy|noble|resolute) ;;
        *) printf 'multi-vm-smoke: invalid release: %s\n' "$release" >&2; exit 2 ;;
    esac
    [[ "$seen" != *" $release "* ]] || {
        printf 'multi-vm-smoke: duplicate release: %s\n' "$release" >&2; exit 2;
    }
    seen+="$release "
done
wait_seconds="${SYSKNIFE_MULTI_VM_TIMEOUT:-15}"
[[ "$wait_seconds" =~ ^[1-9][0-9]*$ ]] || {
    echo 'multi-vm-smoke: SYSKNIFE_MULTI_VM_TIMEOUT must be positive seconds' >&2
    exit 2
}
for tool in cargo python3 ssh timeout; do
    command -v "$tool" >/dev/null || { echo "multi-vm-smoke: missing $tool" >&2; exit 1; }
done
# A short private directory avoids Unix socket path limits and shared stale files.
run_dir="$(mktemp -d /tmp/sysknife-multi.XXXXXX)"
pids=()
cleanup() {
    local pid
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$run_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! cargo build --locked -p sysknife-cli --bin sysknife --message-format=json \
    > "$run_dir/build.jsonl"; then
    echo 'multi-vm-smoke: controller build failed' >&2
    exit 1
fi
# Cargo's artifact path also respects custom target dirs and configured targets.
binary="$(python3 - "$run_dir/build.jsonl" <<'PY'
import json, sys
executables = []
with open(sys.argv[1], encoding='utf-8') as stream:
    for line in stream:
        message = json.loads(line)
        target = message.get('target', {})
        if (message.get('reason') == 'compiler-artifact'
                and target.get('name') == 'sysknife'
                and 'bin' in target.get('kind', [])
                and message.get('executable')):
            executables.append(message['executable'])
if len(executables) != 1:
    sys.exit('multi-vm-smoke: build did not report exactly one sysknife executable')
print(executables[0])
PY
)"
[[ -x "$binary" ]] || { echo "multi-vm-smoke: build artifact is not executable: $binary" >&2; exit 1; }

seen_ports=" "
for release in "${releases[@]}"; do
    # Source independently so one release's defaults cannot leak into the next.
    read -r port user < <(
        export UBUNTU_RELEASE="$release"
        # shellcheck source=tests/e2e/ubuntu-vm.conf
        source "$repo_root/tests/e2e/ubuntu-vm.conf"
        printf '%s %s\n' "$UBUNTU_VM_SSH_PORT" "$UBUNTU_VM_USER"
    )
    [[ "$seen_ports" != *" $port "* ]] || {
        printf '[%s] duplicate SSH port %s: selected releases must use distinct guests\n' \
            "$release" "$port" >&2
        exit 2
    }
    seen_ports+="$port "
    socket="$run_dir/$release.sock"
    ssh -N -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes \
        -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout="$wait_seconds" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -i "${SYSKNIFE_VM_SSH_KEY:-$HOME/.ssh/sysknife-vm}" \
        -p "$port" -L "$socket:/run/sysknife/daemon.sock" "$user@127.0.0.1" \
        > "$run_dir/$release.ssh.log" 2>&1 &
    pid=$!
    pids+=("$pid")
    deadline=$((SECONDS + wait_seconds))
    while [[ ! -S "$socket" ]] && kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do
        sleep 0.1
    done
    if [[ ! -S "$socket" ]] || ! kill -0 "$pid" 2>/dev/null; then
        printf '[%s] tunnel failed to bind\n' "$release" >&2
        sed "s/^/[$release] /" "$run_dir/$release.ssh.log" >&2
        exit 1
    fi
    if ! SYSKNIFE_SOCKET="$socket" timeout --kill-after=2 "$wait_seconds" \
        "$binary" doctor --json > "$run_dir/$release.answer" 2>&1; then
        printf '[%s] read-only doctor call failed\n' "$release" >&2
        sed "s/^/[$release] /" "$run_dir/$release.answer" >&2
        exit 1
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        printf '[%s] tunnel exited during the call\n' "$release" >&2
        exit 1
    fi
    sed "s/^/[$release] /" "$run_dir/$release.answer"
done
printf 'multi-vm-smoke: all %s selected hosts answered\n' "${#releases[@]}"
