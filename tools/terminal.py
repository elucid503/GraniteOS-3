"""Connect to the guest COM2 terminal through a VMware Windows named pipe."""

import argparse
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import re
import sys
import time


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
            self.handle = self.kernel.CreateFileW(name, 0xC0000000, 0, None, 3, 0, None)
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
            if response.endswith(b"granite> "):
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
        require("echo TEXT" in command(b"help\r"), "help")
        permissions = command(b"permissions\r")
        require(all(f"\r\n{name}\r\n" in permissions for name in ("ipc", "memory", "time")), "visible permission array")
        require("ports" not in permissions and "management" not in permissions, "application permission limits")
        require("\r\nhello services\r\n" in command(b"echo hello services\r"), "echo")
        require("\r\nfixed\r\n" in command(b"echo fixex\x08d\r"), "backspace")
        require("^C\r\ngranite> " in command(b"echo discarded\x03"), "line cancellation")
        require("unknown command" in command(b"unknown\r"), "unknown command")
        identity = re.findall(r"\r\n(\d+)\r\n", command(b"id\r"))
        require(bool(identity), "application identity")
        require("\r\n42\r\n" in command(b"ping\r"), "helper API")
        require("supervisor will recover" in command(b"crash helper\r"), "service crash")
        time.sleep(0.5)
        require("\r\n42\r\n" in command(b"ping\r"), "helper recovery")
        require(re.findall(r"\r\n(\d+)\r\n", command(b"id\r")) == identity, "shell survived restart")
        require("serial: " in command(b"services\r"), "discovery")
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pipe", required=True)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("Windows is required")
    import msvcrt

    pipe = Pipe(args.pipe)
    print("Connected to GraniteOS COM2. Ctrl+] disconnects.")
    try:
        while True:
            try:
                data = pipe.read()
                if data:
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                if msvcrt.kbhit():
                    key = msvcrt.getwch()
                    if key == "\x1d":
                        break
                    if key in ("\x00", "\xe0"):
                        msvcrt.getwch()
                        continue
                    pipe.write(key.encode("ascii", errors="ignore"))
                time.sleep(0.005)
            except KeyboardInterrupt:
                pipe.write(b"\x03")
    finally:
        pipe.close()


if __name__ == "__main__":
    main()
