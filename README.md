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

Services form a distinct kernel-recognized layer with explicit, readable
permission arrays enforced by the kernel. COM1 carries diagnostics; COM2
provides the terminal and shell. [Service architecture and API](docs/SERVICES.md).
