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
```
