# GraniteOS 3
A practical, everyday operating system written in Zig. Currently in development.

Requires Zig 0.15.2 on `PATH`, Python 3, Git Bash (or another Windows `sh`), and
VMware Workstation.

```sh
sh tools/vmware.sh run
sh tools/vmware.sh test
```

`run` builds, boots, and attaches to the Obsidian shell; Ctrl+] disconnects
and stops the VM. `test` runs the host tests, then the kernel, service, and
shell acceptance checks. Both accept `--media disk`, `--cpus N`, and
`--memory MB`.

Each VM gets a second SATA disk holding the GraniteOS volume. `run` keeps it
between sessions (`zig-out/vm/run-<media>/data.img`); `test` starts it blank
and checks that files survive a power cycle.

A blank volume has no accounts: the shell runs setup as `nobody`, and
`useradd NAME` creates the first administrator. From then on the shell asks
for a login. `install` (administrators, or anyone during setup) copies
GraniteOS onto the first GPT disk with a FAT32 EFI system partition and at
least 64 MiB of unpartitioned space, adds a GraniteOS partition there, and
puts a GraniteOS entry first in the firmware boot order; existing partitions
are never moved or resized. `test` also installs onto a disk holding a
stand-in OS and boots it without the live media.
