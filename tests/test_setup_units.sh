#!/bin/bash
# Setup must pull in rename even when only setup is started/enabled.

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
pass=0 fail=0
check() {
    if [[ "$1" == "0" ]]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "FAIL: $2"
    fi
}

# Match dependency tokens in [Unit], allowing multiple directives and
# unrelated dependencies on the same line.
has_dependency() {
    awk -v key="$2" -v dependency="$3" '
        /^\[/ { in_unit = ($0 == "[Unit]") }
        in_unit && index($0, key "=") == 1 {
            value = substr($0, length(key) + 2)
            n = split(value, tokens, /[[:space:]]+/)
            for (i = 1; i <= n; i++)
                if (tokens[i] == dependency) found = 1
        }
        END { exit !found }
    ' "$1"
}

for kind in fd plus; do
    setup="canhat_${kind}_setup.service"
    rename="canhat_${kind}_rename.service"
    for directive in Wants After; do
        has_dependency "$repo_root/$setup" "$directive" "$rename"
        check $? "$setup must have $directive=$rename"
    done
    has_dependency "$repo_root/$rename" Before docker.service
    check $? "$rename must run before docker.service"
    has_dependency "$repo_root/$rename" Before "$setup"
    check $? "$rename must run before $setup"
    has_dependency "$repo_root/$setup" After network.target
    check $? "$setup must retain After=network.target"
done

echo "Setup unit tests: $pass passed, $fail failed"
exit "$fail"
