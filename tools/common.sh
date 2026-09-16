#!/bin/sh

fail() {

    printf '%s\n' "$*" >&2
    exit 1

}

project=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
version=$(tr -d '\r\n' < "$project/.zigversion")

case $(uname -s) in
    MINGW*|MSYS*|CYGWIN*) platform=windows ;;
    Linux) platform=linux ;;
    Darwin) platform=macos ;;
    *) fail 'Unsupported host operating system' ;;
esac

case $(uname -m) in
    x86_64|amd64) architecture=x86_64 ;;
    aarch64|arm64) architecture=aarch64 ;;
    *) fail 'Unsupported host architecture' ;;
esac

native_path() {

    if [ "$platform" = windows ]; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi

}

find_python() {

    if [ -n "${PYTHON:-}" ]; then
        python=$PYTHON
    elif command -v python3 >/dev/null 2>&1; then
        python=python3
    elif command -v python >/dev/null 2>&1; then
        python=python
    else
        fail 'Python 3 is required; set PYTHON to its executable path'
    fi

}
