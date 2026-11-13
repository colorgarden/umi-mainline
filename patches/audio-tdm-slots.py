#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
audio-tdm-slots.py —— 给 6.12 的 sm8250 机器驱动补上 TDM 槽位配置。

为什么需要：Mi 10 的扬声器/听筒是两颗 CS35L41，挂在 **TERTIARY TDM** 上。
主线 sm8250 机器驱动只做 `qcom_snd_sdw_hw_params()`，从不调用
`snd_soc_dai_set_tdm_slot()`/`set_channel_map()`，于是 q6afe 里
`tdm->nslots_per_frame` 一直是 0，ADSP 直接拒绝：

    qcom-q6afe: cmd = 0x100ef returned error = 0x2
    qcom-q6afe: AFE enable for port 0x9020 failed -22
    q6afe-dai: fail to start AFE port 38

补的内容照 armbian 0510 的做法：
  * 8 个 32-bit 槽（帧内两个音频通道落在字节偏移 0 和 4）
  * 播放：rx_mask = (1<<channels)-1，cpu channel map = {0,4}
  * 每颗 amp 各占一个槽：RX1/RX2 = {!j, j}，否则两颗都读 slot 0
  * 回采（TX）方向同样处理，tx_mask = (1<<channels)-1

用法（WSL 里，默认 /root/linux）：
    python3 patches/audio-tdm-slots.py            # 打补丁
    python3 patches/audio-tdm-slots.py --revert   # 还原
"""

import sys

PATH = "/root/linux/sound/soc/qcom/sm8250.c"
MARK = "umi-tdm-slots"

FUNC = r'''/* ---- %s: TDM 槽位（CS35L41 x2） ---- */
static const unsigned int sm8250_tdm_slot_offset[2] = { 0, 4 };

static int sm8250_tdm_set_slots(struct snd_pcm_substream *substream,
				struct snd_pcm_hw_params *params)
{
	struct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
	struct snd_soc_dai *cpu_dai = snd_soc_rtd_to_cpu(rtd, 0);
	int channels = params_channels(params);
	const int slots = 8;
	const int slot_width = 32;
	struct snd_soc_dai *codec_dai;
	int ret, j;

	switch (cpu_dai->id) {
	case TERTIARY_TDM_RX_0:
		ret = snd_soc_dai_set_tdm_slot(cpu_dai, 0, (1 << channels) - 1,
					       slots, slot_width);
		if (ret < 0) {
			dev_err(rtd->dev, "%%s: cpu tdm slot failed: %%d\n", __func__, ret);
			return ret;
		}

		ret = snd_soc_dai_set_channel_map(cpu_dai, 0, NULL, channels,
						  sm8250_tdm_slot_offset);
		if (ret < 0) {
			dev_err(rtd->dev, "%%s: cpu channel map failed: %%d\n", __func__, ret);
			return ret;
		}

		/* 每颗 amp 单独给 RX1/RX2 槽，否则两颗都读 slot 0 */
		for_each_rtd_codec_dais(rtd, j, codec_dai) {
			unsigned int slot[2] = { !j, j };

			ret = snd_soc_dai_set_channel_map(codec_dai, 0, NULL, 2, slot);
			if (ret < 0) {
				dev_err(rtd->dev, "%%s: codec %%d map failed: %%d\n",
					__func__, j, ret);
				return ret;
			}
		}
		break;

	case TERTIARY_TDM_TX_0:
		ret = snd_soc_dai_set_tdm_slot(cpu_dai, (1 << channels) - 1, 0,
					       slots, slot_width);
		if (ret < 0) {
			dev_err(rtd->dev, "%%s: cpu tdm slot (tx) failed: %%d\n", __func__, ret);
			return ret;
		}

		ret = snd_soc_dai_set_channel_map(cpu_dai, channels,
						  sm8250_tdm_slot_offset, 0, NULL);
		if (ret < 0) {
			dev_err(rtd->dev, "%%s: cpu channel map (tx) failed: %%d\n", __func__, ret);
			return ret;
		}

		for_each_rtd_codec_dais(rtd, j, codec_dai) {
			unsigned int slot[2] = { !j, j };

			ret = snd_soc_dai_set_channel_map(codec_dai, 2, slot, 0, NULL);
			if (ret < 0) {
				dev_err(rtd->dev, "%%s: codec %%d tx map failed: %%d\n",
					__func__, j, ret);
				return ret;
			}
		}
		break;

	default:
		break;
	}

	return 0;
}
''' % MARK

CALL = """\tret = sm8250_tdm_set_slots(substream, params);
\tif (ret < 0)
\t\treturn ret;

"""

ANCHOR_FUNC = """static int sm8250_snd_hw_params(struct snd_pcm_substream *substream,
				struct snd_pcm_hw_params *params)
{
	struct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
	struct snd_soc_dai *cpu_dai = snd_soc_rtd_to_cpu(rtd, 0);
	struct sm8250_snd_data *pdata = snd_soc_card_get_drvdata(rtd->card);

"""

ANCHOR_CALL = "\tstruct sm8250_snd_data *pdata = snd_soc_card_get_drvdata(rtd->card);\n\n\treturn qcom_snd_sdw_hw_params"


FIXUP_OLD = """	rate->min = rate->max = 48000;
	channels->min = channels->max = 2;
	snd_mask_set_format(fmt, SNDRV_PCM_FORMAT_S16_LE);

	return 0;
}
"""

FIXUP_NEW = """	struct snd_soc_dai *cpu_dai = snd_soc_rtd_to_cpu(rtd, 0);

	rate->min = rate->max = 48000;
	channels->min = channels->max = 2;
	snd_mask_set_format(fmt, SNDRV_PCM_FORMAT_S16_LE);

	/*
	 * ---- %s: Tertiary TDM 用 96 kHz / S24_LE ----
	 *
	 * 两颗 CS35L41 挂在 TERTIARY TDM 上，帧是 8 个 32-bit 槽，
	 * 96 kHz 时 BCLK = 8 * 32 * 96000 = 24.576 MHz。厂商系统里这个
	 * 端口就是这个配置（mixer dump 显示 KHZ_96 / S24_LE / Two）。
	 *
	 * 保持默认的 48 kHz/S16_LE 时，AFE 会在启动端口时返回 -EINVAL，
	 * 用户态看到的是 aplay 的 "pcm_write: Input/output error"。
	 */
	switch (cpu_dai->id) {
	case TERTIARY_TDM_RX_0:
	case TERTIARY_TDM_TX_0:
		rate->min = rate->max = 96000;
		channels->min = channels->max = 2;
		snd_mask_none(fmt);
		snd_mask_set_format(fmt, SNDRV_PCM_FORMAT_S24_LE);
		break;
	default:
		break;
	}

	return 0;
}
""" % MARK


def patch(text):
    if MARK in text:
        print("已经打过补丁，跳过")
        return text

    assert ANCHOR_FUNC in text, "找不到 sm8250_snd_hw_params 的锚点"
    text = text.replace(ANCHOR_FUNC, FUNC + "\n" + ANCHOR_FUNC, 1)

    # 在 qcom_snd_sdw_hw_params 调用前插入我们的调用，并把 return 拆开
    old = ("\tstruct sm8250_snd_data *pdata = snd_soc_card_get_drvdata(rtd->card);\n"
           "\n\treturn qcom_snd_sdw_hw_params(substream, params, &pdata->sruntime[cpu_dai->id]);\n")
    new = ("\tstruct sm8250_snd_data *pdata = snd_soc_card_get_drvdata(rtd->card);\n"
           "\tint ret;\n"
           "\n"
           + CALL +
           "\treturn qcom_snd_sdw_hw_params(substream, params, &pdata->sruntime[cpu_dai->id]);\n")
    assert old in text, "找不到 hw_params 函数体（格式变了？）"
    text = text.replace(old, new, 1)

    assert FIXUP_OLD in text, "找不到 be_hw_params_fixup 的尾部"
    text = text.replace(FIXUP_OLD, FIXUP_NEW, 1)
    return text


def revert(text):
    lines = text.splitlines(keepends=True)
    out = []
    skip = False
    for line in lines:
        if MARK in line and line.lstrip().startswith("/*"):
            skip = True
        if skip:
            if line.rstrip().endswith("}") and "sm8250_tdm_set_slots" not in line and skip is True:
                # 函数体结束
                if line.strip() == "}":
                    skip = False
            continue
        out.append(line)
    text = "".join(out)
    text = text.replace(CALL, "")
    text = text.replace("\tint ret;\n\t\n", "")
    return text


def main():
    txt = open(PATH).read()
    new = revert(txt) if "--revert" in sys.argv else patch(txt)
    if new == txt:
        return
    open(PATH, "w").write(new)
    print(("还原" if "--revert" in sys.argv else "打补丁") + "完成: " + PATH)


if __name__ == "__main__":
    main()
