#!/usr/bin/env bash
# Offline orchestration tests: real Unix sockets, stub SSH/Cargo/CLI, no VM.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d /tmp/sysknife-multi-test.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/repo/tests/e2e" "$fixture/artifact dir"
cp "$repo_root/tests/e2e/multi-vm-smoke.sh" "$repo_root/tests/e2e/ubuntu-vm.conf" \
    "$fixture/repo/tests/e2e/"
export FIXTURE="$fixture"
export PATH="$fixture/bin:$PATH"
export SYSKNIFE_VM_SSH_KEY="$fixture/key"
touch "$SYSKNIFE_VM_SSH_KEY"

cat > "$fixture/bin/cargo" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
root = pathlib.Path(os.environ['FIXTURE'])
assert sys.argv[1:] == ['build', '--locked', '-p', 'sysknife-cli', '--bin', 'sysknife', '--message-format=json']
if os.environ['SCENARIO'] == 'build-fail':
    sys.exit(1)
binary = root / 'artifact dir/sysknife'
shutil.copy2(root / 'cli', binary)
print(json.dumps({'reason': 'compiler-artifact', 'target': {'name': 'sysknife', 'kind': ['bin']}, 'executable': str(binary)}))
PY
cat > "$fixture/bin/ssh" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, signal, socket, sys, time
root = pathlib.Path(os.environ['FIXTURE'])
args = sys.argv[1:]
forward = args[args.index('-L') + 1]
path, remote = forward.split(':', 1)
host = pathlib.Path(path).stem
with (root / 'ssh.log').open('a') as log:
    log.write(json.dumps({'host': host, 'pid': os.getpid(), 'args': args, 'path': path}) + '\n')
assert '-N' in args and '-f' not in args and '-fN' not in args
assert remote == '/run/sysknife/daemon.sock'
assert args[args.index('-p') + 1] == {'jammy': '2222', 'noble': '2223', 'resolute': '2224'}[host]
assert args[-1] == 'ubuntu@127.0.0.1'
scenario = os.environ['SCENARIO']
# Model SSH's dangerous successful startup without a bound forward.
if 'ExitOnForwardFailure=yes' not in args:
    sys.exit(0)
if scenario == 'ssh-fail' and host == 'noble':
    sys.exit(255)
if scenario == 'no-bind' and host == 'noble':
    sys.exit(0)
if scenario == 'hang-bind' and host == 'noble':
    time.sleep(30)
    sys.exit(0)
if scenario == 'stale':
    stale = socket.socket(socket.AF_UNIX)
    stale.bind(path)
    stale.close()
if os.path.lexists(path) and 'StreamLocalBindUnlink=yes' in args:
    os.unlink(path)
sock = socket.socket(socket.AF_UNIX)
sock.bind(path)
sock.listen()
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
while True:
    time.sleep(0.1)
PY
cat > "$fixture/cli" <<'PY'
#!/usr/bin/env python3
import os, pathlib, socket, sys, time
root = pathlib.Path(os.environ['FIXTURE'])
assert sys.argv[1:] == ['doctor', '--json']
path = os.environ['SYSKNIFE_SOCKET']
host = pathlib.Path(path).stem
with (root / 'calls.log').open('a') as log:
    log.write(host + '\n')
assert pathlib.Path(sys.argv[0]).parent.name == 'artifact dir'
connection = socket.socket(socket.AF_UNIX)
connection.connect(path)
if os.environ['SCENARIO'] == 'call-fail' and host == 'noble':
    sys.exit(4)
if os.environ['SCENARIO'] == 'hang-call' and host == 'noble':
    time.sleep(30)
print('{"ok":true}')
PY
cat > "$fixture/bin/sysknife" <<'SH'
#!/usr/bin/env bash
echo 'must not use PATH sysknife' >&2
exit 91
SH
chmod +x "$fixture/bin/"* "$fixture/cli"

run_case() {
    local scenario="$1" expected="$2" host="$3"
    shift 3
    export SCENARIO="$scenario"
    : > "$fixture/ssh.log"
    : > "$fixture/calls.log"
    local status=0
    SYSKNIFE_MULTI_VM_TIMEOUT=5 timeout --kill-after=2 45 \
        bash "$fixture/repo/tests/e2e/multi-vm-smoke.sh" "$@" \
        > "$fixture/output" 2>&1 || status=$?
    if [[ "$expected" == pass ]]; then
        [[ "$status" == 0 ]] || { cat "$fixture/output"; exit 1; }
    else
        [[ "$status" != 0 && "$status" != 124 && "$status" != 137 ]] || {
            cat "$fixture/output"; echo "unexpected status $status: $scenario" >&2; exit 1;
        }
        grep -Fq "$host" "$fixture/output" || { cat "$fixture/output"; exit 1; }
    fi
    python3 - <<'PY'
import json, os, pathlib
root = pathlib.Path(os.environ['FIXTURE'])
for line in (root / 'ssh.log').read_text().splitlines():
    item = json.loads(line)
    try:
        os.kill(item['pid'], 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError(f"tunnel survived: {item}")
    assert not pathlib.Path(item['path']).exists(), item
PY
    printf 'PASS %s\n' "$scenario"
}

run_case success pass ''
[[ "$(cat "$fixture/calls.log")" == $'jammy\nnoble\nresolute' ]]
for release in jammy noble resolute; do
    grep -Fq "[$release] {\"ok\":true}" "$fixture/output"
done
run_case stale pass ''
run_case ssh-fail fail noble
run_case no-bind fail noble
run_case hang-bind fail noble
run_case call-fail fail noble
run_case hang-call fail noble
run_case build-fail fail build
[[ ! -s "$fixture/ssh.log" ]]
run_case subset pass '' noble
[[ "$(cat "$fixture/calls.log")" == noble ]]
run_case invalid fail invalid invalid
[[ ! -s "$fixture/ssh.log" ]]
run_case duplicate fail duplicate noble noble
[[ ! -s "$fixture/ssh.log" ]]
UBUNTU_VM_SSH_PORT=2222 run_case same-port fail 'duplicate SSH port 2222'
grep -Fq '[noble]' "$fixture/output"
[[ "$(cat "$fixture/calls.log")" == jammy ]]

# Termination during an in-flight call must still reap every tunnel.
SCENARIO=hang-call SYSKNIFE_MULTI_VM_TIMEOUT=5 python3 - <<'PY'
import json, os, pathlib, signal, subprocess, time
root = pathlib.Path(os.environ['FIXTURE'])
(root / 'ssh.log').write_text('')
(root / 'calls.log').write_text('')
with (root / 'output').open('w') as out:
    process = subprocess.Popen(['bash', str(root / 'repo/tests/e2e/multi-vm-smoke.sh')], stdout=out, stderr=out)
    try:
        deadline = time.monotonic() + 30
        while 'noble' not in (root / 'calls.log').read_text():
            assert process.poll() is None, (root / 'output').read_text()
            assert time.monotonic() < deadline, 'did not reach the second call'
            time.sleep(0.05)
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=12) == 143
        for line in (root / 'ssh.log').read_text().splitlines():
            item = json.loads(line)
            try:
                os.kill(item['pid'], 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError(f"tunnel survived TERM: {item}")
            assert not pathlib.Path(item['path']).exists()
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=12)
PY
printf 'PASS signal-cleanup\nmulti-vm-smoke: 13 offline cases passed\n'
