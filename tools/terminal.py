"""Talk to the guest COM2 terminal through a VMware Windows named pipe."""

import ctypes
from ctypes import wintypes
import os
import queue
from pathlib import Path
import re
import subprocess
import sys
import threading
import time

PROMPT = b"obsidian [/]> "
KEYS = {"H": b"\x1b[A", "P": b"\x1b[B", "M": b"\x1b[C", "K": b"\x1b[D", "G": b"\x1b[H", "O": b"\x1b[F", "S": b"\x1b[3~"}


class Pipe:
    def __init__(self, name, timeout=10):
        if os.name != "nt":
            raise RuntimeError("Windows named pipes are required")
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.CreateFileW.argtypes = (
            wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
            wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
        )
        self.kernel.CreateFileW.restype = wintypes.HANDLE
        self.kernel.PeekNamedPipe.argtypes = (
            wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
            ctypes.c_void_p, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p,
        )
        for name_io in ("ReadFile", "WriteFile"):
            function = getattr(self.kernel, name_io)
            function.argtypes = (
                wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p,
            )
        self.kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        deadline = time.monotonic() + timeout
        while True:
            self.handle = self.kernel.CreateFileW(rf"\\.\pipe\{name}", 0xC0000000, 0, None, 3, 0, None)
            if self.handle != ctypes.c_void_p(-1).value:
                break
            if time.monotonic() >= deadline:
                raise ctypes.WinError(ctypes.get_last_error())
            time.sleep(0.05)

    def close(self):
        self.kernel.CloseHandle(self.handle)

    def read(self):
        available = wintypes.DWORD()
        if not self.kernel.PeekNamedPipe(self.handle, None, 0, None, ctypes.byref(available), None):
            raise ctypes.WinError(ctypes.get_last_error())
        if not available.value:
            return b""
        buffer = ctypes.create_string_buffer(min(available.value, 4096))
        count = wintypes.DWORD()
        if not self.kernel.ReadFile(self.handle, buffer, len(buffer), ctypes.byref(count), None):
            raise ctypes.WinError(ctypes.get_last_error())
        return buffer.raw[:count.value]

    def write(self, data):
        for byte in data:
            buffer = ctypes.create_string_buffer(bytes((byte,)))
            count = wintypes.DWORD()
            if not self.kernel.WriteFile(self.handle, buffer, 1, ctypes.byref(count), None) or count.value != 1:
                raise ctypes.WinError(ctypes.get_last_error())
            time.sleep(0.015)


def smoke(name, transcript):
    pipe = Pipe(name)
    captured = bytearray()

    def command(text):
        captured.extend(pipe.read())
        pipe.write(text)
        response = bytearray()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            response.extend(pipe.read())
            if response.endswith(b"\n" + PROMPT):
                captured.extend(response)
                return response.decode("ascii", errors="replace")
            time.sleep(0.01)
        captured.extend(response)
        raise RuntimeError(f"Terminal command timed out: {text!r}\n{response!r}")

    def require(condition, detail):
        if not condition:
            raise RuntimeError(f"Terminal acceptance failed: {detail}")

    try:
        command(b"\r")
        require("Available Commands" in command(b"help\r"), "help")
        permissions = command(b"permissions\r")
        require(all(f"\r\n{name}\r\n" in permissions for name in ("ipc", "memory", "time")), "visible permission array")
        require("ports" not in permissions and "management" not in permissions, "application permission limits")
        require("\r\nhello services\r\n" in command(b"echo hello services\r"), "echo")
        require("\r\nfixed\r\n" in command(b"echo fixex\x08d\r"), "backspace")
        require("^C\r\nobsidian [/]> " in command(b"echo discarded\x03"), "line cancellation")
        require("\r\nheld\r\n" in command(b"echo hed\x1b[Dl\r"), "cursor editing")
        require("\r\nheld\r\n" in command(b"\x1b[A\r"), "history recall")
        require("\r\nipc\r\n" in command(b"perm\t\r"), "tab completion")
        require("command not found" in command(b"unknown\r"), "unknown command")
        identity = re.findall(r"\r\n(\d+)\r\n", command(b"id\r"))
        require(bool(identity), "application identity")
        require("\r\n42\r\n" in command(b"ping\r"), "helper API")
        require("supervisor will recover" in command(b"crash helper\r"), "service crash")
        time.sleep(0.5)
        require("\r\n42\r\n" in command(b"ping\r"), "helper recovery")
        require(re.findall(r"\r\n(\d+)\r\n", command(b"id\r")) == identity, "shell survived restart")
        require(re.search(r"serial +\d+", command(b"services\r")), "discovery")
        for _ in range(4):
            command(b"crash helper\r")
            time.sleep(0.5)
            if "helper unavailable" in command(b"ping\r"):
                break
        else:
            raise RuntimeError("Service restart limit was not enforced")
        time.sleep(0.5)
        require("helper unavailable" in command(b"ping\r"), "exhausted service stays offline")
        require(re.findall(r"\r\n(\d+)\r\n", command(b"id\r")) == identity, "restart exhaustion isolates failure")
        print("Interactive terminal and shell passed.")
    finally:
        Path(transcript).write_bytes(captured)
        pipe.close()


def typed():
    """Yield raw typed bytes (Ctrl+C included) from a Windows console, or from an MSYS pty when there is no console."""
    import msvcrt

    kernel = ctypes.WinDLL("kernel32")
    kernel.GetStdHandle.restype = wintypes.HANDLE
    output, source = kernel.GetStdHandle(-11), kernel.GetStdHandle(-10)
    mode = wintypes.DWORD()
    if kernel.GetConsoleMode(output, ctypes.byref(mode)):
        kernel.SetConsoleMode(output, mode.value | 4)
    if kernel.GetConsoleMode(source, ctypes.byref(mode)):
        kernel.SetConsoleMode(source, mode.value & ~1)
        try:
            while True:
                key = msvcrt.getwch() if msvcrt.kbhit() else ""
                yield KEYS.get(msvcrt.getwch(), b"") if key in ("\x00", "\xe0") else key.encode("ascii", errors="ignore")
        finally:
            kernel.SetConsoleMode(source, mode.value)

    received = queue.Queue()
    threading.Thread(target=lambda: [received.put(os.read(0, 64)) for _ in iter(int, 1)], daemon=True).start()
    subprocess.run(["stty", "raw", "-echo"], stdin=sys.stdin, stderr=subprocess.DEVNULL)
    try:
        while True:
            yield b"".join(received.get_nowait() for _ in range(received.qsize()))
    finally:
        subprocess.run(["stty", "sane"], stdin=sys.stdin, stderr=subprocess.DEVNULL)


def attach(name):
    pipe = Pipe(name, timeout=30)
    print("Connected to GraniteOS 3. Ctrl+] disconnects and stops the VM.", flush=True)
    keys = typed()
    try:
        for key in keys:
            data = pipe.read()
            if data:
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            if b"\x1d" in key:
                pipe.write(key[:key.index(b"\x1d")])
                break
            if key:
                pipe.write(key)
            else:
                time.sleep(0.005)
    finally:
        keys.close()
        pipe.close()


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["smoke"] and len(sys.argv) == 4:
            smoke(sys.argv[2], sys.argv[3])
        elif sys.argv[1:2] == ["attach"] and len(sys.argv) == 3:
            attach(sys.argv[2])
        else:
            sys.exit("Usage: terminal.py attach PIPE | smoke PIPE TRANSCRIPT")
    except (RuntimeError, OSError) as error:
        sys.exit(str(error))
