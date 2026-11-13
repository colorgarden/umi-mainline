#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
cs35l41-ignore-pup-poll.py —— 让 CS35L41 上电不等 PUP/PDN 状态位。

现象（umi 实测）：
    cs35l41 3-0040: ASoC: PRE_PMU: RCV Main AMP event failed: -110
    cs35l41 3-0042: ASoC: PRE_PMU: LCV Main AMP event failed: -110

-110 = ETIMEDOUT：`cs35l41_set_pll`/`cs35l41_set_dsp_clock` 里的
`regmap_read_poll_timeout(CS35L41_IRQ1_STATUS1, int_status & pup_pdn_mask)`
在 umi 这两颗 amp 上永远等不到状态位（固件/时序差异），于是 DAPM 的
PRE_PMU 失败、功放不打开。

armbian 的 0042 补丁做法就是**忽略这次轮询的返回值**（照抄），状态位清掉后
继续。这里做同样的事，并把两处（INT_MDSYNC / INT_MDSYNC_EN 与 INT_BOOST）
都改掉。

用法：
    python3 patches/cs35l41-ignore-pup-poll.py            # 打补丁
    python3 patches/cs35l41-ignore-pup-poll.py --revert   # 还原
"""

import sys

PATH = "/root/linux/sound/soc/codecs/cs35l41-lib.c"
MARK = "umi-cs35l41-pup"

OLD = """\t\tret = regmap_read_poll_timeout(regmap, CS35L41_IRQ1_STATUS1,
\t\t\t\t\tint_status, int_status & pup_pdn_mask,
\t\t\t\t\t1000, 100000);
\t\tif (ret)
\t\t\tdev_err(dev, "Enable(%d) failed: %d\\n", enable, ret);
"""

NEW = """\t\t/* %s: umi 上这两颗 CS35L41 永远等不到 PUP/PDN 状态位，
\t\t * PRE_PMU 会以 -ETIMEDOUT 失败、功放不打开。照 armbian 0042 的做法
\t\t * 忽略这次轮询（状态位下面照样清）。 */
\t\tregmap_read_poll_timeout(regmap, CS35L41_IRQ1_STATUS1,
\t\t\t\t\tint_status, int_status & pup_pdn_mask,
\t\t\t\t\t1000, 100000);
""" % MARK

REVERT = """\t\tret = regmap_read_poll_timeout(regmap, CS35L41_IRQ1_STATUS1,
\t\t\t\t\tint_status, int_status & pup_pdn_mask,
\t\t\t\t\t1000, 100000);
\t\tif (ret)
\t\t\tdev_err(dev, "Enable(%d) failed: %d\\n", enable, ret);
"""


def main():
    txt = open(PATH).read()
    revert = "--revert" in sys.argv

    if revert:
        if MARK not in txt:
            print("没有打过补丁")
            return
        # 把带注释的那段换回原来的检查
        start = txt.index("\t\t/* %s:" % MARK)
        end = txt.index("1000, 100000);", start) + len("1000, 100000);\n")
        txt = txt[:start] + REVERT + txt[end:]
        open(PATH, "w").write(txt)
        print("还原完成")
        return

    if MARK in txt:
        print("已经打过补丁，跳过")
        return

    n = txt.count(OLD)
    if n == 0:
        print("找不到锚点，代码可能变了")
        sys.exit(1)
    txt = txt.replace(OLD, NEW)
    open(PATH, "w").write(txt)
    print("打补丁完成（替换 %d 处）: %s" % (n, PATH))


if __name__ == "__main__":
    main()
