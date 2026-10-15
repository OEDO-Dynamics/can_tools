#!/bin/bash
# test_setup_lib_usage.sh - Verify setup/rename scripts use can_tools_lib functions

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

pass=0 failed=0

# Test: canhat_fd_setup.bash sources can_tools_lib
test_fd_setup_sources_lib() {
    local setup_script="$repo_root/canhat_fd_setup.bash"

    # Script should source can_tools_lib.bash (via LIB_PATH or directly)
    grep -q "source" "$setup_script" || return 1
    grep -q "can_tools_lib.bash" "$setup_script" || return 1

    # Script should call can_read_conf
    grep -q "can_read_conf" "$setup_script" || return 1

    # Script should call can_setup_iface
    grep -q "can_setup_iface" "$setup_script" || return 1

    return 0
}

# Test: canhat_fd_rename.bash sources can_tools_lib
test_fd_rename_sources_lib() {
    local rename_script="$repo_root/canhat_fd_rename.bash"

    # Script should source can_tools_lib.bash (via LIB_PATH or directly)
    grep -q "source" "$rename_script" || return 1
    grep -q "can_tools_lib.bash" "$rename_script" || return 1

    # Script should call can_read_conf
    grep -q "can_read_conf" "$rename_script" || return 1

    # Script should call can_pin_name
    grep -q "can_pin_name" "$rename_script" || return 1

    return 0
}

# Test: canhat_plus_setup.bash sources can_tools_lib
test_plus_setup_sources_lib() {
    local setup_script="$repo_root/canhat_plus_setup.bash"

    # Script should source can_tools_lib.bash (via LIB_PATH or directly)
    grep -q "source" "$setup_script" || return 1
    grep -q "can_tools_lib.bash" "$setup_script" || return 1

    # Script should call can_read_conf
    grep -q "can_read_conf" "$setup_script" || return 1

    # Script should call can_setup_iface
    grep -q "can_setup_iface" "$setup_script" || return 1

    # Should disable CAN FD for Plus
    grep -q 'CAN_FD="off"' "$setup_script" || return 1

    return 0
}

# Test: canhat_plus_rename.bash sources can_tools_lib
test_plus_rename_sources_lib() {
    local rename_script="$repo_root/canhat_plus_rename.bash"

    # Script should source can_tools_lib.bash (via LIB_PATH or directly)
    grep -q "source" "$rename_script" || return 1
    grep -q "can_tools_lib.bash" "$rename_script" || return 1

    # Script should call can_read_conf
    grep -q "can_read_conf" "$rename_script" || return 1

    # Script should call can_pin_name
    grep -q "can_pin_name" "$rename_script" || return 1

    return 0
}

# Test: Setup scripts do not use sudo (sudo is in lib, not in wrapper)
test_setup_no_sudo() {
    local setup_script
    setup_script="$repo_root/canhat_fd_setup.bash"

    # Script should not call sudo directly (sudo is inside lib functions)
    if grep -q "sudo ip link set" "$setup_script"; then
        return 1
    fi

    return 0
}

# Test: Rename scripts do not use sudo
test_rename_no_sudo() {
    local rename_script
    rename_script="$repo_root/canhat_fd_rename.bash"

    # Script should not call sudo directly
    if grep -q "sudo ip link set" "$rename_script"; then
        return 1
    fi

    return 0
}

# Run tests
echo "Testing FD setup script lib usage..."
if test_fd_setup_sources_lib; then
    pass=$((pass+1))
    echo "  PASS: FD setup sources lib"
else
    failed=$((failed+1))
    echo "  FAIL: FD setup sources lib"
fi

echo "Testing FD rename script lib usage..."
if test_fd_rename_sources_lib; then
    pass=$((pass+1))
    echo "  PASS: FD rename sources lib"
else
    failed=$((failed+1))
    echo "  FAIL: FD rename sources lib"
fi

echo "Testing Plus setup script lib usage..."
if test_plus_setup_sources_lib; then
    pass=$((pass+1))
    echo "  PASS: Plus setup sources lib"
else
    failed=$((failed+1))
    echo "  FAIL: Plus setup sources lib"
fi

echo "Testing Plus rename script lib usage..."
if test_plus_rename_sources_lib; then
    pass=$((pass+1))
    echo "  PASS: Plus rename sources lib"
else
    failed=$((failed+1))
    echo "  FAIL: Plus rename sources lib"
fi

echo "Testing setup scripts don't call sudo..."
if test_setup_no_sudo; then
    pass=$((pass+1))
    echo "  PASS: setup no sudo"
else
    failed=$((failed+1))
    echo "  FAIL: setup no sudo"
fi

echo "Testing rename scripts don't call sudo..."
if test_rename_no_sudo; then
    pass=$((pass+1))
    echo "  PASS: rename no sudo"
else
    failed=$((failed+1))
    echo "  FAIL: rename no sudo"
fi

echo ""
echo "Results: $pass passed, $failed failed"

if (( failed > 0 )); then
    exit 1
fi

exit 0
