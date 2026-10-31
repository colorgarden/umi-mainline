#!/usr/bin/env python3
"""lp-info.py —— 只读解析 Android super 分区（LP metadata）里的逻辑分区表。

    python3 lp-info.py                    # 列分区（名字/大小/extent 数）
    python3 lp-info.py vendor             # 打印 vendor 的 dm-linear 表行
    python3 lp-info.py --extents vendor   # 打印每个 extent 的 (sector, count)
    python3 lp-info.py --desc             # 打印四张表的描述符（排错用）

只读：open(..., "rb") + seek，不对 /dev 做任何写操作。
"""
import struct
import sys

DEV = "/dev/disk/by-partlabel/super"

GEOM_MAGIC = b"gDla"          # 0x616c4467
HDR_MAGIC_BARE = b"0PL"       # 0x414c5030 的前三字节（第四字节是 major 低位）


def read_at(f, off, n):
    f.seek(off)
    buf = b""
    while len(buf) < n:
        chunk = f.read(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


def find_geometry(f):
    for off in (4096, 8192, 0):
        if read_at(f, off, 4) == GEOM_MAGIC:
            g = read_at(f, off, 52)
            max_size, slots, block = struct.unpack_from("<III", g, 40)
            return off, max_size, slots, block
    raise SystemExit("没找到 LP geometry")


def find_header(f, geom_off, max_size, slots):
    base = geom_off + 4096
    for slot in range(slots):
        for extra in (0, 4096):
            off = base + slot * max_size + extra
            if read_at(f, off, 3) == HDR_MAGIC_BARE:
                return slot, off
    raise SystemExit("没找到 LP metadata header")


def parse_header(f, off):
    major, minor = struct.unpack("<HH", read_at(f, off + 4, 4))
    header_size, = struct.unpack("<I", read_at(f, off + 8, 4))
    desc = {}
    for name, doff in (("partitions", 80), ("extents", 92),
                       ("groups", 104), ("block_devices", 116)):
        if doff + 12 > header_size:
            continue
        o, n, esz = struct.unpack("<III", read_at(f, off + doff, 12))
        desc[name] = (o, n, esz)
    return dict(off=off, major=major, minor=minor,
                header_size=header_size, desc=desc)


def table(f, hdr, key):
    o, n, esz = hdr["desc"][key]
    # 描述符里的 offset 是相对「表区起点」= header 末尾，不是相对 header 起点
    raw = read_at(f, hdr["off"] + hdr["header_size"] + o, n * esz)
    return [raw[i * esz:(i + 1) * esz] for i in range(n)]


def main(argv):
    want = None
    for a in argv:
        if not a.startswith("--"):
            want = a

    with open(DEV, "rb", buffering=0) as f:
        geom_off, max_size, slots, block = find_geometry(f)
        slot, hdr_off = find_header(f, geom_off, max_size, slots)
        hdr = parse_header(f, hdr_off)
        print(f"# super: geometry@0x{geom_off:x} max_size={max_size} slots={slots} block={block}")
        print(f"# active slot={slot} header@0x{hdr_off:x} v{hdr['major']}.{hdr['minor']}")
        if "--desc" in argv:
            for k, v in hdr["desc"].items():
                print(f"#   {k:14s} offset={v[0]:6d} num_entries={v[1]:4d} entry_size={v[2]}")

        parts = table(f, hdr, "partitions")
        exts = table(f, hdr, "extents")
        pso = hdr["desc"]["partitions"][2]
        eso = hdr["desc"]["extents"][2]
        print(f"# entry_size: partition={pso} extent={eso}; "
              f"partitions={len(parts)} extents={len(exts)}")

        rows = []
        for rec in parts:
            name = rec[0:36].rstrip(b"\x00").decode(errors="replace")
            attr, first, num, grp = struct.unpack_from("<IIII", rec, 36)
            sectors = 0
            ex = []
            for i in range(num):
                if first + i >= len(exts):
                    break
                nsec, ttype, tdata, tsource = struct.unpack("<QIQI", exts[first + i][:24])
                sectors += nsec
                ex.append((nsec, ttype, tdata, tsource))
            rows.append((name, sectors, ex, attr))

        if want is None:
            print(f"# {'name':22s} {'size':>10s}  extents  attr")
            for name, sectors, ex, attr in sorted(rows):
                print(f"  {name:22s} {sectors * 512 / 1048576:9.1f}M {len(ex):8d}  0x{attr:x}")
            return 0

        for name, sectors, ex, attr in rows:
            if name != want:
                continue
            print(f"# {name}: {sectors * 512 / 1048576:.1f} MiB, {len(ex)} extent(s), attr=0x{attr:x}")
            for nsec, ttype, tdata, tsource in ex:
                print(f"  sectors={nsec} type={ttype} target_sector={tdata} source_dev={tsource}")
            return 0
        print(f"!! 没有分区 {want}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
