#!/usr/bin/env python3
"""在手机上直接问 mgmt：配置/未配置的 index 列表分别是啥。
用法： python3 /tmp/mgmt-probe.py
"""
import socket
import struct
import sys

AF_BLUETOOTH = 31
HCI_CHANNEL_CONTROL = 3

MGMT_OP_READ_INDEX_LIST = 0x0003
MGMT_OP_READ_INFO = 0x0004
MGMT_OP_READ_UNCONF_INDEX_LIST = 0x0036
MGMT_INDEX_NONE = 0xFFFF


def open_sock():
    s = socket.socket(AF_BLUETOOTH, socket.SOCK_RAW, 1)  # BTPROTO_HCI
    s.bind(("00:00:00:00:00:00", HCI_CHANNEL_CONTROL))
    s.settimeout(3)
    return s


def cmd(s, opcode, index=MGMT_INDEX_NONE, params=b""):
    pkt = struct.pack("<HHH", opcode, index, len(params)) + params
    s.send(pkt)
    while True:
        data = s.recv(4096)
        ev, plen = struct.unpack_from("<HH", data, 0)
        payload = data[4:4 + plen]
        if len(payload) < 6:
            continue
        r_op, r_idx, r_len = struct.unpack_from("<HHH", payload, 0)
        if r_op != opcode:
            continue
        status = payload[6] if r_len >= 1 else 0xFF
        return status, payload[7:7 + max(0, r_len - 1)]


def main():
    s = open_sock()
    for name, op in (("READ_INDEX_LIST", MGMT_OP_READ_INDEX_LIST),
                     ("READ_UNCONF_INDEX_LIST", MGMT_OP_READ_UNCONF_INDEX_LIST)):
        try:
            st, data = cmd(s, op)
        except socket.timeout:
            print(f"{name}: timeout")
            continue
        n = struct.unpack_from("<H", data, 0)[0] if len(data) >= 2 else -1
        idx = [struct.unpack_from("<H", data, 2 + 2 * i)[0] for i in range(max(0, n))]
        print(f"{name}: status=0x{st:02x} n={n} indices={idx}")

    # 对 index 0 直接 READ_INFO，看内核怎么答
    try:
        st, data = cmd(s, MGMT_OP_READ_INFO, 0)
        print(f"READ_INFO(0): status=0x{st:02x} len={len(data)}")
        if st == 0 and len(data) >= 8:
            bdaddr = data[0:6]
            version = struct.unpack_from("<I", data, 6)[0]
            print("  bdaddr(raw le)=", ":".join(f"{b:02x}" for b in reversed(bdaddr)),
                  "version=0x%08x" % version)
    except socket.timeout:
        print("READ_INFO(0): timeout")


if __name__ == "__main__":
    sys.exit(main())
