P = "/root/linux/sound/soc/codecs/cs35l41.c"
MARK = "umi-cs35l41-sysclk"
OLD = """\tfsindex = cs35l41_get_fs_mon_config_index(freq);
\tif (fsindex < 0) {
\t\tdev_err(cs35l41->dev, "Invalid CLK Config freq: %u\\n", freq);
\t\treturn -EINVAL;
\t}

\tdev_dbg(cs35l41->dev, "Set DAI sysclk %d\\n", freq);

\tif (freq <= 6144000) {
\t\t/* Use the lookup table */
\t\tfs1_val = cs35l41_fs_mon[fsindex].fs1;
\t\tfs2_val = cs35l41_fs_mon[fsindex].fs2;
\t} else {
\t\t/* Use hard-coded values */
\t\tfs1_val = 0x10;
\t\tfs2_val = 0x24;
\t}
"""
NEW = """\tdev_dbg(cs35l41->dev, "Set DAI sysclk %d\\n", freq);

\tif (freq <= 6144000) {
\t\tfsindex = cs35l41_get_fs_mon_config_index(freq);
\t\tif (fsindex < 0) {
\t\t\tdev_err(cs35l41->dev, "Invalid CLK Config freq: %u\\n", freq);
\t\t\treturn -EINVAL;
\t\t}
\t\tfs1_val = cs35l41_fs_mon[fsindex].fs1;
\t\tfs2_val = cs35l41_fs_mon[fsindex].fs2;
\t} else {
\t\t/* MARK: 96kHz/8x32bit TDM 的 BCLK 是 24.576MHz，fs_mon 表
\t\t * 只到 12.288MHz；这一档窗口固定、不会被读，不要查表，
\t\t * 否则 -EINVAL 会让 BE 起不来（用户态写 EIO）。 */
\t\tfs1_val = 0x10;
\t\tfs2_val = 0x24;
\t}
""".replace("MARK", MARK)
t = open(P).read()
if MARK in t:
    print("已打过")
elif OLD in t:
    open(P, "w").write(t.replace(OLD, NEW, 1))
    print("cs35l41 sysclk 补丁完成")
else:
    print("锚点缺失")
