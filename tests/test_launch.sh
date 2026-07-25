#!/usr/bin/env bash
# test_launch.sh — Unit tests for launch.sh helpers
#
# Tests:
# 1. sync_claude_config_to_vm is called on first VM creation (new snapshot)
# 2. sync_claude_config_to_vm is skipped on subsequent launches (existing snapshot)
# 3. _pid_alive tracks process liveness (including unreaped children)
# 4. _check_virtiofsd_idmap requires newuidmap/newgidmap when unprivileged
# 5. start_virtiofsd fails when virtiofsd dies after binding its socket

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$PROJECT_DIR"

source "$PROJECT_DIR/lib/config.sh"
source "$PROJECT_DIR/lib/launch.sh"

set +euo pipefail

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; (( TESTS_PASSED++ )); (( TESTS_RUN++ )); }
fail() { echo "  FAIL: $1"; (( TESTS_FAILED++ )); (( TESTS_RUN++ )); }

setup_test_env() {
    TEST_VM_DIR="$(mktemp -d)"
    export CLAUDE_VM_DIR="$TEST_VM_DIR"
    export CLAUDE_VM_CONFIG="$TEST_VM_DIR/config"
    load_config
    ensure_dirs
}

teardown_test_env() {
    rm -rf "$TEST_VM_DIR" 2>/dev/null
}

# ── Test: is_new_vm is true when snapshot does not exist ─────────────────────
echo "--- Test 1: is_new_vm=true when snapshot absent ---"
setup_test_env

PROJECT_DIR_TEST="$(mktemp -d)"
snap_path="$(project_snapshot_path "$PROJECT_DIR_TEST")"

is_new_vm=false
[[ ! -f "$snap_path" ]] && is_new_vm=true

if [[ "$is_new_vm" == true ]]; then
    pass "is_new_vm set to true when snapshot absent"
else
    fail "is_new_vm should be true when snapshot absent"
fi

rm -rf "$PROJECT_DIR_TEST"
teardown_test_env

# ── Test: is_new_vm is false when snapshot already exists ────────────────────
echo "--- Test 2: is_new_vm=false when snapshot present ---"
setup_test_env

PROJECT_DIR_TEST="$(mktemp -d)"
snap_path="$(project_snapshot_path "$PROJECT_DIR_TEST")"
mkdir -p "$(dirname "$snap_path")"
touch "$snap_path"

is_new_vm=false
[[ ! -f "$snap_path" ]] && is_new_vm=true

if [[ "$is_new_vm" == false ]]; then
    pass "is_new_vm stays false when snapshot present"
else
    fail "is_new_vm should be false when snapshot present"
fi

rm -rf "$PROJECT_DIR_TEST"
teardown_test_env

# ── Test: _pid_alive reports a running process as alive ──────────────────────
echo "--- Test 3: _pid_alive on a running process ---"

sleep 30 &
live_pid=$!

if _pid_alive "$live_pid"; then
    pass "_pid_alive true for a running process"
else
    fail "_pid_alive should be true for a running process"
fi

kill "$live_pid" 2>/dev/null

# ── Test: _pid_alive reports an exited child as dead ─────────────────────────
# The child is deliberately left unreaped — `kill -0` succeeds on a zombie, so
# liveness is read from /proc instead.
echo "--- Test 4: _pid_alive on an exited (unreaped) child ---"

bash -c 'exit 1' &
dead_pid=$!
sleep 0.3

if _pid_alive "$dead_pid"; then
    fail "_pid_alive should be false for an exited child"
else
    pass "_pid_alive false for an exited child"
fi

wait "$dead_pid" 2>/dev/null

# ── Test: virtiofsd id-mapping helpers are required (issue #7) ───────────────
echo "--- Test 5: _check_virtiofsd_idmap requires newuidmap/newgidmap ---"

FAKE_BIN="$(mktemp -d)"

output="$(PATH="$FAKE_BIN" _check_virtiofsd_idmap /usr/libexec/virtiofsd 2>&1)"
rc=$?

if (( EUID == 0 )); then
    echo "  SKIP: running as root (the helpers are only needed unprivileged)"
elif (( rc != 0 )) && [[ "$output" == *uidmap* ]]; then
    pass "missing newuidmap/newgidmap fails with an install hint"
else
    fail "missing newuidmap/newgidmap should fail (rc=$rc): $output"
fi

# Present in PATH -> check passes
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/newuidmap"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/newgidmap"
chmod +x "$FAKE_BIN/newuidmap" "$FAKE_BIN/newgidmap"

if PATH="$FAKE_BIN" _check_virtiofsd_idmap /usr/libexec/virtiofsd 2>/dev/null; then
    pass "newuidmap/newgidmap present satisfies the check"
else
    fail "newuidmap/newgidmap present should satisfy the check"
fi

# The legacy C daemon doesn't use the helpers — don't demand them
rm -f "$FAKE_BIN/newuidmap" "$FAKE_BIN/newgidmap"

if PATH="$FAKE_BIN" _check_virtiofsd_idmap /usr/lib/qemu/virtiofsd 2>/dev/null; then
    pass "legacy qemu virtiofsd skips the id-map check"
else
    fail "legacy qemu virtiofsd should skip the id-map check"
fi

rm -rf "$FAKE_BIN"

# ── Test: start_virtiofsd rejects a daemon that dies after binding ───────────
# Regression for issue #7: virtiofsd binds the socket, then dies during sandbox
# setup (e.g. no newuidmap). The socket file survives, so an existence-only
# check passed and the failure surfaced later as a QEMU "Connection refused".
echo "--- Test 6: start_virtiofsd detects a daemon that dies after binding ---"

if ! command -v python3 &>/dev/null; then
    echo "  SKIP: python3 needed to create a unix socket"
else
    setup_test_env
    FAKE_BIN="$(mktemp -d)"
    VFS_PROJECT="$(mktemp -d)"
    VFS_RUN="$TEST_VM_DIR/run/fake"
    mkdir -p "$VFS_RUN"

    # Stub the id-map helpers so this test exercises liveness, not test 5
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/newuidmap"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/newgidmap"
    chmod +x "$FAKE_BIN/newuidmap" "$FAKE_BIN/newgidmap"

    # Fake virtiofsd: bind the socket, leave the file behind, then die
    cat > "$FAKE_BIN/virtiofsd" <<'FAKE'
#!/usr/bin/env bash
sock=""
for arg in "$@"; do
    case "$arg" in --socket-path=*) sock="${arg#--socket-path=}" ;; esac
done
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)' "$sock"
echo "fake virtiofsd: simulated crash during sandbox setup" >&2
exit 1
FAKE
    chmod +x "$FAKE_BIN/virtiofsd"

    output="$(PATH="$FAKE_BIN:$PATH" start_virtiofsd "$VFS_PROJECT" "$VFS_RUN/virtiofs.sock" "$VFS_RUN" 2>&1)"
    rc=$?

    if (( rc != 0 )); then
        pass "start_virtiofsd fails when the daemon dies after binding"
    else
        fail "start_virtiofsd should fail when the daemon dies (rc=$rc): $output"
    fi

    if [[ "$output" == *"simulated crash"* ]]; then
        pass "start_virtiofsd surfaces the virtiofsd log on failure"
    else
        fail "start_virtiofsd should surface the virtiofsd log: $output"
    fi

    # ── A daemon that stays up is accepted ──────────────────────────────────
    echo "--- Test 7: start_virtiofsd accepts a live daemon ---"
    cat > "$FAKE_BIN/virtiofsd" <<'FAKE'
#!/usr/bin/env bash
sock=""
for arg in "$@"; do
    case "$arg" in --socket-path=*) sock="${arg#--socket-path=}" ;; esac
done
exec python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(30)' "$sock"
FAKE
    chmod +x "$FAKE_BIN/virtiofsd"

    rm -f "$VFS_RUN/virtiofs.sock"
    output="$(PATH="$FAKE_BIN:$PATH" start_virtiofsd "$VFS_PROJECT" "$VFS_RUN/virtiofs.sock" "$VFS_RUN" 2>&1)"
    rc=$?

    if (( rc == 0 )); then
        pass "start_virtiofsd succeeds when the daemon stays alive"
    else
        fail "start_virtiofsd should succeed with a live daemon (rc=$rc): $output"
    fi

    [[ -f "$VFS_RUN/virtiofsd.pid" ]] && kill "$(cat "$VFS_RUN/virtiofsd.pid")" 2>/dev/null
    rm -rf "$FAKE_BIN" "$VFS_PROJECT"
    teardown_test_env
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
(( TESTS_FAILED > 0 )) && exit 1 || exit 0
