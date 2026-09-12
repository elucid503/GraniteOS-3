# Tasks

## Milestone 1: Boot

- [ ] Fresh Zig project following the established code style in AGENTS.md
- [ ] Architecture- and platform-independent foundations.
- [ ] x86_64 UEFI boot from removable media.
- [ ] Serial diagnostics.
- [ ] Boot in VMware and on the initial Coffee Lake desktop.

## Milestone 2: Kernel

- [ ] Physical and virtual memory management.
- [ ] Process isolation and controlled hardware access.
- [ ] Preemptive scheduling and multicore execution.
- [ ] Interprocess communication.
- [ ] Application loading and execution.
- [ ] Kernel failure diagnostics and reboot.

## Milestone 3: Services

- [ ] Isolated drivers and system helpers.
- [ ] Restricted service access to hardware and memory.
- [ ] Service startup, supervision, and restart.
- [ ] Recovery without interrupting unrelated applications.
- [ ] Application-to-service and application-to-application APIs.
- [ ] Terminal and shell.

## Milestone 4: Storage and Accounts

- [ ] SATA and VMware storage support.
- [ ] Filesystem selection and persistent files/directories.
- [ ] File and volume sizes without arbitrary fixed limits.
- [ ] Multiple accounts, login, and administrator privileges.
- [ ] Private home directories and access permissions.
- [ ] Logout and screen locking.
- [ ] Installed boot alongside an existing OS, preserving its data.
- [ ] Shutdown and reboot.

## Milestone 5: Graphics and Desktop

- [ ] USB and VMware keyboard/mouse support.
- [ ] Intel UHD 630 and VMware display support.
- [ ] GPU-accelerated rendering wherever supported.
- [ ] Graphical login, desktop, and window management.
- [ ] Desktop responsiveness, rendering, and usability improvements over GraniteOS 2.
- [ ] File manager, editor, image viewer, settings, and system monitoring.
- [ ] Remaining GraniteOS 2 desktop utilities with independently implemented code.

## Milestone 6: Workflows

- [ ] Ethernet and VMware networking support.
- [ ] TCP/IP, automatic configuration, DNS, and HTTP/HTTPS transfers.
- [ ] Audio output on supported physical and virtual hardware.
- [ ] Document and code editing.
- [ ] Audio/video playback.

## Milestone 7: Initial Release

- [ ] Complete-system validation in VMware and on the Coffee Lake desktop.
- [ ] Service-crash isolation and recovery validation.
- [ ] User separation and permission validation.
- [ ] Installation and existing-OS coexistence validation.
- [ ] Idle memory usage below 512 MB.
- [ ] Flexible boot-to-login target below 10 seconds.
- [ ] Completed-system performance and usability assessment.

## Milestone 8: Stretch — Apple Silicon

- [ ] AArch64 kernel and platform support.
- [ ] Apple boot integration.
- [ ] Apple M1 and newer hardware drivers and GPU acceleration.
- [ ] ARM VMware validation on Apple Silicon.
- [ ] Physical Apple Silicon validation.

## Milestone 9: Stretch — Hardware and Reliability

- [ ] NVMe storage and Wi-Fi.
- [ ] IPv6.
- [ ] Bluetooth and battery management.
- [ ] Suspend/resume.
- [ ] Filesystem integrity across unexpected power loss.

## Milestone 10: Stretch — Software Ecosystem

- [ ] SDK, software distribution, and package management.
- [ ] Online communication and collaborative workflows.
- [ ] Browser exploration.
- [ ] Windows application compatibility service.
