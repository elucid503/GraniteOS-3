# Goals/Requirements

## Functional

- Run on bare-metal x86_64, targeting Intel Coffee Lake and newer processors.
- Initially support a Coffee Lake desktop with Intel UHD 630 graphics, SATA storage, and USB keyboard and mouse.
- Support VMware testing on an Intel x86_64 host, including its virtual storage, display, input, and network devices.
- Boot through UEFI from removable media and installed storage.
- Support installation alongside an existing OS without overwriting its data.
- Provide serial output during initial development and for diagnostics.
- Separate the system into kernel, services, and applications.
- Keep scheduling, memory management, process isolation, and control of hardware access in the kernel.
- Run drivers and system helpers in isolated service processes with restricted hardware access.
- Provide application APIs for accessing services and communicating with other applications.
- Support preemptive multitasking, multiple cores, and interprocess communication.
- Restart failed services and drivers without interrupting unrelated applications.
- Provide a graphical desktop exceeding GraniteOS 2 in responsiveness, rendering, and usability.
- Use GPU acceleration wherever supported for desktop rendering and graphics operations.
- Provide a terminal, shell, file manager, text/code editor, image viewer, settings, and system monitoring.
- Provide the remaining GraniteOS 2 desktop utilities; application names remain undecided.
- Support document editing, code editing, and audio/video playback.
- Support SATA storage, USB keyboard and mouse, Ethernet, and audio output.
- Provide TCP/IP networking, automatic network configuration, DNS, and HTTP/HTTPS transfers.
- Provide persistent files and directories without arbitrary fixed file-count, file-size, or volume-capacity limits.
- Decide the filesystem during implementation; Strata concepts remain an option, with no old-format compatibility requirement.
- Support multiple accounts, authenticated login, administrator privileges, private home directories, logout, and screen locking.
- Enforce access permissions between users and applications.
- Provide shutdown and reboot, including reboot after kernel failure.
- Stretch: Apple M1 and newer bare-metal support, platform boot integration, and ARM VMware testing on Apple Silicon.
- Stretch: NVMe storage and Wi-Fi.
- Stretch: IPv6 networking.
- Stretch: Bluetooth, battery management, and suspend/resume.
- Stretch: Filesystem integrity across unexpected power loss.
- Stretch: SDK, software distribution, and package management.
- Stretch: Online communication and collaborative workflows.
- Stretch: Browser exploration.
- Stretch: Windows application compatibility through the services layer.

## Non-functional

- Fresh implementation with no reused GraniteOS 1 or 2 source code; external code and libraries are permitted.
- Use Zig, with assembly and external components where necessary.
- Follow GraniteOS 2's CLAUDE.md code style and source-directory conventions.
- Keep common code independent of CPU architecture, hardware platform, and OS frameworks.
- Permit external boot components for platform integration.
- Require no POSIX, Linux, or GraniteOS 2 application compatibility.
- Operate independently of a host OS or VM on supported physical hardware.
- Prefer VMware for VM testing; avoid QEMU wherever practical.
- Validate physical hardware support on physical hardware; VM results establish virtual-device support only.
- Keep idle memory usage below 512 MB; application workloads may use more.
- Target bootloader entry to usable graphical login in under 10 seconds; this target is flexible.
- Recover from service failures without rebooting the kernel; kernel failures may require rebooting.
- Judge remaining performance and usability targets at completion.
- Stretch items are deferred goals, not initial-release requirements.
