#!/bin/sh

set -eu

. "$(dirname "$0")/common.sh"

optimize=Debug

while [ "$#" -gt 0 ]; do
    case $1 in
        --optimize|--python)

            [ "$#" -ge 2 ] || fail "$1 requires a value"

            case $1 in
                --optimize) optimize=$2 ;;
                --python) PYTHON=$2 ;;
            esac

            shift 2

        ;;
        *) fail 'Usage: sh tools/build.sh [--optimize Debug|ReleaseSafe|ReleaseFast|ReleaseSmall] [--python PATH]' ;;
    esac
done

case $optimize in
    Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;;
    *) fail 'Invalid optimization mode' ;;
esac

find_python

zig=${ZIG:-$project/.tools/zig-$architecture-$platform-$version/zig}
[ "$platform" != windows ] || zig=${ZIG:-$zig.exe}

if [ ! -x "$zig" ] && [ -z "${ZIG:-}" ]; then
    zig=$(command -v zig) || fail 'Zig is missing; run sh tools/setup.sh first'
fi

[ "$("$zig" version)" = "$version" ] || fail "This project requires Zig $version"

ZIG_GLOBAL_CACHE_DIR=$(native_path "$project/.zig-cache/global")
export ZIG_GLOBAL_CACHE_DIR

cd "$project"

"$zig" build "-Doptimize=$optimize" --summary all
"$zig" build test "-Doptimize=$optimize" --summary all
"$python" -m unittest discover -s tools -p test_media.py -v
"$python" tools/media.py
