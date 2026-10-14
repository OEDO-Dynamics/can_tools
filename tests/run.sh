#!/bin/bash

# tests/run.sh - Main test runner
# Runs all test_*.sh scripts and reports results

cd "$(dirname "$0")"

# Counters
passed=0
failed=0

# Run each test file
for test_file in test_*.sh; do
    if [[ ! -f "$test_file" ]]; then
        continue
    fi

    echo "Running: $test_file"
    bash "$test_file"
    ret=$?

    if (( ret == 0 )); then
        (( passed++ ))
        echo "  PASSED"
    else
        (( failed++ ))
        echo "  FAILED"
    fi
done

echo ""
echo "Results: $passed passed, $failed failed"

if (( failed > 0 )); then
    exit 1
fi

exit 0
