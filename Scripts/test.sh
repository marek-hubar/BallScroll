#!/bin/bash
# Run the unit tests.
#
# With full Xcode installed, plain `swift test` works. With only the Command
# Line Tools, the Swift Testing framework is on disk but not on the default
# search path, so this script adds it.
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == */CommandLineTools ]]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    libs="$developer_dir/Library/Developer/usr/lib"
    exec swift test \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xlinker -F -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$libs" \
        "$@"
else
    exec swift test "$@"
fi
