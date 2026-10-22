"""Prospectively fixed byte-volume inputs; no converter invocation or tuning."""
import sys
sys.dont_write_bytecode = True
import argparse
import ctypes
import hashlib
import json
import os
import stat
import time
from pathlib import Path

MIB = 1024 * 1024
PINS = {
    "corpus.json": "621DC9106835EB3274659A08F033DA4B74EF7CCE9A58846E4B01788C866CFE34",
    "flat-unicode.xes": "6BE15ABCC35C4BDF755F27307C93B0B5E4E5F90C7D715FCC4B57DC07A503516F",
    "flat-unicode.csv": "F14031CC8FCDF5119AFFAF1C2490D54B779A0929754DEE6DDF8D6280971E2905",
    "flat-unicode.manual-core.json": "6E50B95CD9CE56D2B52C099BBCFB59E20AEBF128466BDA76ACD3697D7D7FB64B",
}


def digest(path, deadline=None):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        while data := stream.read(65536):
            if deadline is not None and time.monotonic() >= deadline:
                raise TimeoutError("input preparation deadline")
            result.update(data)
    return result.hexdigest().upper()


def contained(workspace, path, must_exist=True):
    if not workspace.is_absolute() or not path.is_absolute():
        raise ValueError("absolute paths required")
    workspace = Path(os.path.abspath(workspace))
    path = Path(os.path.abspath(path))
    relative = path.relative_to(workspace)
    current = workspace
    for part in (None, *relative.parts):
        if part is not None:
            current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            if not must_exist and current == path:
                break
            raise
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
            raise ValueError("workspace reparse or symbolic link refused")
    return path


def private_directory(path):
    """Check actual owner/DACL on Windows, or owner/mode on POSIX."""
    if os.name != "nt":
        info = path.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise PermissionError("private directory owner/mode")
        return
    from ctypes import wintypes as w
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    security = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel.GetCurrentProcess.restype = w.HANDLE
    kernel.CloseHandle.argtypes = [w.HANDLE]
    kernel.LocalFree.argtypes = [w.HLOCAL]
    security.OpenProcessToken.argtypes = [w.HANDLE, w.DWORD, ctypes.POINTER(w.HANDLE)]
    security.GetTokenInformation.argtypes = [w.HANDLE, w.DWORD, w.LPVOID, w.DWORD, ctypes.POINTER(w.DWORD)]
    security.GetNamedSecurityInfoW.argtypes = [w.LPWSTR, w.DWORD, w.DWORD, ctypes.POINTER(w.LPVOID), w.LPVOID, ctypes.POINTER(w.LPVOID), w.LPVOID, ctypes.POINTER(w.LPVOID)]
    security.GetNamedSecurityInfoW.restype = w.DWORD
    security.GetAce.argtypes = [w.LPVOID, w.DWORD, ctypes.POINTER(w.LPVOID)]
    security.EqualSid.argtypes = [w.LPVOID, w.LPVOID]
    token = w.HANDLE()
    descriptor, owner, dacl = w.LPVOID(), w.LPVOID(), w.LPVOID()
    if not security.OpenProcessToken(kernel.GetCurrentProcess(), 8, ctypes.byref(token)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        size = w.DWORD()
        security.GetTokenInformation(token, 1, None, 0, ctypes.byref(size))
        if size.value < ctypes.sizeof(w.LPVOID) or size.value > 65536:
            raise PermissionError("token user size")
        buffer = ctypes.create_string_buffer(size.value)
        if not security.GetTokenInformation(token, 1, buffer, size, ctypes.byref(size)):
            raise ctypes.WinError(ctypes.get_last_error())
        user_sid = ctypes.cast(buffer, ctypes.POINTER(w.LPVOID))[0]
        error = security.GetNamedSecurityInfoW(str(path), 1, 5, ctypes.byref(owner), None, ctypes.byref(dacl), None, ctypes.byref(descriptor))
        if error:
            raise ctypes.WinError(error)
        if not owner or not dacl or not security.EqualSid(owner, user_sid):
            raise PermissionError("private directory owner or DACL")
        # ACL.AceCount lies at byte offset 4; one current-user full-control ACE.
        if ctypes.c_ushort.from_address(dacl.value + 4).value != 1:
            raise PermissionError("private directory ACE count")
        ace = w.LPVOID()
        if not security.GetAce(dacl, 0, ctypes.byref(ace)):
            raise ctypes.WinError(ctypes.get_last_error())
        ace_type = ctypes.c_ubyte.from_address(ace.value).value
        mask = ctypes.c_uint32.from_address(ace.value + 4).value
        if ace_type != 0 or mask & 0x1F01FF != 0x1F01FF or not security.EqualSid(ace.value + 8, user_sid):
            raise PermissionError("private directory allow/current-user/full-control")
    finally:
        if descriptor:
            kernel.LocalFree(descriptor)
        kernel.CloseHandle(token)


def fresh_private(workspace, output):
    output = contained(workspace, output, must_exist=False)
    output.relative_to(workspace / ".local" / "sprint21" / "root")
    private_directory(output.parent)
    output.mkdir(mode=0o777 if os.name == "nt" else 0o700)
    private_directory(output)
    return output


def save(path, value):
    with path.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, ensure_ascii=False, sort_keys=True, indent=2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    deadline = time.monotonic() + 25
    workspace = contained(args.workspace, args.workspace)
    output = fresh_private(workspace, args.output)
    try:
        frozen = workspace / "fixtures" / "conversions"
        sources = {}
        for name, expected in PINS.items():
            path = contained(workspace, frozen / name)
            if path.stat().st_size > 25 * MIB or digest(path, deadline) != expected:
                raise ValueError("frozen input pin mismatch")
            sources[name] = path.read_bytes()
        assert len(sources["flat-unicode.xes"]) == 430
        assert len(sources["flat-unicode.csv"]) == 125
        rows = []
        fixed = {
            "control.xes": sources["flat-unicode.xes"],
            "expected.csv": sources["flat-unicode.csv"],
            "expected-core.json": sources["flat-unicode.manual-core.json"],
        }
        for name, data in fixed.items():
            with (output / name).open("xb") as stream:
                stream.write(data)
        with (output / "padded.xes").open("xb") as stream:
            stream.write(sources["flat-unicode.xes"])
            remaining = 18 * MIB - len(sources["flat-unicode.xes"])
            block = b" " * 65536
            while remaining:
                if time.monotonic() >= deadline:
                    raise TimeoutError("input generation deadline")
                piece = block[:min(remaining, len(block))]
                stream.write(piece)
                remaining -= len(piece)
        total = 0
        for name in (*fixed, "padded.xes"):
            path = output / name
            size = path.stat().st_size
            total += size
            if size > 25 * MIB or total > 40 * MIB:
                raise ValueError("input generation byte budget")
            rows.append({"file": name, "bytes": size, "sha256": digest(path, deadline)})
        save(output / "manifest.json", {
            "schema_version": 1, "status": "FIXED_BEFORE_MEASUREMENT", "source_pins": PINS,
            "source_bytes": 430, "manual_csv_bytes": 125, "padded_bytes": 18 * MIB,
            "padding": "ASCII spaces appended after the unchanged 430-byte XES document",
            "workload_scope": "BYTE_VOLUME_ONLY: one trace, two events; not worst-case semantic complexity",
            "converter_executed": False, "expected_core": json.loads(sources["flat-unicode.manual-core.json"]),
            "files": rows, "total_file_bytes_without_manifest": total,
        })
        if time.monotonic() >= deadline:
            raise TimeoutError("input preparation deadline")
    except Exception as error:
        save(output / "failure.json", {"status": "FAILED", "exception": type(error).__name__, "message": str(error)})
        raise


if __name__ == "__main__":
    main()
