#!/bin/sh

set -eu

. "$(dirname "$0")/common.sh"

[ "$#" -eq 0 ] || fail 'Usage: sh tools/setup.sh'
[ "$version" = 0.15.2 ] || fail 'Update the pinned download checksums for this Zig version first'
find_python

case $architecture-$platform in

    x86_64-windows)

        digest=3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c

    ;;

    aarch64-windows)

        digest=b926465f8872bf983422257cd9ec248bb2b270996fbe8d57872cca13b56fc370

    ;;

    x86_64-linux)

        digest=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239

    ;;

    aarch64-linux)

        digest=958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f

    ;;

    x86_64-macos)

        digest=375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f

    ;;

    aarch64-macos)

        digest=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b

    ;;

esac

directory=$project/.tools
extension=tar.xz
[ "$platform" != windows ] || extension=zip
filename=zig-$architecture-$platform-$version.$extension
archive=$directory/$filename

[ -d "$directory" ] || mkdir -p "$directory"

trap 'rm -f "$archive.part"' 0
trap 'exit 130' INT
trap 'exit 143' TERM

download=$archive
if [ ! -f "$archive" ]; then

    download=$archive.part
    curl --fail --location --retry 3 "https://ziglang.org/download/$version/$filename" -o "$download"

fi

"$python" - "$(native_path "$download")" "$digest" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()

with open(sys.argv[1], "rb") as archive:

    for block in iter(lambda: archive.read(1024 * 1024), b""):

        digest.update(block)

if digest.hexdigest() != sys.argv[2]:

    sys.exit("Zig archive checksum mismatch")

PY

if [ "$download" != "$archive" ]; then

    mv -f "$download" "$archive"

fi

if [ "$platform" = windows ]; then

    "$python" -m zipfile -e "$(native_path "$archive")" "$(native_path "$directory")"

else

    tar -xf "$archive" -C "$directory"

fi

printf 'Zig %s is available in %s\n' "$version" "$directory"
