"""Owned counter calibration only; no process-mining engine or dependencies."""
import json
import os
import pathlib
import sys
import time

directory = pathlib.Path(sys.argv[1])
nonce = sys.argv[2]
if len(nonce) != 32 or not all(c in "0123456789abcdef" for c in nonce):
    raise ValueError("nonce")
def publish(name, record):
    temporary = directory / (name + ".pending")
    with temporary.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(record, stream, separators=(",", ":"))
        stream.flush()
        os.fsync(stream.fileno())
    os.rename(temporary, directory / (name + ".json"))


publish("boot", {"pid": os.getpid(), "nonce": nonce})
if sys.stdin.readline().rstrip("\n\r") != "GO " + nonce:
    raise ValueError("go")
allocated = 32 * 1024 * 1024
data = bytearray(allocated)
for offset in range(0, allocated, 4096):
    data[offset] = 123
start = time.perf_counter_ns()
checksum = 0
while time.perf_counter_ns() - start < 150_000_000:
    checksum = (checksum + 17) % 1_000_003
record = {"pid": os.getpid(), "nonce": nonce, "allocated_bytes": allocated,
          "touched_pages": allocated // 4096, "checksum": checksum}
publish("ready", record)
if sys.stdin.readline().rstrip("\n\r") != "EXIT " + nonce:
    raise ValueError("exit")
assert len(data) == allocated and data[0] == 123
print(json.dumps({"status": "complete", "pid": os.getpid(), "nonce": nonce}))
