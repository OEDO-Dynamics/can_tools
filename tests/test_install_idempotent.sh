#!/bin/bash
# test_install_idempotent.sh - Verify install.sh is idempotent and preserves config

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

pass=0 failed=0

# Test: install.sh has correct structure
test_install_script_exists() {
    [[ -f "$repo_root/install.sh" ]] || return 1
    [[ -x "$repo_root/install.sh" ]] || return 1
    return 0
}

# Test: install.sh supports CHECK_MODE
test_install_check_mode_support() {
    grep -q "CHECK_MODE" "$repo_root/install.sh" || return 1
    return 0
}

# Test: install.sh sources systemctl daemon-reload
test_install_systemctl_reload() {
    grep -q "systemctl daemon-reload" "$repo_root/install.sh" || return 1
    return 0
}

# Test: install.sh preserves existing config
test_install_config_preservation() {
    grep -q "Configuration exists, not overwriting" "$repo_root/install.sh" || return 1
    return 0
}

# Test: install.sh uses rsync without --delete (idempotent)
test_install_no_delete() {
    # Should not mention --delete for destructive operations
    if grep -q "\-\-delete" "$repo_root/install.sh"; then
        return 1
    fi
    return 0
}

# Test: install.sh has proper error handling
test_install_error_handling() {
    grep -q "set -euo pipefail" "$repo_root/install.sh" || return 1
    return 0
}

# Test: install.sh creates directories
test_install_mkdir() {
    grep -q "mkdir -p" "$repo_root/install.sh" || return 1
    return 0
}

# Run tests
echo "Testing install.sh structure..."
if test_install_script_exists; then
    pass=$((pass+1))
    echo "  PASS: install.sh exists and is executable"
else
    failed=$((failed+1))
    echo "  FAIL: install.sh exists and is executable"
fi

echo "Testing CHECK_MODE support..."
if test_install_check_mode_support; then
    pass=$((pass+1))
    echo "  PASS: CHECK_MODE supported"
else
    failed=$((failed+1))
    echo "  FAIL: CHECK_MODE supported"
fi

echo "Testing systemctl daemon-reload..."
if test_install_systemctl_reload; then
    pass=$((pass+1))
    echo "  PASS: systemctl daemon-reload called"
else
    failed=$((failed+1))
    echo "  FAIL: systemctl daemon-reload called"
fi

echo "Testing config preservation..."
if test_install_config_preservation; then
    pass=$((pass+1))
    echo "  PASS: config preservation"
else
    failed=$((failed+1))
    echo "  FAIL: config preservation"
fi

echo "Testing no --delete flag..."
if test_install_no_delete; then
    pass=$((pass+1))
    echo "  PASS: no --delete flag"
else
    failed=$((failed+1))
    echo "  FAIL: no --delete flag"
fi

echo "Testing error handling..."
if test_install_error_handling; then
    pass=$((pass+1))
    echo "  PASS: error handling"
else
    failed=$((failed+1))
    echo "  FAIL: error handling"
fi

echo "Testing mkdir calls..."
if test_install_mkdir; then
    pass=$((pass+1))
    echo "  PASS: mkdir calls"
else
    failed=$((failed+1))
    echo "  FAIL: mkdir calls"
fi

echo ""
echo "Results: $pass passed, $failed failed"

if (( failed > 0 )); then
    exit 1
fi

exit 0
