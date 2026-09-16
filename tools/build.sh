#!/bin/sh

set -eu

. "$(dirname "$0")/common.sh"

optimize=Debug
self_test=true
service_test=

while [ "$#" -gt 0 ]; do
    case $1 in
        --optimize|--python|--self-test|--service-test)

            [ "$#" -ge 2 ] || fail "$1 requires a value"

            case $1 in
                --optimize) optimize=$2 ;;
                --python) PYTHON=$2 ;;
                --self-test) self_test=$2 ;;
                --service-test) service_test=$2 ;;
            esac

            shift 2

        ;;
        *) fail 'Usage: sh tools/build.sh [--optimize MODE] [--python PATH] [--self-test true|false] [--service-test true|false]' ;;
    esac
done

case $optimize in
    Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;;
    *) fail 'Invalid optimization mode' ;;
esac

case $self_test in
    true|false) ;;
    *) fail 'Invalid self-test setting' ;;
esac

case $service_test in
    ''|true|false) ;;
    *) fail 'Invalid service-test setting' ;;
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

set -- "-Doptimize=$optimize" "-Dself-test=$self_test"
[ -z "$service_test" ] || set -- "$@" "-Dservice-test=$service_test"
"$zig" build "$@" --summary all
"$zig" build test "-Doptimize=$optimize" --summary all
"$python" -m unittest discover -s tools -p test_media.py -v
"$python" tools/media.py
