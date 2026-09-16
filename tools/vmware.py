"""Run the disposable GraniteOS VMware acceptance machines."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


ROOT = Path(__file__).resolve().parent.parent
MARKERS = (
    "boot: firmware released",
    "boot: handoff ready",
    "kernel: memory protected",
    "kernel: page isolation and allocation rollback passed",
    "kernel: all processors online",
    "kernel: IPC and capability checks passed",
    "kernel: fault isolation passed",
    "kernel: process memory reclaimed",
    "kernel: ready",
    "services: ready",
    "services: supervisor recovered; children adopted",
    "services: recovery and application APIs passed",
)


def vmrun_path(explicit):
    candidate = explicit or os.environ.get("VMRUN") or shutil.which("vmrun")
    if candidate:
        return str(candidate)
    for prefix in ("ProgramFiles", "ProgramFiles(x86)"):
        candidate = Path(os.environ.get(prefix, "C:/Program Files")) / "VMware/VMware Workstation/vmrun.exe"
        if candidate.is_file():
            return str(candidate)
    raise RuntimeError("VMware vmrun is missing; use --vmrun PATH")


def command(vmrun, *args):
    result = subprocess.run([vmrun, *map(str, args)], capture_output=True, text=True, timeout=45)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def configure(directory, args):
    image = ROOT / "zig-out" / ("granite.iso" if args.media == "iso" else "granite.img")
    if not image.is_file():
        raise RuntimeError("Build boot media first")
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "result.json").unlink(missing_ok=True)
    serial = directory / "serial.log"
    serial.write_text("")
    terminal = directory / "terminal.log"
    terminal.write_text("")
    pipe = rf"\\.\pipe\GraniteOS-{args.media}-{args.cpus}-{args.memory}"
    terminal_device = (
        f'serial1.fileType = "pipe"\nserial1.fileName = "{pipe}"\n'
        'serial1.pipe.endPoint = "server"\nserial1.tryNoRxLoss = "TRUE"'
        if args.terminal == "pipe" else
        f'serial1.fileType = "file"\nserial1.fileName = "{terminal.as_posix()}"'
    )
    if args.media == "disk":
        shutil.copyfile(image, directory / "disk.img")
        sectors = image.stat().st_size // 512
        (directory / "disk.vmdk").write_text(
            '# Disk DescriptorFile\nversion=1\nencoding="UTF-8"\n'
            'CID=fffffffe\nparentCID=ffffffff\ncreateType="monolithicFlat"\n'
            f'RW {sectors} FLAT "disk.img" 0\n'
            'ddb.adapterType = "ide"\nddb.geometry.cylinders = "132"\n'
            'ddb.geometry.heads = "16"\nddb.geometry.sectors = "63"\n'
        )
        device = 'sata0:0.fileName = "disk.vmdk"'
    else:
        device = f'sata0:0.deviceType = "cdrom-image"\nsata0:0.fileName = "{image.as_posix()}"'
    vmx = directory / "granite.vmx"
    vmx.write_text(f''' .encoding = "UTF-8"
config.version = "8"
virtualHW.version = "21"
displayName = "GraniteOS 3 Kernel Test"
guestOS = "other-64"
firmware = "efi"
uefi.secureBoot.enabled = "FALSE"
memsize = "{args.memory}"
numvcpus = "{args.cpus}"
cpuid.coresPerSocket = "{args.cpus}"
powerType.powerOff = "hard"
powerType.reset = "hard"
sata0.present = "TRUE"
sata0:0.present = "TRUE"
{device}
sata0:0.startConnected = "TRUE"
serial0.present = "TRUE"
serial0.fileType = "file"
serial0.fileName = "{serial.as_posix()}"
serial0.yieldOnMsrRead = "TRUE"
serial0.startConnected = "TRUE"
serial1.present = "TRUE"
{terminal_device}
serial1.yieldOnMsrRead = "TRUE"
serial1.startConnected = "TRUE"
floppy0.present = "FALSE"
ethernet0.present = "FALSE"
usb.present = "FALSE"
sound.present = "FALSE"
msg.autoAnswer = "TRUE"
uuid.action = "create"
'''.lstrip())
    return vmx, serial, pipe


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--action", choices=("test", "start", "stop"), default="test")
    parser.add_argument("--media", choices=("iso", "disk"), default="iso")
    parser.add_argument("--expect", choices=("ready", "reboot", "idle"), default="ready")
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--memory", type=int, default=256)
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--vmrun")
    parser.add_argument("--terminal", choices=("file", "pipe"), default="file")
    parser.add_argument("--terminal-test", action="store_true")
    args = parser.parse_args()
    if args.terminal_test:
        args.terminal = "pipe"
        if args.expect == "reboot" or args.action != "test":
            parser.error("--terminal-test requires --action test and a non-reboot expectation")
    if args.terminal == "pipe" and os.name != "nt":
        parser.error("The terminal pipe client currently requires Windows")
    if not 1 <= args.cpus <= 64 or not 128 <= args.memory <= 8192 or not 10 <= args.timeout <= 300:
        parser.error("Require 1–64 CPUs, 128–8192 MB, and a 10–300 second timeout")
    vmrun = vmrun_path(args.vmrun)
    directory = ROOT / "zig-out/vm" / f"Kernel-{args.media}-{args.cpus}-{args.memory}-{args.expect}"
    vmx = directory / "granite.vmx"
    if args.action == "stop":
        command(vmrun, "stop", vmx, "hard")
        return
    running = command(vmrun, "list").replace("\\", "/").lower().splitlines()
    if vmx.as_posix().lower() in running:
        raise RuntimeError("This test VM is already running; stop it first")
    vmx, serial, pipe = configure(directory, args)
    command(vmrun, "start", vmx, "gui" if args.action == "start" else "nogui")
    if args.action == "start":
        print(f"Serial log: {serial}")
        if args.terminal == "pipe":
            print(f'Connect with: python tools/terminal.py --pipe "{pipe}"')
        return
    start = time.monotonic()
    try:
        while time.monotonic() - start < args.timeout:
            output = serial.read_text(errors="replace")
            if args.expect == "reboot":
                passed = "kernel: rebooting after kernel failure" in output and output.count("boot: GraniteOS 3") >= 2
            else:
                if ": error: " in output or "Exception Type" in output or "services: acceptance failed" in output:
                    raise RuntimeError(output)
                markers = MARKERS if args.expect == "ready" else ("kernel: all processors online", "kernel: ready", "services: ready")
                passed = all(marker in output for marker in markers)
                if args.expect == "ready":
                    passed = passed and output.count("kernel: verified cpu = ") == args.cpus
            if passed:
                if args.terminal_test:
                    from terminal import smoke
                    smoke(pipe, directory / "terminal.log")
                output = serial.read_text(errors="replace")
                if "services: acceptance failed" in output or ": error: " in output:
                    raise RuntimeError(output)
                report = vars(args) | {"passed": True, "seconds": round(time.monotonic() - start, 2)}
                (directory / "result.json").write_text(json.dumps(report, indent=2) + "\n")
                print(output, end="")
                print(f"VMware {args.expect} test passed ({args.cpus} CPUs, {args.memory} MB, {args.media}).")
                return
            time.sleep(0.2)
        raise RuntimeError(f"VMware test timed out. Inspect {serial}\n{output}")
    finally:
        command(vmrun, "stop", vmx, "hard")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error)) from error
