#!/bin/bash
cd "$(dirname "$0")"
forge build > build.log 2>&1
echo "BUILD_EXIT=$?" >> build.log
