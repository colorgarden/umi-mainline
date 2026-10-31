#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
bt-debug-trace.py —— 给 6.12 的 net/bluetooth/hci_sync.c + hci_core.c 插临时
pr_info，定位 “hci0 起来了但没有 mgmt index / bluetoothctl 看不到” 卡在哪一步。

用法（在 WSL 里，路径默认 /root/linux）：
    python3 patches/bt-debug-trace.py            # 打补丁
    python3 patches/bt-debug-trace.py --revert   # 还原

⚠ 诊断用，定位完必须 --revert。镜像里不要留。

判读方法（dmesg | grep umi-bt）：
    setup ret=0        → qca_setup 成功（hci0 debugfs 里的 `ibs` 就是它的产物）
    init1(ret=..)      → hci_init1_sync（Reset + br_init1）
    init_sync=..       → 整个 HCI init 的最终返回值
    power_on open=..   → hci_dev_do_open 的返回值，负数就是这里失败的
"""

import sys

MARK = "umi-bt"
SYNC = "/root/linux/net/bluetooth/hci_sync.c"
CORE = "/root/linux/net/bluetooth/hci_core.c"

EDITS = {
    SYNC: [
        # setup 的返回
        (
            "\tif (hdev->setup)\n"
            "\t\tret = hdev->setup(hdev);\n",
            "\tif (hdev->setup)\n"
            "\t\tret = hdev->setup(hdev);\n"
            '\tpr_info("[' + MARK + '] %s setup ret=%d\\n", hdev->name, ret);\n',
        ),
        # 未配置判定
        (
            "\tif (hci_dev_test_flag(hdev, HCI_UNCONFIGURED))\n"
            "\t\treturn hci_unconf_init_sync(hdev);\n",
            '\tpr_info("[' + MARK + '] %s unconf=%d ext_cfg=%d\\n", hdev->name,\n'
            "\t\thci_dev_test_flag(hdev, HCI_UNCONFIGURED),\n"
            "\t\ttest_bit(HCI_QUIRK_EXTERNAL_CONFIG, &hdev->quirks));\n"
            "\tif (hci_dev_test_flag(hdev, HCI_UNCONFIGURED))\n"
            "\t\treturn hci_unconf_init_sync(hdev);\n",
        ),
        # init1：Reset + br_init1
        (
            "\treturn hci_init_stage_sync(hdev, br_init1);\n",
            "\terr = hci_init_stage_sync(hdev, br_init1);\n"
            '\tpr_info("[' + MARK + '] %s init1(ret=%d)\\n", hdev->name, err);\n'
            "\treturn err;\n",
        ),
        # init_sync 的 init2..init4
        (
            "\terr = hci_init2_sync(hdev);\n"
            "\tif (err < 0)\n"
            "\t\treturn err;\n",
            "\terr = hci_init2_sync(hdev);\n"
            '\tpr_info("[' + MARK + '] %s init2=%d\\n", hdev->name, err);\n'
            "\tif (err < 0)\n"
            "\t\treturn err;\n",
        ),
        (
            "\terr = hci_init3_sync(hdev);\n"
            "\tif (err < 0)\n"
            "\t\treturn err;\n",
            "\terr = hci_init3_sync(hdev);\n"
            '\tpr_info("[' + MARK + '] %s init3=%d\\n", hdev->name, err);\n'
            "\tif (err < 0)\n"
            "\t\treturn err;\n",
        ),
        (
            "\terr = hci_init4_sync(hdev);\n"
            "\tif (err < 0)\n"
            "\t\treturn err;\n",
            "\terr = hci_init4_sync(hdev);\n"
            '\tpr_info("[' + MARK + '] %s init4=%d\\n", hdev->name, err);\n'
            "\tif (err < 0)\n"
            "\t\treturn err;\n",
        ),
        # hci_dev_init_sync 两段结果
        (
            "\tret = hci_dev_setup_sync(hdev);\n",
            "\tret = hci_dev_setup_sync(hdev);\n"
            '\tpr_info("[' + MARK + '] %s setup_sync=%d\\n", hdev->name, ret);\n',
        ),
        (
            "\t\t\tret = hci_init_sync(hdev);\n"
            "\t\t\tif (!ret && hdev->post_init)\n",
            "\t\t\tret = hci_init_sync(hdev);\n"
            '\t\t\tpr_info("[' + MARK + '] %s init_sync=%d\\n", hdev->name, ret);\n'
            "\t\t\tif (!ret && hdev->post_init)\n",
        ),
        # hci_dev_open_sync 的总结果
        (
            "done:\n"
            "\treturn ret;\n"
            "}\n",
            "done:\n"
            '\tpr_info("[' + MARK + '] %s open_sync=%d up=%d setup=%d unconf=%d bdaddr=%pM\\n",\n'
            "\t\thdev->name, ret, test_bit(HCI_UP, &hdev->flags),\n"
            "\t\thci_dev_test_flag(hdev, HCI_SETUP),\n"
            "\t\thci_dev_test_flag(hdev, HCI_UNCONFIGURED), &hdev->bdaddr);\n"
            "\treturn ret;\n"
            "}\n",
        ),
    ],
    CORE: [
        (
            "\terr = hci_dev_do_open(hdev);\n"
            "\tif (err < 0) {\n",
            "\terr = hci_dev_do_open(hdev);\n"
            '\tpr_info("[' + MARK + '] %s power_on open=%d\\n", hdev->name, err);\n'
            "\tif (err < 0) {\n",
        ),
        (
            "\tif (hci_dev_test_and_clear_flag(hdev, HCI_SETUP)) {\n",
            '\tpr_info("[' + MARK + '] %s idx: setup=%d unconf=%d rfkill=%d bdaddr=%pM\\n",\n'
            "\t\thdev->name, hci_dev_test_flag(hdev, HCI_SETUP),\n"
            "\t\thci_dev_test_flag(hdev, HCI_UNCONFIGURED),\n"
            "\t\thci_dev_test_flag(hdev, HCI_RFKILLED), &hdev->bdaddr);\n"
            "\tif (hci_dev_test_and_clear_flag(hdev, HCI_SETUP)) {\n",
        ),
    ],
}


def apply():
    total = 0
    for path, edits in EDITS.items():
        src = open(path, encoding="utf-8").read()
        if MARK in src:
            print(f"{path}: already patched")
            continue
        for old, new in edits:
            n = src.count(old)
            if n != 1:
                print(f"!! {path}: 期望命中 1 次，实际 {n} 次 -> {old.splitlines()[0]!r}")
                return 2
            src = src.replace(old, new, 1)
            total += 1
        open(path, "w", encoding="utf-8").write(src)
        print(f"{path}: patched")
    print(f"total insertions: {total}")
    return 0


def revert():
    for path in EDITS:
        lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
        keep, dropped, skipping = [], 0, False
        for ln in lines:
            if MARK in ln:
                dropped += 1
                # 这条 pr_info 可能占多行：继续吞到以 ; 结尾的行为止
                skipping = not ln.rstrip("\n").rstrip().endswith(";")
                continue
            if skipping:
                skipping = not ln.rstrip("\n").rstrip().endswith(";")
                continue
            keep.append(ln)
        open(path, "w", encoding="utf-8").write("".join(keep))
        print(f"{path}: removed {dropped} lines")
    return 0


if __name__ == "__main__":
    sys.exit(revert() if "--revert" in sys.argv else apply())
