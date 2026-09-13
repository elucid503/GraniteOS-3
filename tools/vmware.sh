#!/bin/sh

set -eu

. "$(dirname "$0")/common.sh"

action=test
media=iso
timeout=60
vmrun=${VMRUN:-}

while [ "$#" -gt 0 ]; do

    case $1 in

        --action|--media|--timeout|--vmrun)

            [ "$#" -ge 2 ] || fail "$1 requires a value"

            case $1 in

                --action)

                    action=$2

                ;;

                --media)

                    media=$2

                ;;

                --timeout)

                    timeout=$2

                ;;

                --vmrun)

                    vmrun=$2

                ;;

            esac

            shift 2

        ;;

        *)

            fail 'Usage: sh tools/vmware.sh [--action test|start|stop] [--media iso|disk] [--timeout SECONDS] [--vmrun PATH]'

        ;;

    esac

done

case $action in

    test|start|stop)

    ;;

    *)

        fail 'Invalid VMware action'

    ;;

esac

case $media in

    iso)

        name=Iso

    ;;

    disk)

        name=Disk

    ;;

    *)

        fail 'Invalid boot media'

    ;;

esac

case $timeout in

    ''|*[!0-9]*)

        fail 'Timeout must be an integer from 10 to 300'

    ;;

esac

timeout=$(printf '%s' "$timeout" | sed 's/^0*//')
timeout=${timeout:-0}
[ "$timeout" -ge 10 ] && [ "$timeout" -le 300 ] || fail 'Timeout must be from 10 to 300 seconds'

if [ -z "$vmrun" ]; then

    vmrun=$(command -v vmrun || true)

    if [ -z "$vmrun" ] && [ "$platform" = windows ]; then

        vmrun=$(cygpath -u 'C:\Program Files\VMware\VMware Workstation\vmrun.exe')

        if [ ! -x "$vmrun" ]; then

            vmrun=$(cygpath -u 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe')

        fi

    fi

fi

[ -n "$vmrun" ] || fail 'VMware vmrun is missing; use --vmrun PATH'

if [ "$platform" = windows ]; then

    vmrun=$(cygpath -u "$vmrun")

fi

command -v "$vmrun" >/dev/null 2>&1 || fail 'VMware vmrun is missing; use --vmrun PATH'

directory=$project/zig-out/vm/$name
vmx=$(native_path "$directory/granite.vmx")
serial=$directory/serial.log
iso=$project/zig-out/granite.iso
disk=$project/zig-out/granite.img

if [ "$action" = stop ]; then

    "$vmrun" stop "$vmx" hard
    exit 0

fi

[ -f "$iso" ] && [ -f "$disk" ] || fail 'Build the media with tools/build.sh first'
running=$("$vmrun" list) || fail 'Cannot query VMware'

if printf '%s\n' "$running" | tr -d '\r' | tr '\\' '/' | grep -Fxi -e "$vmx" >/dev/null; then

    fail 'The GraniteOS VM is already running. Stop it first.'

fi

mkdir -p "$directory"
rm -f "$serial"

if [ "$media" = disk ]; then

    cp "$disk" "$directory/disk.img"
    sectors=$(($(wc -c < "$disk") / 512))

    cat > "$directory/disk.vmdk" <<EOF
# Disk DescriptorFile
version=1
encoding="UTF-8"
CID=fffffffe
parentCID=ffffffff
createType="monolithicFlat"
RW $sectors FLAT "disk.img" 0
ddb.adapterType = "ide"
ddb.geometry.cylinders = "132"
ddb.geometry.heads = "16"
ddb.geometry.sectors = "63"
EOF

    device='sata0:0.fileName = "disk.vmdk"'

else

    device="sata0:0.deviceType = \"cdrom-image\"
sata0:0.fileName = \"$(native_path "$iso")\""

fi

cat > "$directory/granite.vmx" <<EOF
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "21"
displayName = "GraniteOS 3 Boot"
guestOS = "other-64"
firmware = "efi"
uefi.secureBoot.enabled = "FALSE"
memsize = "256"
numvcpus = "1"
powerType.powerOff = "hard"
powerType.reset = "hard"
sata0.present = "TRUE"
sata0:0.present = "TRUE"
$device
sata0:0.startConnected = "TRUE"
serial0.present = "TRUE"
serial0.fileType = "file"
serial0.fileName = "$(native_path "$serial")"
serial0.yieldOnMsrRead = "TRUE"
serial0.startConnected = "TRUE"
floppy0.present = "FALSE"
ethernet0.present = "FALSE"
usb.present = "FALSE"
sound.present = "FALSE"
gui.lastPoweredViewMode = "windowed"
msg.autoAnswer = "TRUE"
uuid.action = "create"
EOF

if [ "$action" = start ]; then

    "$vmrun" start "$vmx" gui
    printf 'Serial log: %s\n' "$serial"
    exit 0

fi

started=false

cleanup() {

    result=$?
    trap - 0

    if [ "$started" = true ]; then

        "$vmrun" stop "$vmx" hard || printf '%s\n' 'Warning: Could not stop the test VM' >&2

    fi

    exit "$result"

}

trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM

"$vmrun" start "$vmx" nogui
started=true
deadline=$(($(date +%s) + timeout))
while [ "$(date +%s)" -lt "$deadline" ]; do

    if [ -f "$serial" ]; then

        if grep -Fq ': error: ' "$serial"; then

            cat "$serial" >&2
            fail 'VMware boot failed'

        fi

        if grep -Fq 'kernel: ready' "$serial"; then

            grep -Fq 'boot: firmware released' "$serial" &&
                grep -Fq 'boot: handoff ready' "$serial" || fail 'Incomplete firmware handoff'

            cat "$serial"
            printf '%s\n' 'VMware boot test passed.'
            exit 0

        fi

    fi

    sleep 1

done

fail "Boot timed out after $timeout seconds. Inspect $directory/vmware.log and $serial"
