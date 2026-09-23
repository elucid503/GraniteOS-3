#!/bin/sh

# Build GraniteOS and boot it in VMware: `run` attaches the COM2 terminal, `test` runs every acceptance check.

set -eu

fail() {

    printf '%s\n' "$*" >&2
    exit 1

}

usage='Usage: sh tools/vmware.sh run|test [--media iso|disk] [--cpus N] [--memory MB]'
[ "$#" -ge 1 ] || fail "$usage"

action=$1
media=iso
cpus=2
memory=256
shift

while [ "$#" -gt 0 ]; do

    [ "$#" -ge 2 ] || fail "$usage"

    case $1 in
        --media) media=$2 ;;
        --cpus) cpus=$2 ;;
        --memory) memory=$2 ;;
        *) fail "$usage" ;;
    esac

    shift 2

done

case $action-$media in
    run-iso|run-disk|test-iso|test-disk) ;;
    *) fail "$usage" ;;
esac

case $cpus-$memory in
    *[!0-9-]*|-*|*-) fail "$usage" ;;
esac

[ "$cpus" -ge 1 ] && [ "$cpus" -le 64 ] && [ "$memory" -ge 128 ] && [ "$memory" -le 8192 ] || fail 'Require 1–64 CPUs and 128–8192 MB'

case $(uname -s) in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) fail 'The VMware terminal pipe requires Windows' ;;
esac

project=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
cd "$project"

python=${PYTHON:-}
for candidate in py python3 python; do

    [ -z "$python" ] || break
    ! "$candidate" --version >/dev/null 2>&1 || python=$candidate

done

[ -n "$python" ] || fail 'Python 3 is required; set PYTHON to its executable path'

vmrun=${VMRUN:-$(command -v vmrun || true)}
for candidate in "/c/Program Files/VMware/VMware Workstation/vmrun.exe" "/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"; do

    [ -n "$vmrun" ] || [ ! -x "$candidate" ] || vmrun=$candidate

done

[ -n "$vmrun" ] || fail 'VMware vmrun is missing; set VMRUN to its path'

command -v zig >/dev/null || fail 'Zig is missing from PATH'
version=$(tr -d '\r\n' < .zigversion)
[ "$(zig version)" = "$version" ] || fail "This project requires Zig $version"

if [ "$action" = test ]; then

    zig build test -Doptimize=ReleaseSafe
    "$python" -m unittest discover -s tools -p test_media.py

fi

zig build -Doptimize=ReleaseSafe "-Dself-test=$([ "$action" = test ] && echo true || echo false)"
"$python" tools/media.py

directory=zig-out/vm/$action-$media
serial=$directory/serial.log
vmx=$(cygpath -m "$project/$directory/granite.vmx")
# MSYS rewrites a leading `\\` in native arguments, so only the short pipe name crosses into Python.
pipe=GraniteOS-$action-$media

mkdir -p "$directory"
: > "$serial"

if [ "$media" = disk ]; then

    cp zig-out/granite.img "$directory/disk.img"
    cat > "$directory/disk.vmdk" <<EOF
# Disk DescriptorFile
version=1
encoding="UTF-8"
CID=fffffffe
parentCID=ffffffff
createType="monolithicFlat"
RW $(( $(wc -c < zig-out/granite.img) / 512 )) FLAT "disk.img" 0
ddb.adapterType = "ide"
ddb.geometry.cylinders = "132"
ddb.geometry.heads = "16"
ddb.geometry.sectors = "63"
EOF
    device='sata0:0.fileName = "disk.vmdk"'

else

    device="sata0:0.deviceType = \"cdrom-image\"
sata0:0.fileName = \"$(cygpath -m "$project/zig-out/granite.iso")\""

fi

cat > "$directory/granite.vmx" <<EOF
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "21"
displayName = "GraniteOS 3"
guestOS = "other-64"
firmware = "efi"
uefi.secureBoot.enabled = "FALSE"
memsize = "$memory"
numvcpus = "$cpus"
cpuid.coresPerSocket = "$cpus"
powerType.powerOff = "hard"
powerType.reset = "hard"
sata0.present = "TRUE"
sata0:0.present = "TRUE"
$device
sata0:0.startConnected = "TRUE"
serial0.present = "TRUE"
serial0.fileType = "file"
serial0.fileName = "$(cygpath -m "$project/$serial")"
serial0.yieldOnMsrRead = "TRUE"
serial0.startConnected = "TRUE"
serial1.present = "TRUE"
serial1.fileType = "pipe"
serial1.fileName = "\\\\.\\pipe\\$pipe"
serial1.pipe.endPoint = "server"
serial1.tryNoRxLoss = "TRUE"
serial1.yieldOnMsrRead = "TRUE"
serial1.startConnected = "TRUE"
floppy0.present = "FALSE"
ethernet0.present = "FALSE"
usb.present = "FALSE"
sound.present = "FALSE"
msg.autoAnswer = "TRUE"
uuid.action = "create"
EOF

"$vmrun" start "$vmx" nogui
trap '"$vmrun" stop "$vmx" hard >/dev/null' EXIT
trap 'exit 130' INT TERM

if [ "$action" = run ]; then

    printf 'Kernel log (COM1): %s\n' "$serial"
    "$python" tools/terminal.py attach "$pipe"
    exit

fi

markers='boot: firmware released
boot: handoff ready
kernel: memory protected
kernel: page isolation and allocation rollback passed
kernel: all processors online
kernel: IPC and capability checks passed
kernel: fault isolation passed
kernel: process memory reclaimed
kernel: ready
services: ready
services: supervisor recovered; children adopted
services: recovery and application APIs passed'
failure=': error: |Exception Type|services: acceptance failed'
deadline=$(( $(date +%s) + 120 ))

while :; do

    ! grep -qE "$failure" "$serial" || fail "$(cat "$serial")"

    found=$(printf '%s\n' "$markers" | grep -oFf - "$serial" | sort -u | wc -l)
    [ "$found" -ne "$(printf '%s\n' "$markers" | wc -l)" ] || [ "$(grep -c 'kernel: verified cpu = ' "$serial")" -ne "$cpus" ] || break
    [ "$(date +%s)" -lt "$deadline" ] || fail "VMware test timed out. Inspect $serial"
    sleep 0.2

done

"$python" tools/terminal.py smoke "$pipe" "$directory/terminal.log"
! grep -qE ': error: |services: acceptance failed' "$serial" || fail "$(cat "$serial")"
cat "$serial"
printf 'VMware test passed (%s CPUs, %s MB, %s).\n' "$cpus" "$memory" "$media"
