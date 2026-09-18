#!/bin/bash
cd "$(dirname "$0")"
forge test --no-match-path "test/integration/**" > test.log 2>&1
echo "TEST_EXIT=$?" >> test.log
