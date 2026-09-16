# GraniteOS 3
A practical, everyday operating system written in Zig. Currently in development.

```sh
sh tools/setup.sh
sh tools/build.sh --optimize ReleaseSafe
sh tools/vmware.sh --action test --media iso
sh tools/vmware.sh --action test --media disk
```

On Windows, the VMware runner can also be invoked directly:

```sh
python tools/vmware.py --media iso --cpus 2
python tools/vmware.py --media disk --cpus 4 --memory 512
python tools/vmware.py --media iso --cpus 2 --terminal-test
```

Services form a distinct kernel-recognized layer with explicit, readable
permission arrays enforced by the kernel. COM1 carries diagnostics; COM2
provides the terminal and shell. [Service architecture and API](docs/SERVICES.md).

For an interactive session without injected test failures:

```sh
sh tools/build.sh --optimize ReleaseSafe --self-test false
python tools/vmware.py --action start --media iso --terminal pipe
```

Run the printed `tools/terminal.py` command in a Windows terminal. Ctrl+]
disconnects. Stop the VM with `python tools/vmware.py --action stop --media iso`.
