#!/bin/bash

cd "$(dirname "$0")" || exit 1

passed=0 failed=0

for test_file in test_*.sh; do
    [[ -f "$test_file" ]] || continue

    echo "Running: $test_file"
    bash "$test_file"
    ret=$?

    if (( ret == 0 )); then
        passed=$((passed+1))
        echo "  PASSED"
    else
        failed=$((failed+1))
        echo "  FAILED"
    fi
done

echo ""
echo "Results: $passed passed, $failed failed"

if (( failed > 0 )); then
    exit 1
fi

exit 0
