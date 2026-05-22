#!/usr/bin/env bash
# test_list.sh — Unit tests for cmd_list (claude-vm list)
#
# Exercises the snapshot iteration logic: real snapshots show their sidecar
# label, sidecar-less snapshots show (unknown), 0-byte placeholders are
# filtered out entirely (orphan partials from interrupted creation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; (( TESTS_PASSED++ )); (( TESTS_RUN++ )); }
fail() { echo "  FAIL: $1 — $2"; (( TESTS_FAILED++ )); (( TESTS_RUN++ )); }

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

_init() {
    export CLAUDE_VM_DIR="$TEST_DIR/$1"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"
    mkdir -p "$CLAUDE_VM_DIR"
    # Re-source config.sh so path constants pick up the new CLAUDE_VM_DIR
    source "$PROJECT_DIR/lib/config.sh"
    set +euo pipefail
    load_config
    ensure_dirs
}

# Mock base_image_exists so cmd_list's base-image block doesn't crash on a
# missing or fake image.
base_image_exists() { [[ -f "$(base_image_path)" ]]; }

# Extract cmd_list from the claude-vm binary so we can call it in-process.
eval "$(sed -n '/^cmd_list()/,/^}/p' "$PROJECT_DIR/claude-vm")"

# ── Test 1: real snapshot with sidecar shows project path ───────────────────

test_list_shows_sidecar_label() {
    echo "--- Test 1: list shows project path from sidecar ---"
    _init "list-sidecar"

    local project="/tmp/proj-list-sidecar-$$"
    local hash
    hash="$(project_hash "$project")"
    echo "fake qcow2 content" > "$SNAPSHOTS_DIR/${hash}.qcow2"
    echo "$project" > "$SNAPSHOTS_DIR/${hash}.project"

    local output
    output="$(cmd_list 2>&1)"

    if echo "$output" | grep -qF "$project"; then
        pass "project path appears in output"
    else
        fail "list sidecar" "expected '$project' in output: $output"
    fi
}

# ── Test 2: 0-byte qcow2 (orphan partial) is filtered out ───────────────────

test_list_skips_empty_qcow2() {
    echo "--- Test 2: list skips 0-byte qcow2 placeholders ---"
    _init "list-empty"

    # 0-byte file — simulates an interrupted snapshot creation
    : > "$SNAPSHOTS_DIR/deadbeef0000.qcow2"

    local output
    output="$(cmd_list 2>&1)"

    if echo "$output" | grep -qF "deadbeef0000"; then
        fail "list empty filter" "0-byte qcow2 appeared in output: $output"
    elif echo "$output" | grep -qF "(unknown)"; then
        fail "list empty filter" "0-byte qcow2 surfaced as (unknown): $output"
    else
        pass "0-byte qcow2 is hidden"
    fi
}

# ── Test 3: mix of real + empty — only the real one is shown ────────────────

test_list_mix_real_and_empty() {
    echo "--- Test 3: list shows real snapshot but hides 0-byte siblings ---"
    _init "list-mix"

    local project="/tmp/proj-list-mix-$$"
    local hash
    hash="$(project_hash "$project")"
    echo "qcow2 contents" > "$SNAPSHOTS_DIR/${hash}.qcow2"
    echo "$project" > "$SNAPSHOTS_DIR/${hash}.project"

    # Two orphan 0-byte siblings
    : > "$SNAPSHOTS_DIR/aaaaaaaaaaaa.qcow2"
    : > "$SNAPSHOTS_DIR/bbbbbbbbbbbb.qcow2"

    local output
    output="$(cmd_list 2>&1)"

    local ok=true
    echo "$output" | grep -qF "$project"     || { fail "real shown"  "missing $project"; ok=false; }
    echo "$output" | grep -qF "aaaaaaaaaaaa" && { fail "empty hidden" "aaaaaaaaaaaa leaked"; ok=false; }
    echo "$output" | grep -qF "bbbbbbbbbbbb" && { fail "empty hidden" "bbbbbbbbbbbb leaked"; ok=false; }
    echo "$output" | grep -qF "(unknown)"    && { fail "no unknowns" "(unknown) appeared: $output"; ok=false; }

    $ok && pass "real snapshot shown, both 0-byte siblings hidden"
}

# ── Test 4: pending restore (sidecar + backup, no qcow2) ────────────────────

test_list_shows_pending_restore() {
    echo "--- Test 4: list shows [pending restore] for sidecar+backup with no qcow2 ---"
    _init "list-pending"

    local project="/tmp/proj-list-pending-$$"
    local hash
    hash="$(project_hash "$project")"

    # State left by a successful rebase: sidecar kept, qcow2 gone, backup waiting.
    echo "$project" > "$SNAPSHOTS_DIR/${hash}.project"
    mkdir -p "$BACKUPS_DIR/${hash}/.claude"
    echo "data" > "$BACKUPS_DIR/${hash}/.claude/settings.json"

    local output
    output="$(cmd_list 2>&1)"

    local ok=true
    echo "$output" | grep -qF "$project"          || { fail "project label"   "missing $project"; ok=false; }
    echo "$output" | grep -qF "pending restore"   || { fail "status label"    "missing [pending restore]"; ok=false; }
    echo "$output" | grep -qF "$hash"             || { fail "hash shown"      "missing $hash"; ok=false; }

    $ok && pass "pending-restore project surfaces with sidecar label + [pending restore]"
}

# ── Test 5: orphan sidecar without backup is hidden ─────────────────────────

test_list_hides_orphan_sidecar() {
    echo "--- Test 5: list ignores sidecar with no qcow2 and no backup ---"
    _init "list-orphan-sidecar"

    # Sidecar from an old destroyed project — no qcow2, no backup
    echo "/tmp/gone" > "$SNAPSHOTS_DIR/deadbeefdead.project"

    local output
    output="$(cmd_list 2>&1)"

    if echo "$output" | grep -qF "deadbeefdead"; then
        fail "orphan sidecar leaked" "hash appeared: $output"
    elif echo "$output" | grep -qF "/tmp/gone"; then
        fail "orphan sidecar leaked" "label appeared: $output"
    else
        pass "orphan sidecar without backup is hidden"
    fi
}

# ── Test 6: empty dir yields "(none)" ───────────────────────────────────────

test_list_empty_dir() {
    echo "--- Test 4: list prints (none) for empty snapshots dir ---"
    _init "list-none"

    local output
    output="$(cmd_list 2>&1)"

    if echo "$output" | grep -q "(none)"; then
        pass "empty dir shows (none)"
    else
        fail "list empty" "expected '(none)' marker, got: $output"
    fi
}

# ── Run all tests ───────────────────────────────────────────────────────────

echo "=== claude-vm list tests ==="
echo ""

test_list_shows_sidecar_label
test_list_skips_empty_qcow2
test_list_mix_real_and_empty
test_list_shows_pending_restore
test_list_hides_orphan_sidecar
test_list_empty_dir

echo ""
echo "=== Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total ==="

(( TESTS_FAILED > 0 )) && exit 1
exit 0
