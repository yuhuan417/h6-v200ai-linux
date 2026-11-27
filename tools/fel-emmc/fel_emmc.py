#!/usr/bin/env python3
"""v200ai FEL eMMC tool.

Drives a board in FEL mode: a small SPL stub initialises DRAM and exports a
function table, then a payload running from DRAM does the eMMC work.  Nothing
here depends on a bootable U-Boot or on the eMMC content.

Examples:
    ./fel_emmc.py info
    ./fel_emmc.py read  16 2032 bootarea.bin
    ./fel_emmc.py write 16 bootarea.bin
    ./fel_emmc.py flash images/firmware.img --lba 0
    ./fel_emmc.py dump  0 1

The stub is built from a U-Boot tree (see README.md); pass --stub if it is not
at the default location.
"""

import argparse
import os
import struct
import subprocess
import sys

API_ADDR = 0x400FF000
PAR_ADDR = 0x400FE000
PAYLOAD_ADDR = 0x42000000
PAYLOAD_ENTRY = PAYLOAD_ADDR + 0x10
MAGIC_ADDR = 0x400FFFF0
MARKER_ADDR = 0x400FFFD0

MAGIC_PAYLOAD = 0x5041594C  # 'PAYL'
MAGIC_ENTRY = 0x504C5931    # 'PLY1'
PAR_MAGIC = 0x50505230      # 'PPR0'

PAR_FMT = "<14I"
PAR_NAMES = ["magic", "op", "sect", "cnt", "dst", "clock", "result", "err",
             "got", "lba", "t0", "t1", "dev", "part"]

OP_INIT = 0
OP_READ = 1
OP_WRITE = 2
OP_READ_CHUNKED = 3
OP_WRITE_CHUNKED = 4

MAX_BLKS = int(os.environ.get('FEL_EMMC_CHUNK', '512'))  # blocks per payload call
SECTOR = 512

HERE = os.path.dirname(os.path.abspath(__file__))


class FelError(RuntimeError):
    pass


def fel(*args, timeout=300):
    cmd = ["sudo", "sunxi-fel"] + [str(a) for a in args]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if res.returncode != 0:
        raise FelError(f"sunxi-fel {' '.join(map(str, args))}: "
                       f"{(res.stderr or res.stdout).strip()}")
    return res.stdout


def writel(addr, value):
    fel("writel", hex(addr), value)


def readl(addr):
    out = fel("readl", hex(addr)).strip()
    return int(out, 0) if out else None


class Tool:
    def __init__(self, stub, payload):
        self.stub = stub
        self.payload = payload
        self._dram_ready = False

    def ensure_dram(self):
        if self._dram_ready:
            return
        # First run must not have the payload magic set; DRAM is not writable
        # before this run, so the stub is entered without any parameters.
        fel("spl", self.stub)
        # DRAM is up now: make sure no stale magic can trigger a payload call.
        writel(MAGIC_ADDR, 0)
        self._dram_ready = True

    def run(self, op, sect=0, cnt=0, dst=0, clock=0, dev=1, part=0,
            read_back=None, timeout=300):
        self.ensure_dram()
        par = struct.pack(PAR_FMT, PAR_MAGIC, op, sect, cnt, dst, clock,
                          0, 0, 0, 0, 0, 0, dev, part)
        with open("/tmp/fel_emmc_par.bin", "wb") as f:
            f.write(par)
        fel("write", hex(PAYLOAD_ADDR), self.payload)
        fel("write", hex(PAR_ADDR), "/tmp/fel_emmc_par.bin")
        args = ["writel", hex(MAGIC_ADDR), MAGIC_PAYLOAD,
                "spl", self.stub,
                "readl", hex(MARKER_ADDR),
                "read", hex(PAR_ADDR), str(struct.calcsize(PAR_FMT)),
                "/tmp/fel_emmc_out.bin"]
        if read_back:
            args += ["read", hex(dst), str(read_back),
                     "/tmp/fel_emmc_data.bin"]
        res = fel(*args, timeout=timeout)
        marker = int(res.strip().splitlines()[0], 0) if res.strip() else 0
        with open("/tmp/fel_emmc_out.bin", "rb") as f:
            out = struct.unpack(PAR_FMT, f.read())
        status = dict(zip(PAR_NAMES, out))
        if marker != 0xAAAA1234:
            raise FelError(f"payload did not run (marker 0x{marker:08x})")
        if status["result"] != 0:
            raise FelError(f"payload failed: result={status['result']} "
                           f"err=-{status['err']} got={status['got']}")
        return status

    def info(self, dev=1, part=0):
        return self.run(OP_INIT, dev=dev, part=part)

    def read(self, lba, count, out_path, dev=1, part=0, chunked=False):
        buf = bytearray()
        done = 0
        while done < count:
            step = min(MAX_BLKS, count - done)
            op = OP_READ_CHUNKED if chunked else OP_READ
            st = self.run(op, sect=lba + done, cnt=step, dst=0x43000000,
                          dev=dev, part=part, read_back=step * SECTOR)
            with open("/tmp/fel_emmc_data.bin", "rb") as f:
                buf += f.read(step * SECTOR)
            done += step
            print(f"\rread {done}/{count} blocks", end="", file=sys.stderr)
        print("", file=sys.stderr)
        with open(out_path, "wb") as f:
            f.write(buf)
        return len(buf)

    def write(self, lba, data, dev=1, part=0, chunked=False):
        total = (len(data) + SECTOR - 1) // SECTOR
        done = 0
        while done < total:
            step = min(MAX_BLKS, total - done)
            chunk = data[done * SECTOR:(done + step) * SECTOR]
            chunk += b"\x00" * (step * SECTOR - len(chunk))
            with open("/tmp/fel_emmc_chunk.bin", "wb") as f:
                f.write(chunk)
            self.ensure_dram()
            fel("write", hex(0x43000000), "/tmp/fel_emmc_chunk.bin")
            op = OP_WRITE_CHUNKED if chunked else OP_WRITE
            self.run(op, sect=lba + done, cnt=step, dst=0x43000000,
                     dev=dev, part=part)
            done += step
            print(f"\rwrote {done}/{total} blocks", end="", file=sys.stderr)
        print("", file=sys.stderr)
        return total

    def dump(self, lba, count, dev=1, part=0):
        self.read(lba, count, "/tmp/fel_emmc_dump.bin", dev=dev, part=part,
                  chunked=True)
        with open("/tmp/fel_emmc_dump.bin", "rb") as f:
            data = f.read()
        for off in range(0, len(data), 16):
            row = data[off:off + 16]
            hexs = " ".join(f"{b:02x}" for b in row)
            text = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
            print(f"{lba * SECTOR + off:08x}  {hexs:<47}  {text}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stub", default=os.path.join(HERE, "spl", "sunxi-spl.bin"))
    ap.add_argument("--payload", default=os.path.join(HERE, "payload.bin"))
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("info", help="initialise mmc and report media size")
    p.add_argument("--part", type=lambda x: int(x, 0), default=0)

    for name in ("read", "dump"):
        p = sub.add_parser(name, help="read blocks")
        p.add_argument("lba", type=lambda x: int(x, 0))
        p.add_argument("count", type=lambda x: int(x, 0))
        if name == "read":
            p.add_argument("out")
        p.add_argument("--part", type=lambda x: int(x, 0), default=0)
        p.add_argument("--chunk", action="store_true")

    p = sub.add_parser("write", help="write blocks")
    p.add_argument("lba", type=lambda x: int(x, 0))
    p.add_argument("file")
    p.add_argument("--part", type=lambda x: int(x, 0), default=0)
    p.add_argument("--chunk", action="store_true")

    p = sub.add_parser("flash", help="write an image, optionally verifying")
    p.add_argument("image")
    p.add_argument("--lba", type=lambda x: int(x, 0), default=0)
    p.add_argument("--part", type=lambda x: int(x, 0), default=0)
    p.add_argument("--verify", action="store_true")

    args = ap.parse_args()
    tool = Tool(args.stub, args.payload)

    if args.cmd == "info":
        st = tool.info(part=args.part)
        blocks = st["lba"]
        print(f"mmc_init ok  blocks={blocks}  size={blocks * SECTOR} bytes  "
              f"dev={st['dev']}  part={st['part']}")
        return 0

    if args.cmd == "read":
        n = tool.read(args.lba, args.count, args.out, part=args.part,
                      chunked=args.chunk)
        print(f"read {n} bytes -> {args.out}")
        return 0

    if args.cmd == "dump":
        tool.dump(args.lba, args.count, part=args.part)
        return 0

    if args.cmd == "write":
        with open(args.file, "rb") as f:
            data = f.read()
        n = tool.write(args.lba, data, part=args.part, chunked=args.chunk)
        print(f"wrote {n} blocks from {args.file}")
        return 0

    if args.cmd == "flash":
        with open(args.image, "rb") as f:
            data = f.read()
        n = tool.write(args.lba, data, part=args.part)
        print(f"flashed {n} blocks ({len(data)} bytes) at lba {args.lba}")
        if args.verify:
            tool.read(args.lba, n, "/tmp/fel_emmc_verify.bin",
                      part=args.part, chunked=True)
            with open("/tmp/fel_emmc_verify.bin", "rb") as f:
                back = f.read()
            ok = back[:len(data)] == data
            print(f"verify: {'OK' if ok else 'MISMATCH'}")
            return 0 if ok else 1
        return 0

    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except FelError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(2)
