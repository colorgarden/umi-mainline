// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2024, Teguh Sobirin <teguh@sobir.in>.
 *
 * This driver is for the switch-mode battery charger power delivery
 * and boost hardware found in pm8150b and related PMICs.
 * This work based on pmi8998 charger driver by 
 * Caleb Connolly <caleb.connolly@linaro.org>
 * Should be merged with the existing charger driver in the future.
 */

#include <linux/bits.h>
#include <linux/devm-helpers.h>
#include <linux/iio/consumer.h>
#include <linux/interrupt.h>
#include <linux/kernel.h>
#include <linux/math.h>
#include <linux/minmax.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/pm_wakeirq.h>
#include <linux/of.h>
#include <linux/power_supply.h>
#include <linux/regmap.h>
#include <linux/types.h>
#include <linux/workqueue.h>

/* clang-format off */
#define BATTERY_CHARGER_STATUS_1			0x06
#define ICL_INCR_REQ_FOR_PRECHG_BIT			BIT(7)
#define ZERO_CHARGE_CURRENT_BIT				BIT(6)
#define STEP_CHARGING_STATUS_SHIFT			3
#define STEP_CHARGING_STATUS_MASK			GENMASK(5, 3)
#define BATTERY_CHARGER_STATUS_MASK			GENMASK(2, 0)

#define BATTERY_CHARGER_STATUS_2			0x07
#define DROP_IN_BATTERY_VOLTAGE_REFERENCE_BIT		BIT(7)
#define VBATT_LTET_RECHARGE_BIT				BIT(6)
#define VBATT_GTET_INHIBIT_BIT				BIT(5)
#define VBATT_GTET_FLOAT_VOLTAGE_BIT			BIT(4)
#define BATT_GT_FULL_ON_BIT				BIT(3)
#define CHARGER_ERROR_STATUS_SFT_EXPIRE_BIT		BIT(2)
#define CHARGER_ERROR_STATUS_BAT_OV_BIT			BIT(1)
#define CHARGER_ERROR_STATUS_BAT_TERM_MISSING_BIT	BIT(0)

#define BATTERY_CHARGER_STATUS_4		0x0A
#define CHARGE_CURRENT_REFERENCE_MASK		GENMASK(7, 0)

#define BATTERY_CHARGER_STATUS_7_REG		0x0D
#define BAT_TEMP_STATUS_SOFT_LIMIT_MASK		GENMASK(5, 4)
#define BAT_TEMP_STATUS_HOT_SOFT_BIT		BIT(5)
#define BAT_TEMP_STATUS_COLD_SOFT_BIT		BIT(4)
#define BAT_TEMP_STATUS_HARD_LIMIT_MASK		GENMASK(3, 2)
#define BAT_TEMP_STATUS_TOO_HOT_BIT		BIT(3)
#define BAT_TEMP_STATUS_TOO_COLD_BIT		BIT(2)
#define BAT_TEMP_STATUS_TOO_HOT_AFP_BIT		BIT(1)
#define BAT_TEMP_STATUS_TOO_COLD_AFP_BIT	BIT(0)

#define CHARGING_ENABLE_CMD			0x42
#define CHARGING_ENABLE_CMD_BIT			BIT(0)
#define CHARGING_ENABLE_POF_BIT			BIT(1)

#define CHGR_CFG2				0x51
#define EN_FAVOR_IN_BIT				BIT(5)
#define BAT_OV_ECC_BIT				BIT(4)
#define I_TERM_BIT				BIT(3)
#define AUTO_RECHG_BIT				BIT(2)
#define SOC_BASED_RECHG_BIT			BIT(1)
#define CHARGER_INHIBIT_BIT			BIT(0)

#define PRE_CHARGE_CURRENT_CFG			0x60
#define PRE_CHARGE_CURRENT_SETTING_MASK		GENMASK(2, 0)

#define FAST_CHARGE_CURRENT_CFG			0x61
#define FAST_CHARGE_CURRENT_SETTING_MASK	GENMASK(7, 0)

#define FLOAT_VOLTAGE_CFG			0x70
#define FLOAT_VOLTAGE_SETTING_MASK		GENMASK(7, 0)

#define CHARGE_RCHG_SOC_THRESHOLD_CFG_REG	0x7D
#define CHARGE_RCHG_SOC_THRESHOLD_CFG_MASK	GENMASK(7, 0)

#define ICL_STATUS				0x107
#define ICL_INPUT_CURRENT_LIMIT_MASK		GENMASK(7, 0)

#define AICL_STATUS				0x108
#define AICL_INPUT_CURRENT_LIMIT_MASK		GENMASK(7, 0)

#define POWER_PATH_STATUS				0x10B
#define P_PATH_INPUT_SS_DONE_BIT			BIT(7)
#define P_PATH_USBIN_SUSPEND_STS_BIT			BIT(6)
#define P_PATH_DCIN_SUSPEND_STS_BIT			BIT(5)
#define P_PATH_USE_USBIN_BIT				BIT(4)
#define P_PATH_USE_DCIN_BIT				BIT(3)
#define P_PATH_POWER_PATH_MASK				GENMASK(2, 1)
#define P_PATH_VALID_INPUT_POWER_SOURCE_STS_BIT		BIT(0)

#define OTG_CFG					0x153
#define OTG_RESERVED_BIT			BIT(7)
#define FAST_ROLE_SWAP_START_OPTION_BIT		BIT(6)
#define DIS_OTG_ON_TSD_BIT			BIT(5)
#define OTG_CFG_4_BIT				BIT(4)
#define EN_SOC_BASED_OTG_UVLO_BIT		BIT(3)
#define ENABLE_OTG_IN_DEBUG_MODE_BIT		BIT(2)
#define OTG_EN_SRC_CFG_BIT			BIT(1)
#define OTG_HICCUP_CNTR_RST_TIMER_SEL_BIT	BIT(0)

#define APSD_STATUS				0x307
#define APSD_STATUS_7_BIT			BIT(7)
#define HVDCP_CHECK_TIMEOUT_BIT			BIT(6)
#define SLOW_PLUGIN_TIMEOUT_BIT			BIT(5)
#define ENUMERATION_DONE_BIT			BIT(4)
#define VADP_CHANGE_DONE_AFTER_AUTH_BIT		BIT(3)
#define QC_AUTH_DONE_STATUS_BIT			BIT(2)
#define QC_CHARGER_BIT				BIT(1)
#define APSD_DTC_STATUS_DONE_BIT		BIT(0)

#define APSD_RESULT_STATUS			0x308
#define APSD_RESULT_STATUS_7_BIT		BIT(7)
#define APSD_RESULT_STATUS_MASK			GENMASK(6, 0)
#define QC_3P0_BIT				BIT(6)
#define QC_2P0_BIT				BIT(5)
#define FLOAT_CHARGER_BIT			BIT(4)
#define DCP_CHARGER_BIT				BIT(3)
#define CDP_CHARGER_BIT				BIT(2)
#define OCP_CHARGER_BIT				BIT(1)
#define SDP_CHARGER_BIT				BIT(0)

#define USBIN_INT_RT_STS_OFFSET			0x310
#define USBIN_PLUGIN_RT_STS_BIT			BIT(4)

#define USBIN_CMD_IL				0x340
#define USBIN_SUSPEND_BIT			BIT(0)

#define CMD_APSD				0x341
#define APSD_RERUN_BIT				BIT(0)

#define CMD_ICL_OVERRIDE			0x342
#define ICL_OVERRIDE_BIT			BIT(0)

/* MiCode umi-q-oss smb5-reg.h / smblib_set_usb_pd_allowed_voltage(). */
#define USBIN_ADAPTER_ALLOW_OVERRIDE		0x344
#define USBIN_ADAPTER_ALLOW_CONTINUOUS		BIT(3)

#define TYPE_C_CFG				0x358
#define BC1P2_START_ON_CC_BIT			BIT(7)

#define HVDCP_PULSE_COUNT_MAX			0x35b
#define HVDCP_PULSE_COUNT_MAX_QC2_MASK		GENMASK(7, 6)

#define USBIN_ADAPTER_ALLOW_CFG			0x360
#define USBIN_ADAPTER_ALLOW_MASK		GENMASK(3, 0)

#define USBIN_OPTIONS_1_CFG			0x362
#define HVDCP_AUTH_ALG_EN_CFG_BIT		BIT(6)
#define HVDCP_AUTONOMOUS_MODE_EN_CFG_BIT	BIT(5)
#define BC1P2_SRC_DETECT_BIT			BIT(3)
#define HVDCP_EN_BIT				BIT(2)
#define HVDCP_NO_AUTH_QC3_CFG_BIT		BIT(1)

#define USBIN_LOAD_CFG				0x365
#define ICL_OVERRIDE_AFTER_APSD_BIT		BIT(4)
#define USBIN_AICL_STEP_TIMING_SEL_MASK		GENMASK(3, 2)
#define USBIN_IN_COLLAPSE_GF_SEL_MASK		GENMASK(1, 0)

#define USBIN_ICL_OPTIONS			0x366
#define CFG_USB3P0_SEL_BIT			BIT(2)
#define USB51_MODE_BIT				BIT(1)
#define USBIN_MODE_CHG_BIT			BIT(0)

#define USBIN_CURRENT_LIMIT_CFG			0x370
#define USBIN_CURRENT_LIMIT_MASK		GENMASK(7, 0)

#define USBIN_AICL_OPTIONS_CFG			0x380
#define SUSPEND_ON_COLLAPSE_USBIN_BIT		BIT(7)
#define USBIN_AICL_PERIODIC_RERUN_EN_BIT	BIT(4)
#define USBIN_AICL_ADC_EN_BIT			BIT(3)
#define USBIN_AICL_EN_BIT			BIT(2)

#define USBIN_5V_AICL_THRESHOLD_CFG		0x381
#define USBIN_5V_AICL_THRESHOLD_CFG_MASK	GENMASK(2, 0)

#define USBIN_CONT_AICL_THRESHOLD_CFG		0x384
#define USBIN_CONT_AICL_THRESHOLD_CFG_MASK	GENMASK(5, 0)

#define DCIN_CMD_IL				0x440
#define DCIN_SUSPEND_BIT			BIT(0)

#define TYPE_C_SNK_STATUS			0x506
#define DETECTED_SRC_TYPE_MASK			GENMASK(6, 0)
#define SNK_RP_STD_DAM_BIT			BIT(6)
#define SNK_RP_1P5_DAM_BIT			BIT(5)
#define SNK_RP_3P0_DAM_BIT			BIT(4)
#define SNK_DAM_MASK				GENMASK(6, 4)
#define SNK_DAM_500MA_BIT			BIT(6)
#define SNK_DAM_1500MA_BIT			BIT(5)
#define SNK_DAM_3000MA_BIT			BIT(4)
#define SNK_RP_STD_BIT				BIT(3)
#define SNK_RP_1P5_BIT				BIT(2)
#define SNK_RP_3P0_BIT				BIT(1)
#define SNK_RP_SHORT_BIT			BIT(0)

#define TYPE_C_MODE_CFG				0x544
#define TYPEC_TRY_MODE_MASK			GENMASK(4, 3)
#define EN_TRY_SNK_BIT				BIT(4)
#define EN_TRY_SRC_BIT				BIT(3)
#define TYPEC_POWER_ROLE_CMD_MASK		GENMASK(2, 0)
#define EN_SRC_ONLY_BIT				BIT(2)
#define EN_SNK_ONLY_BIT				BIT(1)
#define TYPEC_DISABLE_CMD_BIT			BIT(0)

#define TYPEC_TYPE_C_VCONN_CONTROL		0x546
#define VCONN_EN_ORIENTATION_BIT		BIT(2)
#define VCONN_EN_VALUE_BIT			BIT(1)
#define VCONN_EN_SRC_BIT			BIT(0)

#define TYPE_C_DEBUG_ACCESS_SINK		0x54a
#define TYPEC_DEBUG_ACCESS_SINK_MASK		GENMASK(4, 0)

#define DEBUG_ACCESS_SRC_CFG			0x54C
#define EN_UNORIENTED_DEBUG_ACCESS_SRC_BIT	BIT(0)

#define TYPE_C_EXIT_STATE_CFG			0x550
#define BYPASS_VSAFE0V_DURING_ROLE_SWAP_BIT	BIT(3)
#define SEL_SRC_UPPER_REF_BIT			BIT(2)
#define EXIT_SNK_BASED_ON_CC_BIT		BIT(0)

#define TYPE_C_INTERRUPT_EN_CFG_1			0x55e
#define TYPEC_LEGACY_CABLE_INT_EN_BIT			BIT(7)
#define TYPEC_NONCOMPLIANT_LEGACY_CABLE_INT_EN_BIT	BIT(6)
#define TYPEC_TRYSOURCE_DETECT_INT_EN_BIT		BIT(5)
#define TYPEC_TRYSINK_DETECT_INT_EN_BIT			BIT(4)
#define TYPEC_CCOUT_DETACH_INT_EN_BIT			BIT(3)
#define TYPEC_CCOUT_ATTACH_INT_EN_BIT			BIT(2)
#define TYPEC_VBUS_DEASSERT_INT_EN_BIT			BIT(1)
#define TYPEC_VBUS_ASSERT_INT_EN_BIT			BIT(0)

#define BARK_BITE_WDOG_PET			0x643
#define BARK_BITE_WDOG_PET_BIT			BIT(0)

#define WD_CFG					0x651
#define WATCHDOG_TRIGGER_AFP_EN_BIT		BIT(7)
#define BARK_WDOG_INT_EN_BIT			BIT(6)
#define BITE_WDOG_INT_EN_BIT			BIT(5)
#define SFT_AFTER_WDOG_IRQ_MASK			GENMASK(4, 3)
#define WDOG_IRQ_SFT_BIT			BIT(2)
#define WDOG_TIMER_EN_ON_PLUGIN_BIT		BIT(1)
#define WDOG_TIMER_EN_BIT			BIT(0)

#define SNARL_BARK_BITE_WD_CFG			0x653
#define BITE_WDOG_DISABLE_CHARGING_CFG_BIT	BIT(7)
#define SNARL_WDOG_TIMEOUT_MASK			GENMASK(6, 4)
#define BARK_WDOG_TIMEOUT_MASK			GENMASK(3, 2)
#define BITE_WDOG_TIMEOUT_MASK			GENMASK(1, 0)

#define AICL_RERUN_TIME_CFG			0x661
#define AICL_RERUN_TIME_MASK			GENMASK(1, 0)

#define SDP_CURRENT_UA			500000
#define CDP_CURRENT_UA			3000000
#define DCP_CURRENT_UA			3300000
#define CURRENT_MAX_UA			DCP_CURRENT_UA

/* pmi8150b registers represent current in increments of 1/40th of an amp */
#define CURRENT_SCALE_FACTOR		50000
/* Experimental switch-mode path, not the BQ25970 charge-pump profile. */
#define SMB5_PPS_MIN_UV			5000000
#define SMB5_PPS_MAX_UV			9000000
#define SMB5_PPS_STEP_UV			20000
#define SMB5_PPS_STEP_UA			50000
#define SMB5_PPS_POLL_MS			1000
/* clang-format on */

enum charger_status {
	TRICKLE_CHARGE = 0,
	PRE_CHARGE,
	FAST_CHARGE,
	FULLON_CHARGE,
	TAPER_CHARGE,
	TERMINATE_CHARGE,
	INHIBIT_CHARGE,
	DISABLE_CHARGE,
};

struct smb5_register {
	u16 addr;
	u8 mask;
	u8 val;
};

/**
 * struct smb5_chip - smb5 chip structure
 * @dev:		Device reference for power_supply
 * @name:		The platform device name
 * @base:		Base address for smb5 registers
 * @regmap:		Register map
 * @batt_info:		Battery data from DT
 * @status_change_work: Worker to handle plug/unplug events
 * @cable_irq:		USB plugin IRQ
 * @wakeup_enabled:	If the cable IRQ will cause a wakeup
 * @usb_in_i_chan:	USB_IN current measurement channel
 * @usb_in_v_chan:	USB_IN voltage measurement channel
 * @chg_psy:		Charger power supply instance
 */
struct smb5_chip {
	struct device *dev;
	const char *name;
	unsigned int base;
	struct regmap *regmap;
	struct power_supply_battery_info *batt_info;

	struct delayed_work status_change_work;
	int cable_irq;
	bool wakeup_enabled;

	struct iio_channel *usb_in_i_chan;
	struct iio_channel *usb_in_v_chan;

	struct power_supply *chg_psy;
	struct power_supply *tcpm_psy;
	struct mutex pd_lock;
	bool pps_enabled;
	bool pps_active;
	bool pps_fault;
	bool user_inhibit;
	bool pd_stopping;
	int pps_error;
	int pps_voltage_uv;
	int pps_current_ua;
	int input_max_ua;
};

static enum power_supply_property smb5_properties[] = {
	POWER_SUPPLY_PROP_MANUFACTURER,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_CURRENT_MAX,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_HEALTH,
	POWER_SUPPLY_PROP_ONLINE,
	POWER_SUPPLY_PROP_USB_TYPE,
	POWER_SUPPLY_PROP_CHARGING_ENABLED,
};

static int smb5_get_prop_usb_online(struct smb5_chip *chip, int *val)
{
	unsigned int stat;
	int rc;

	rc = regmap_read(chip->regmap, chip->base + USBIN_INT_RT_STS_OFFSET, &stat);
	if (rc < 0) {
		dev_err(chip->dev, "Couldn't read USBIN_RT_STS rc=%d\n", rc);
		return rc;
	}

	*val = (stat & USBIN_PLUGIN_RT_STS_BIT) ? 1 : 0;
	return 0;
}

/*
 * Qualcomm "automatic power source detection" aka APSD
 * tells us what type of charger we're connected to.
 */
static int smb5_apsd_get_charger_type(struct smb5_chip *chip, int *val)
{
	unsigned int apsd_stat, stat;
	int usb_online = 0;
	int rc;

	rc = smb5_get_prop_usb_online(chip, &usb_online);
	if (!usb_online) {
		*val = POWER_SUPPLY_USB_TYPE_UNKNOWN;
		return rc;
	}

	rc = regmap_read(chip->regmap, chip->base + APSD_STATUS, &apsd_stat);
	if (rc < 0) {
		dev_err(chip->dev, "Failed to read apsd status, rc = %d", rc);
		return rc;
	}
	if (!(apsd_stat & APSD_DTC_STATUS_DONE_BIT)) {
		dev_err(chip->dev, "Apsd not ready");
		return -EAGAIN;
	}

	rc = regmap_read(chip->regmap, chip->base + APSD_RESULT_STATUS, &stat);
	if (rc < 0) {
		dev_err(chip->dev, "Failed to read apsd result, rc = %d", rc);
		return rc;
	}

	stat &= APSD_RESULT_STATUS_MASK;

	if (stat & CDP_CHARGER_BIT){
		*val = POWER_SUPPLY_USB_TYPE_CDP;
	} else if (stat & DCP_CHARGER_BIT){
		*val = POWER_SUPPLY_USB_TYPE_DCP;
	} else if (stat & OCP_CHARGER_BIT){
		*val = POWER_SUPPLY_USB_TYPE_DCP;
	} else if (stat & FLOAT_CHARGER_BIT){
		*val = POWER_SUPPLY_USB_TYPE_DCP;
	} else if (stat & QC_2P0_BIT){
		*val = POWER_SUPPLY_USB_TYPE_DCP;
	} else if (stat & QC_3P0_BIT){
		*val = POWER_SUPPLY_USB_TYPE_DCP;
	} else {
		*val = POWER_SUPPLY_USB_TYPE_SDP;
	}

	return 0;
}

static int smb5_get_prop_charging_enabled(struct smb5_chip *chip, int *val)
{
	unsigned int charging_enabled;
	int rc = regmap_read(chip->regmap, chip->base + CHARGING_ENABLE_CMD, &charging_enabled);
	if (rc < 0) {
		dev_err(chip->dev, "Failed to read charging enabled status, rc = %d", rc);
		return rc;
	}
	*val = charging_enabled & CHARGING_ENABLE_CMD_BIT ? 1 : 0;
	return 0;
}

static int smb5_get_prop_status(struct smb5_chip *chip, int *val)
{
	unsigned char stat[2];
	int usb_online = 0;
	int rc;

	rc = smb5_get_prop_usb_online(chip, &usb_online);
	if (!usb_online) {
		*val = POWER_SUPPLY_STATUS_DISCHARGING;
		return rc;
	}

	rc = regmap_bulk_read(chip->regmap,
			      chip->base + BATTERY_CHARGER_STATUS_1, &stat, 2);
	if (rc < 0) {
		dev_err(chip->dev, "Failed to read charging status ret=%d\n",
			rc);
		return rc;
	}

	if (stat[1] & VBATT_GTET_INHIBIT_BIT) {
		*val = POWER_SUPPLY_STATUS_NOT_CHARGING;
		return 0;
	}

	stat[0] = stat[0] & BATTERY_CHARGER_STATUS_MASK;

	switch (stat[0]) {
	case TRICKLE_CHARGE:
	case PRE_CHARGE:
	case FAST_CHARGE:
	case FULLON_CHARGE:
	case TAPER_CHARGE:
		*val = POWER_SUPPLY_STATUS_CHARGING;
		return rc;
	case DISABLE_CHARGE:
		*val = POWER_SUPPLY_STATUS_NOT_CHARGING;
		return rc;
	case TERMINATE_CHARGE:
	case INHIBIT_CHARGE:
		*val = POWER_SUPPLY_STATUS_FULL;
		return rc;
	default:
		*val = POWER_SUPPLY_STATUS_UNKNOWN;
		return rc;
	}
}

static inline int smb5_get_current_limit(struct smb5_chip *chip,
					 unsigned int *val)
{
	int rc = regmap_read(chip->regmap, chip->base + AICL_STATUS, val);

	if (rc >= 0)
		*val *= CURRENT_SCALE_FACTOR;	
	return rc;
}

static int smb5_set_current_limit(struct smb5_chip *chip, unsigned int val)
{
	unsigned char val_raw;

	if (val > 4950000) {
		dev_err(chip->dev,
			"Can't set current limit higher than 4950000uA");
		return -EINVAL;
	}
	val_raw = val / CURRENT_SCALE_FACTOR;

	return regmap_write(chip->regmap, chip->base + USBIN_CURRENT_LIMIT_CFG,
		val_raw);
}

static int smb5_set_prop_charging_enabled(struct smb5_chip *chip, unsigned int val)
{
	return regmap_update_bits(chip->regmap, chip->base + CHARGING_ENABLE_CMD,
					CHARGING_ENABLE_CMD_BIT, val ? CHARGING_ENABLE_CMD_BIT : 0);
}

static void smb5_pd_work(struct smb5_chip *chip);

static void smb5_status_change_work(struct work_struct *work)
{
	unsigned int charger_type, current_ua;
	int usb_online = 0;
	int count, rc;
	struct smb5_chip *chip;

	chip = container_of(work, struct smb5_chip, status_change_work.work);
	if (chip->tcpm_psy) {
		smb5_pd_work(chip);
		return;
	}

	smb5_get_prop_usb_online(chip, &usb_online);
	if (!usb_online)
		return;

	for (count = 0; count < 3; count++) {
		dev_dbg(chip->dev, "get charger type retry %d\n", count);
		rc = smb5_apsd_get_charger_type(chip, &charger_type);
		if (rc != -EAGAIN)
			break;
		msleep(100);
	}

	if (rc < 0 && rc != -EAGAIN) {
		dev_err(chip->dev, "get charger type failed: %d\n", rc);
		return;
	}

	if (rc < 0) {
		rc = regmap_update_bits(chip->regmap, chip->base + CMD_APSD,
					APSD_RERUN_BIT, APSD_RERUN_BIT);
		schedule_delayed_work(&chip->status_change_work,
				      msecs_to_jiffies(1000));
		dev_dbg(chip->dev, "get charger type failed, rerun apsd\n");
		return;
	}

	switch (charger_type) {
	case POWER_SUPPLY_USB_TYPE_CDP:
		current_ua = CDP_CURRENT_UA;
		break;
	case POWER_SUPPLY_USB_TYPE_DCP:
		current_ua = DCP_CURRENT_UA;
		break;
	case POWER_SUPPLY_USB_TYPE_SDP:
	default:
		current_ua = SDP_CURRENT_UA;
		break;
	}

	smb5_set_current_limit(chip, current_ua);
	power_supply_changed(chip->chg_psy);
}

static int smb5_get_iio_chan(struct smb5_chip *chip, struct iio_channel *chan,
			     int *val)
{
	int rc;
	union power_supply_propval status;

	rc = power_supply_get_property(chip->chg_psy, POWER_SUPPLY_PROP_STATUS,
				       &status);
	if (rc < 0 || status.intval != POWER_SUPPLY_STATUS_CHARGING) {
		*val = 0;
		return 0;
	}

	if (IS_ERR(chan)) {
		dev_err(chip->dev, "Failed to chan, err = %li", PTR_ERR(chan));
		return PTR_ERR(chan);
	}

	return iio_read_channel_processed(chan, val);
}

static int smb5_get_prop_health(struct smb5_chip *chip, int *val)
{
	int rc;
	unsigned int stat;

	rc = regmap_read(chip->regmap, chip->base + BATTERY_CHARGER_STATUS_2,
			 &stat);
	if (rc < 0) {
		dev_err(chip->dev, "Couldn't read charger status rc=%d\n", rc);
		return rc;
	}

	if (stat & CHARGER_ERROR_STATUS_BAT_OV_BIT) {
		dev_err(chip->dev, "battery over-voltage\n");
		*val = POWER_SUPPLY_HEALTH_OVERVOLTAGE;
		return 0;
	}
	if (stat & (CHARGER_ERROR_STATUS_SFT_EXPIRE_BIT |
		    CHARGER_ERROR_STATUS_BAT_TERM_MISSING_BIT)) {
		*val = POWER_SUPPLY_HEALTH_UNSPEC_FAILURE;
		return 0;
	}

	rc = regmap_read(chip->regmap, chip->base + BATTERY_CHARGER_STATUS_7_REG,
			 &stat);
	if (rc < 0) {
		dev_err(chip->dev, "Couldn't read charger status 7 rc=%d\n", rc);
		return rc;
	}

	if (stat & BAT_TEMP_STATUS_TOO_COLD_BIT)
		*val = POWER_SUPPLY_HEALTH_COLD;
	else if (stat & BAT_TEMP_STATUS_TOO_HOT_BIT)
		*val = POWER_SUPPLY_HEALTH_OVERHEAT;
	else if (stat & BAT_TEMP_STATUS_COLD_SOFT_BIT)
		*val = POWER_SUPPLY_HEALTH_COOL;
	else if (stat & BAT_TEMP_STATUS_HOT_SOFT_BIT)
		*val = POWER_SUPPLY_HEALTH_WARM;
	else
		*val = POWER_SUPPLY_HEALTH_GOOD;

	return 0;
}

/* TCPM owns PD messages/APDO selection; this driver owns the local load.
 * Never infer a PPS contract from USB_TYPE alone: ONLINE must become 2.
 * References: Linux v6.12 TCPM power_supply ABI; MiCode umi-q-oss
 * drivers/power/supply/qcom/{smb5-reg.h,smb5-lib.c}. No vendor auth bypass.
 */
static int smb5_source_get(struct smb5_chip *chip,
			   enum power_supply_property prop)
{
	union power_supply_propval val;
	int ret = power_supply_get_property(chip->tcpm_psy, prop, &val);

	return ret ? ret : val.intval;
}

static int smb5_source_set(struct smb5_chip *chip,
			   enum power_supply_property prop, int value)
{
	union power_supply_propval val = { .intval = value };

	return power_supply_set_property(chip->tcpm_psy, prop, &val);
}

static int smb5_pps_valid_target(int voltage_uv, int current_ua, int max_ua)
{
	if (voltage_uv < SMB5_PPS_MIN_UV || voltage_uv > SMB5_PPS_MAX_UV ||
	    voltage_uv % SMB5_PPS_STEP_UV || current_ua < SDP_CURRENT_UA ||
	    current_ua > max_ua || current_ua % SMB5_PPS_STEP_UA)
		return -EINVAL;
	return 0;
}

/* Caller holds pd_lock. Always shed the load before a protocol fallback.
 * Even when one operation fails, still try the other shutdown operations.
 */
static int smb5_pps_stop(struct smb5_chip *chip)
{
	int ret, first, online;

	first = smb5_set_prop_charging_enabled(chip, false);
	ret = smb5_set_current_limit(chip, SDP_CURRENT_UA);
	if (!first)
		first = ret;
	online = smb5_source_get(chip, POWER_SUPPLY_PROP_ONLINE);
	if (online < 0) {
		if (!first)
			first = online;
	} else if (online == 2 || chip->pps_active) {
		/* On detach there is no remaining PD contract to renegotiate. */
		ret = online ? smb5_source_set(chip, POWER_SUPPLY_PROP_ONLINE, 1) : 0;
		if (!first)
			first = ret;
		if (!ret) {
			online = smb5_source_get(chip, POWER_SUPPLY_PROP_ONLINE);
			if (online < 0 || online == 2)
				first = first ? first : (online < 0 ? online : -EIO);
		}
	}
	if (!first) {
		ret = regmap_update_bits(chip->regmap,
			chip->base + USBIN_ADAPTER_ALLOW_OVERRIDE,
			USBIN_ADAPTER_ALLOW_MASK, 0);
		if (!ret)
			chip->pps_active = false;
		first = ret;
	}
	return first;
}

/* Run in a sleepable worker, never in TCPM/power_supply notification context.
 * Reissuing CURRENT_NOW each second also renews the PPS contract (<10 s).
 * A communication/register/health failure latches off until an explicit retry.
 */
static int smb5_pps_update(struct smb5_chip *chip)
{
	int ret, online, health, current_ua, voltage_uv, min_uv, max_uv, max_ua;
	int expected_ua;

	online = smb5_source_get(chip, POWER_SUPPLY_PROP_ONLINE);
	if (online < 0)
		return online;
	if (!online) {
		chip->pps_enabled = false;
		return smb5_pps_stop(chip);
	}
	ret = smb5_get_prop_health(chip, &health);
	if (ret)
		return ret;
	if (health != POWER_SUPPLY_HEALTH_GOOD)
		return -ERANGE;
	if (chip->user_inhibit || chip->pps_fault)
		return smb5_pps_stop(chip);

	if (!chip->pps_enabled) {
		if (online == 2 || chip->pps_active) {
			ret = smb5_pps_stop(chip);
			if (ret)
				return ret;
		}
		/* No fixed high-voltage PDO is advertised by our connector. */
		voltage_uv = smb5_source_get(chip, POWER_SUPPLY_PROP_VOLTAGE_NOW);
		if (voltage_uv <= 0 || voltage_uv > SMB5_PPS_MIN_UV)
			return voltage_uv < 0 ? voltage_uv : -ERANGE;
		current_ua = smb5_source_get(chip, POWER_SUPPLY_PROP_CURRENT_NOW);
		if (current_ua < 0)
			return current_ua;
		current_ua = min(current_ua, chip->input_max_ua);
		current_ua = rounddown(current_ua, CURRENT_SCALE_FACTOR);
		ret = smb5_set_current_limit(chip, current_ua);
		if (ret)
			return ret;
		return smb5_set_prop_charging_enabled(chip, current_ua > 0);
	}

	ret = smb5_pps_valid_target(chip->pps_voltage_uv, chip->pps_current_ua,
				    chip->input_max_ua);
	if (ret)
		return ret;
	ret = smb5_source_get(chip, POWER_SUPPLY_PROP_USB_TYPE);
	if (ret != POWER_SUPPLY_USB_TYPE_PD_PPS)
		return ret < 0 ? ret : -EOPNOTSUPP;

	/* Shed load before changing an operating point or entering PPS. */
	voltage_uv = smb5_source_get(chip, POWER_SUPPLY_PROP_VOLTAGE_NOW);
	current_ua = smb5_source_get(chip, POWER_SUPPLY_PROP_CURRENT_NOW);
	if (voltage_uv < 0 || current_ua < 0)
		return voltage_uv < 0 ? voltage_uv : current_ua;
	/* TCPM initializes a PPS request from the fixed contract. Ensure that
	 * it already meets op-sink power, so TCPM need not raise voltage to
	 * meet that requirement while entering PPS.
	 */
	if (current_ua < SDP_CURRENT_UA ||
	    (online != 2 && voltage_uv != SMB5_PPS_MIN_UV))
		return -ERANGE;
	/* Compare against the effective request, not the uncapped user target.
	 * When APDO CURRENT_MAX is below pps_current_ua, TCPM CURRENT_NOW stays
	 * at the capped value; comparing the target would shed/renegotiate at 1 Hz.
	 */
	if (online == 2) {
		max_ua = smb5_source_get(chip, POWER_SUPPLY_PROP_CURRENT_MAX);
		if (max_ua < 0)
			return max_ua;
		expected_ua = rounddown(min(chip->pps_current_ua, max_ua),
					SMB5_PPS_STEP_UA);
	} else {
		expected_ua = chip->pps_current_ua;
	}
	if (online != 2 || voltage_uv != chip->pps_voltage_uv ||
	    current_ua != expected_ua) {
		ret = smb5_set_current_limit(chip, SDP_CURRENT_UA);
		if (ret)
			return ret;
	}
	ret = regmap_update_bits(chip->regmap,
		chip->base + USBIN_ADAPTER_ALLOW_OVERRIDE,
		USBIN_ADAPTER_ALLOW_MASK, USBIN_ADAPTER_ALLOW_CONTINUOUS);
	if (ret)
		return ret;
	if (online != 2) {
		ret = smb5_source_set(chip, POWER_SUPPLY_PROP_ONLINE, 2);
		if (ret)
			return ret;
		chip->pps_active = true;
	}
	min_uv = smb5_source_get(chip, POWER_SUPPLY_PROP_VOLTAGE_MIN);
	max_uv = smb5_source_get(chip, POWER_SUPPLY_PROP_VOLTAGE_MAX);
	max_ua = smb5_source_get(chip, POWER_SUPPLY_PROP_CURRENT_MAX);
	if (min_uv < 0 || max_uv < 0 || max_ua < 0)
		return min_uv < 0 ? min_uv : (max_uv < 0 ? max_uv : max_ua);
	if (chip->pps_voltage_uv < min_uv || chip->pps_voltage_uv > max_uv)
		return -ERANGE;
	current_ua = rounddown(min(chip->pps_current_ua, max_ua), SMB5_PPS_STEP_UA);
	if (current_ua < SDP_CURRENT_UA)
		return -ERANGE;
	ret = smb5_source_set(chip, POWER_SUPPLY_PROP_CURRENT_NOW, current_ua);
	if (ret)
		return ret;
	ret = smb5_source_set(chip, POWER_SUPPLY_PROP_VOLTAGE_NOW, chip->pps_voltage_uv);
	if (ret)
		return ret;
	/* Read the accepted contract back before increasing the local input load. */
	ret = smb5_source_get(chip, POWER_SUPPLY_PROP_ONLINE);
	if (ret != 2)
		return ret < 0 ? ret : -ENOTCONN;
	ret = smb5_source_get(chip, POWER_SUPPLY_PROP_VOLTAGE_NOW);
	if (ret != chip->pps_voltage_uv)
		return ret < 0 ? ret : -ERANGE;
	ret = smb5_source_get(chip, POWER_SUPPLY_PROP_CURRENT_NOW);
	if (ret <= 0 || ret > current_ua)
		return ret < 0 ? ret : -ERANGE;
	current_ua = rounddown(ret, CURRENT_SCALE_FACTOR);
	ret = smb5_get_prop_health(chip, &health);
	if (ret || health != POWER_SUPPLY_HEALTH_GOOD)
		return ret ? ret : -ERANGE;
	ret = smb5_set_current_limit(chip, current_ua);
	if (ret)
		return ret;
	ret = smb5_set_prop_charging_enabled(chip, true);
	if (!ret)
		chip->pps_active = true;
	return ret;
}

static void smb5_pd_work(struct smb5_chip *chip)
{
	int ret, stop_ret;

	mutex_lock(&chip->pd_lock);
	if (chip->pd_stopping) {
		mutex_unlock(&chip->pd_lock);
		return;
	}
	ret = smb5_pps_update(chip);
	if (ret) {
		chip->pps_enabled = false;
		chip->pps_fault = true;
		chip->pps_error = ret;
		stop_ret = smb5_pps_stop(chip);
		dev_err_ratelimited(chip->dev, "PD/PPS stopped: error=%d fallback=%d\n",
				    ret, stop_ret);
	}
	mutex_unlock(&chip->pd_lock);
	if (!READ_ONCE(chip->pd_stopping))
		schedule_delayed_work(&chip->status_change_work,
				      msecs_to_jiffies(SMB5_PPS_POLL_MS));
}

static ssize_t pps_enable_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct smb5_chip *chip = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", READ_ONCE(chip->pps_enabled));
}

static ssize_t pps_enable_store(struct device *dev, struct device_attribute *attr,
			       const char *buf, size_t count)
{
	struct smb5_chip *chip = dev_get_drvdata(dev);
	bool enable;
	int ret, health;

	ret = kstrtobool(buf, &enable);
	if (ret)
		return ret;
	mutex_lock(&chip->pd_lock);
	if (chip->pd_stopping) {
		ret = -ESHUTDOWN;
		goto out;
	}
	if (enable) {
		ret = smb5_source_get(chip, POWER_SUPPLY_PROP_ONLINE);
		if (ret <= 0) {
			ret = ret < 0 ? ret : -ENOTCONN;
			goto out;
		}
		ret = smb5_source_get(chip, POWER_SUPPLY_PROP_USB_TYPE);
		if (ret != POWER_SUPPLY_USB_TYPE_PD_PPS) {
			ret = ret < 0 ? ret : -EOPNOTSUPP;
			goto out;
		}
		ret = smb5_get_prop_health(chip, &health);
		if (ret || health != POWER_SUPPLY_HEALTH_GOOD) {
			ret = ret ? ret : -ERANGE;
			goto out;
		}
	} else {
		ret = smb5_pps_stop(chip);
		if (ret) {
			chip->pps_enabled = false;
			chip->pps_fault = true;
			chip->pps_error = ret;
			goto out;
		}
	}
	chip->pps_enabled = enable;
	chip->pps_fault = false;
	chip->pps_error = 0;
	if (enable)
		chip->user_inhibit = false;
	ret = 0;
out:
	mutex_unlock(&chip->pd_lock);
	if (!ret)
		mod_delayed_work(system_wq, &chip->status_change_work, 0);
	return ret ? ret : count;
}
static DEVICE_ATTR_RW(pps_enable);

static ssize_t pps_voltage_uv_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct smb5_chip *chip = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n", READ_ONCE(chip->pps_voltage_uv));
}

static ssize_t pps_current_ua_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct smb5_chip *chip = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n", READ_ONCE(chip->pps_current_ua));
}

static ssize_t smb5_pps_target_store(struct device *dev, const char *buf,
				    size_t count, bool voltage)
{
	struct smb5_chip *chip = dev_get_drvdata(dev);
	int value, ret;

	ret = kstrtoint(buf, 0, &value);
	if (ret)
		return ret;
	mutex_lock(&chip->pd_lock);
	ret = chip->pd_stopping ? -ESHUTDOWN :
		smb5_pps_valid_target(voltage ? value : chip->pps_voltage_uv,
		voltage ? chip->pps_current_ua : value, chip->input_max_ua);
	if (!ret) {
		if (voltage)
			chip->pps_voltage_uv = value;
		else
			chip->pps_current_ua = value;
	}
	mutex_unlock(&chip->pd_lock);
	if (!ret)
		mod_delayed_work(system_wq, &chip->status_change_work, 0);
	return ret ? ret : count;
}

static ssize_t pps_voltage_uv_store(struct device *dev, struct device_attribute *attr,
				   const char *buf, size_t count)
{
	return smb5_pps_target_store(dev, buf, count, true);
}
static DEVICE_ATTR_RW(pps_voltage_uv);

static ssize_t pps_current_ua_store(struct device *dev, struct device_attribute *attr,
				   const char *buf, size_t count)
{
	return smb5_pps_target_store(dev, buf, count, false);
}
static DEVICE_ATTR_RW(pps_current_ua);

static ssize_t pps_status_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct smb5_chip *chip = dev_get_drvdata(dev);
	ssize_t n;

	mutex_lock(&chip->pd_lock);
	n = sysfs_emit(buf, "enabled=%u active=%u fault=%u error=%d inhibited=%u\n",
		chip->pps_enabled, chip->pps_active, chip->pps_fault, chip->pps_error,
		chip->user_inhibit);
	n += sysfs_emit_at(buf, n, "online=%d contract_uv=%d contract_ua=%d max_ua=%d\n",
		smb5_source_get(chip, POWER_SUPPLY_PROP_ONLINE),
		smb5_source_get(chip, POWER_SUPPLY_PROP_VOLTAGE_NOW),
		smb5_source_get(chip, POWER_SUPPLY_PROP_CURRENT_NOW), chip->input_max_ua);
	mutex_unlock(&chip->pd_lock);
	return n;
}
static DEVICE_ATTR_RO(pps_status);

static struct attribute *smb5_pps_attrs[] = {
	&dev_attr_pps_enable.attr,
	&dev_attr_pps_voltage_uv.attr,
	&dev_attr_pps_current_ua.attr,
	&dev_attr_pps_status.attr,
	NULL,
};
static const struct attribute_group smb5_pps_group = {
	.attrs = smb5_pps_attrs,
};

static void smb5_pd_cleanup(void *data)
{
	struct smb5_chip *chip = data;

	WRITE_ONCE(chip->pd_stopping, true);
	cancel_delayed_work_sync(&chip->status_change_work);
	if (chip->wakeup_enabled) {
		dev_pm_clear_wake_irq(chip->dev);
		chip->wakeup_enabled = false;
	}
	if (chip->tcpm_psy) {
		mutex_lock(&chip->pd_lock);
		chip->pps_enabled = false;
		if (smb5_pps_stop(chip))
			dev_err(chip->dev, "Failed to stop PD/PPS during teardown\n");
		mutex_unlock(&chip->pd_lock);
	} else
		smb5_set_prop_charging_enabled(chip, false);
}

static void smb5_battery_info_put(void *data)
{
	struct smb5_chip *chip = data;

	power_supply_put_battery_info(chip->chg_psy, chip->batt_info);
}

static void smb5_wake_irq_clear(void *data)
{
	struct smb5_chip *chip = data;

	dev_pm_clear_wake_irq(chip->dev);
	chip->wakeup_enabled = false;
}

/* PM8150B encoding, from MiCode umi-q-oss qpnp-smb5.c smb5_pm8150b_params.
 * The inherited PMI8998 7.5 mV formula is not valid for this PMIC.
 */
static int smb5_battery_config(struct smb5_chip *chip)
{
	int fv = chip->batt_info->voltage_max_design_uv;
	int fcc = chip->batt_info->constant_charge_current_max_ua;
	int ret;

	if (fv < 3600000 || fv > 4790000 || fcc < SDP_CURRENT_UA || fcc > 8000000)
		return -EINVAL;
	chip->input_max_ua = rounddown(min(fcc, 1500000), CURRENT_SCALE_FACTOR);
	ret = regmap_update_bits(chip->regmap, chip->base + FLOAT_VOLTAGE_CFG,
				 FLOAT_VOLTAGE_SETTING_MASK, (fv - 3600000) / 10000);
	if (ret)
		return ret;
	return regmap_update_bits(chip->regmap, chip->base + FAST_CHARGE_CURRENT_CFG,
				 FAST_CHARGE_CURRENT_SETTING_MASK, fcc / CURRENT_SCALE_FACTOR);
}

static int smb5_get_property(struct power_supply *psy,
			     enum power_supply_property psp,
			     union power_supply_propval *val)
{
	struct smb5_chip *chip = power_supply_get_drvdata(psy);

	switch (psp) {
	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = "Qualcomm";
		return 0;
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = chip->name;
		return 0;
	case POWER_SUPPLY_PROP_CURRENT_MAX:
		return smb5_get_current_limit(chip, &val->intval);
	case POWER_SUPPLY_PROP_CURRENT_NOW:
		return smb5_get_iio_chan(chip, chip->usb_in_i_chan,
					 &val->intval);
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		return smb5_get_iio_chan(chip, chip->usb_in_v_chan,
					 &val->intval);
	case POWER_SUPPLY_PROP_ONLINE:
		return smb5_get_prop_usb_online(chip, &val->intval);
	case POWER_SUPPLY_PROP_STATUS:
		return smb5_get_prop_status(chip, &val->intval);
	case POWER_SUPPLY_PROP_HEALTH:
		return smb5_get_prop_health(chip, &val->intval);
	case POWER_SUPPLY_PROP_USB_TYPE:
		if (chip->tcpm_psy) {
			int type = smb5_source_get(chip, POWER_SUPPLY_PROP_USB_TYPE);

			if (type < 0)
				return type;
			val->intval = type;
			return 0;
		}
		return smb5_apsd_get_charger_type(chip, &val->intval);
	case POWER_SUPPLY_PROP_CHARGING_ENABLED:
		return smb5_get_prop_charging_enabled(chip, &val->intval);
	default:
		dev_err(chip->dev, "invalid property: %d\n", psp);
		return -EINVAL;
	}
}

static int smb5_set_property(struct power_supply *psy,
			     enum power_supply_property psp,
			     const union power_supply_propval *val)
{
	struct smb5_chip *chip = power_supply_get_drvdata(psy);

	switch (psp) {
	case POWER_SUPPLY_PROP_CURRENT_MAX:
		if (chip->tcpm_psy)
			return -EBUSY; /* The accepted PD/CC contract owns ICL. */
		if (val->intval < 0)
			return -EINVAL;
		return smb5_set_current_limit(chip, val->intval);
	case POWER_SUPPLY_PROP_CHARGING_ENABLED:
		if (chip->tcpm_psy) {
			int ret;

			if (val->intval != 0 && val->intval != 1)
				return -EINVAL;
			mutex_lock(&chip->pd_lock);
			chip->user_inhibit = !val->intval;
			if (chip->user_inhibit)
				chip->pps_enabled = false;
			ret = chip->user_inhibit ? smb5_pps_stop(chip) : 0;
			mutex_unlock(&chip->pd_lock);
			if (!READ_ONCE(chip->pd_stopping))
				mod_delayed_work(system_wq, &chip->status_change_work, 0);
			return ret;
		}
		return smb5_set_prop_charging_enabled(chip, val->intval);
	default:
		dev_err(chip->dev, "No setter for property: %d\n", psp);
		return -EINVAL;
	}
}

static int smb5_property_is_writable(struct power_supply *psy,
				     enum power_supply_property psp)
{
	struct smb5_chip *chip = power_supply_get_drvdata(psy);

	switch (psp) {
	case POWER_SUPPLY_PROP_CURRENT_MAX:
		return !chip->tcpm_psy;
	case POWER_SUPPLY_PROP_CHARGING_ENABLED:
		return 1;
	default:
		return 0;
	}
}

static irqreturn_t smb5_handle_batt_overvoltage(int irq, void *data)
{
	struct smb5_chip *chip = data;
	unsigned int status;

	if (regmap_read(chip->regmap, chip->base + BATTERY_CHARGER_STATUS_2,
			&status))
		return IRQ_HANDLED;

	if (status & CHARGER_ERROR_STATUS_BAT_OV_BIT) {
		/* The hardware stops charging automatically */
		dev_err(chip->dev, "battery overvoltage detected\n");
		power_supply_changed(chip->chg_psy);
	}

	return IRQ_HANDLED;
}

static irqreturn_t smb5_handle_usb_plugin(int irq, void *data)
{
	struct smb5_chip *chip = data;
	int ret, limit_ret;

	if (chip->tcpm_psy) {
		/* Bound a new attachment before waiting for TCPM's new contract. */
		mutex_lock(&chip->pd_lock);
		ret = smb5_set_prop_charging_enabled(chip, false);
		limit_ret = smb5_set_current_limit(chip, SDP_CURRENT_UA);
		chip->pps_enabled = false;
		if (ret || limit_ret) {
			chip->pps_fault = true;
			chip->pps_error = ret ? ret : limit_ret;
		}
		mutex_unlock(&chip->pd_lock);
	}
	power_supply_changed(chip->chg_psy);

	if (!READ_ONCE(chip->pd_stopping))
		mod_delayed_work(system_wq, &chip->status_change_work,
				 chip->tcpm_psy ? 0 : msecs_to_jiffies(1500));

	return IRQ_HANDLED;
}

static irqreturn_t smb5_handle_usb_icl_change(int irq, void *data)
{
	struct smb5_chip *chip = data;

	power_supply_changed(chip->chg_psy);

	return IRQ_HANDLED;
}

static irqreturn_t smb5_handle_wdog_bark(int irq, void *data)
{
	struct smb5_chip *chip = data;
	int rc;

	power_supply_changed(chip->chg_psy);

	rc = regmap_write(chip->regmap, chip->base + BARK_BITE_WDOG_PET,
			  BARK_BITE_WDOG_PET_BIT);
	if (rc < 0)
		dev_err(chip->dev, "Couldn't pet the dog rc=%d\n", rc);

	return IRQ_HANDLED;
}

static const struct power_supply_desc smb5_psy_desc = {
	.name = "pm8150b_charger",
	.type = POWER_SUPPLY_TYPE_USB,
	.usb_types = BIT(POWER_SUPPLY_USB_TYPE_SDP) |
		     BIT(POWER_SUPPLY_USB_TYPE_CDP) |
 		     BIT(POWER_SUPPLY_USB_TYPE_DCP) |
		     BIT(POWER_SUPPLY_USB_TYPE_C) |
		     BIT(POWER_SUPPLY_USB_TYPE_PD) |
		     BIT(POWER_SUPPLY_USB_TYPE_PD_PPS) |
		     BIT(POWER_SUPPLY_USB_TYPE_UNKNOWN),
	.properties = smb5_properties,
	.num_properties = ARRAY_SIZE(smb5_properties),
	.get_property = smb5_get_property,
	.set_property = smb5_set_property,
	.property_is_writeable = smb5_property_is_writable,
};

/* Init sequence derived from vendor downstream driver */
static const struct smb5_register smb5_init_seq[] = {
	{ .addr = USBIN_CMD_IL, .mask = USBIN_SUSPEND_BIT, .val = 0 },
	{ .addr = AICL_RERUN_TIME_CFG, .mask = AICL_RERUN_TIME_MASK, .val = 0 },
	/*
	 * By default configure us as an upstream facing port
	 * FIXME: This will be handled by the type-c driver
	 */
	{ .addr = TYPE_C_MODE_CFG,
	  .mask = EN_TRY_SNK_BIT | EN_SNK_ONLY_BIT,
	  .val = EN_TRY_SNK_BIT },
	{ .addr = TYPEC_TYPE_C_VCONN_CONTROL,
	  .mask = VCONN_EN_ORIENTATION_BIT | VCONN_EN_SRC_BIT |
		  VCONN_EN_VALUE_BIT,
	  .val = VCONN_EN_SRC_BIT },
	{ .addr = DEBUG_ACCESS_SRC_CFG,
	  .mask = EN_UNORIENTED_DEBUG_ACCESS_SRC_BIT,
	  .val = EN_UNORIENTED_DEBUG_ACCESS_SRC_BIT },
	{ .addr = TYPE_C_EXIT_STATE_CFG,
	  .mask = SEL_SRC_UPPER_REF_BIT,
	  .val = SEL_SRC_UPPER_REF_BIT },
	/*
	 * Disable Type-C factory mode and stay in Attached.SRC state when VCONN
	 * over-current happens
	 */
	{ .addr = TYPE_C_CFG,
	  .mask = BC1P2_START_ON_CC_BIT,
	  .val = 0 },
	{ .addr = TYPE_C_DEBUG_ACCESS_SINK,
	  .mask = TYPEC_DEBUG_ACCESS_SINK_MASK,
	  .val = 0x17 },
	/* Configure VBUS for software control */
	{ .addr = OTG_CFG, .mask = OTG_EN_SRC_CFG_BIT, .val = 0 },
	/*
	 * Use VBAT to determine the recharge threshold when battery is full
	 * rather than the state of charge.
	 */
	{ .addr = CHARGE_RCHG_SOC_THRESHOLD_CFG_REG,
	  .mask = CHARGE_RCHG_SOC_THRESHOLD_CFG_MASK,
	  .val = 98 },
	/* Enable charging */
	{ .addr = CHARGING_ENABLE_CMD,
	  .mask = CHARGING_ENABLE_CMD_BIT,
	  .val = CHARGING_ENABLE_CMD_BIT },
	/* Enable BC1P2 Src detect */
	{ .addr = USBIN_OPTIONS_1_CFG,
	  .mask = BC1P2_SRC_DETECT_BIT,
	  .val = BC1P2_SRC_DETECT_BIT },
	/* Set the default SDP charger type to a 500ma USB 2.0 port */
	{ .addr = USBIN_ICL_OPTIONS,
	  .mask = USBIN_MODE_CHG_BIT,
	  .val = USBIN_MODE_CHG_BIT },
	{ .addr = CMD_ICL_OVERRIDE,
	  .mask = ICL_OVERRIDE_BIT,
	  .val = 0 },
	{ .addr = USBIN_LOAD_CFG,
	  .mask = ICL_OVERRIDE_AFTER_APSD_BIT,
	  .val = 0 },
	/* Disable watchdog */
	{ .addr = SNARL_BARK_BITE_WD_CFG, .mask = 0xff, .val = 0 },
	{ .addr = WD_CFG,
	  .mask = WATCHDOG_TRIGGER_AFP_EN_BIT | WDOG_TIMER_EN_ON_PLUGIN_BIT |
		  BARK_WDOG_INT_EN_BIT,
	  .val = 0 },
	/*
	 * Enable Automatic Input Current Limit, this will slowly ramp up the current
	 * When connected to a wall charger, and automatically stop when it detects
	 * the charger current limit (voltage drop?) or it reaches the programmed limit.
	 */
	{ .addr = USBIN_AICL_OPTIONS_CFG,
	  .mask = USBIN_AICL_PERIODIC_RERUN_EN_BIT | USBIN_AICL_ADC_EN_BIT
			| USBIN_AICL_EN_BIT | SUSPEND_ON_COLLAPSE_USBIN_BIT,
	  .val = USBIN_AICL_PERIODIC_RERUN_EN_BIT | USBIN_AICL_ADC_EN_BIT
			| USBIN_AICL_EN_BIT | SUSPEND_ON_COLLAPSE_USBIN_BIT },
};

static int smb5_init_hw(struct smb5_chip *chip)
{
	int rc, i;
	for (i = 0; i < ARRAY_SIZE(smb5_init_seq); i++) {
		u8 value = smb5_init_seq[i].val;
		u8 mask = smb5_init_seq[i].mask;

		/* TCPM exclusively owns CC roles, VCONN and Type-C interrupts. */
		if (chip->tcpm_psy && smb5_init_seq[i].addr >= 0x500 &&
		    smb5_init_seq[i].addr < 0x600)
			continue;
		if (chip->tcpm_psy && (smb5_init_seq[i].addr == CHARGING_ENABLE_CMD ||
				      smb5_init_seq[i].addr == USBIN_OPTIONS_1_CFG))
			value = 0;
		if (chip->tcpm_psy && smb5_init_seq[i].addr == USBIN_OPTIONS_1_CFG)
			mask |= HVDCP_EN_BIT | HVDCP_AUTH_ALG_EN_CFG_BIT |
				HVDCP_AUTONOMOUS_MODE_EN_CFG_BIT | HVDCP_NO_AUTH_QC3_CFG_BIT;
		if (chip->tcpm_psy && smb5_init_seq[i].addr == CMD_ICL_OVERRIDE)
			value = ICL_OVERRIDE_BIT;
		if (chip->tcpm_psy && smb5_init_seq[i].addr == USBIN_LOAD_CFG)
			value = ICL_OVERRIDE_AFTER_APSD_BIT;
		dev_dbg(chip->dev, "%d: Writing 0x%02x to 0x%02x\n", i,
			smb5_init_seq[i].val, smb5_init_seq[i].addr);
		rc = regmap_update_bits(chip->regmap,
					chip->base + smb5_init_seq[i].addr,
					mask,
					value);
		if (rc < 0)
			return dev_err_probe(chip->dev, rc,
					     "%s: init command %d failed\n",
					     __func__, i);
	}
	return 0;
}

static int smb5_init_irq(struct smb5_chip *chip, int *irq, const char *name,
			 irqreturn_t (*handler)(int irq, void *data))
{
	int irqnum;
	int rc;

	irqnum = platform_get_irq_byname(to_platform_device(chip->dev), name);
	if (irqnum < 0)
		return irqnum;

	rc = devm_request_threaded_irq(chip->dev, irqnum, NULL, handler,
				       IRQF_ONESHOT, name, chip);
	if (rc < 0)
		return dev_err_probe(chip->dev, rc, "Couldn't request irq %s\n",
				     name);

	if (irq)
		*irq = irqnum;

	return 0;
}

static int smb5_probe(struct platform_device *pdev)
{
	struct power_supply_config supply_config = {};
	struct power_supply_desc *desc;
	struct smb5_chip *chip;
	int rc, irq;

	chip = devm_kzalloc(&pdev->dev, sizeof(*chip), GFP_KERNEL);
	if (!chip)
		return -ENOMEM;

	chip->dev = &pdev->dev;
	chip->name = pdev->name;
	mutex_init(&chip->pd_lock);
	chip->pps_voltage_uv = SMB5_PPS_MIN_UV;
	chip->pps_current_ua = SDP_CURRENT_UA;
	platform_set_drvdata(pdev, chip);
	if (device_property_present(chip->dev, "usb-c-power-supply")) {
		chip->tcpm_psy = devm_power_supply_get_by_phandle(chip->dev,
							       "usb-c-power-supply");
		if (IS_ERR(chip->tcpm_psy))
			return dev_err_probe(chip->dev, PTR_ERR(chip->tcpm_psy),
					     "TCPM supply not ready\n");
		if (!chip->tcpm_psy)
			return -ENODEV;
	}

	chip->regmap = dev_get_regmap(pdev->dev.parent, NULL);
	if (!chip->regmap)
		return dev_err_probe(chip->dev, -ENODEV,
				     "failed to locate the regmap\n");

	rc = device_property_read_u32(chip->dev, "reg", &chip->base);
	if (rc < 0)
		return dev_err_probe(chip->dev, rc,
				     "Couldn't read base address\n");

	chip->usb_in_v_chan = devm_iio_channel_get(chip->dev, "usb_in_v_div_16");
	if (IS_ERR(chip->usb_in_v_chan))
		return dev_err_probe(chip->dev, PTR_ERR(chip->usb_in_v_chan),
				     "Couldn't get usb_in_v_div_16 IIO channel\n");

	chip->usb_in_i_chan = devm_iio_channel_get(chip->dev, "usb_in_i_uv");
	if (IS_ERR(chip->usb_in_i_chan)) {
		return dev_err_probe(chip->dev, PTR_ERR(chip->usb_in_i_chan),
				     "Couldn't get usb_in_i_uv IIO channel\n");
	}

	supply_config.drv_data = chip;
	supply_config.fwnode = pdev->dev.fwnode;

	desc = devm_kzalloc(chip->dev, sizeof(smb5_psy_desc), GFP_KERNEL);
	if (!desc)
		return -ENOMEM;
	memcpy(desc, &smb5_psy_desc, sizeof(smb5_psy_desc));
	desc->name =
		devm_kasprintf(chip->dev, GFP_KERNEL, "%s-charger",
			       (const char *)device_get_match_data(chip->dev));
	if (!desc->name)
		return -ENOMEM;

	chip->chg_psy =
		devm_power_supply_register(chip->dev, desc, &supply_config);
	if (IS_ERR(chip->chg_psy))
		return dev_err_probe(chip->dev, PTR_ERR(chip->chg_psy),
				     "failed to register power supply\n");

	rc = power_supply_get_battery_info(chip->chg_psy, &chip->batt_info);
	if (rc)
		return dev_err_probe(chip->dev, rc,
				     "Failed to get battery info\n");
	rc = devm_add_action_or_reset(chip->dev, smb5_battery_info_put, chip);
	if (rc)
		return rc;

	rc = devm_delayed_work_autocancel(chip->dev, &chip->status_change_work,
					  smb5_status_change_work);
	if (rc)
		return dev_err_probe(chip->dev, rc,
				     "Failed to init status change work\n");

	rc = devm_add_action_or_reset(chip->dev, smb5_pd_cleanup, chip);
	if (rc)
		return rc;
	/* Configure battery limits with charging stopped, before allowing input. */
	rc = smb5_set_prop_charging_enabled(chip, false);
	if (rc)
		return rc;
	rc = smb5_battery_config(chip);
	if (rc)
		return dev_err_probe(chip->dev, rc, "Invalid/failed battery limits\n");
	rc = smb5_set_current_limit(chip, SDP_CURRENT_UA);
	if (rc)
		return rc;
	rc = smb5_init_hw(chip);
	if (rc)
		return rc;

	rc = smb5_init_irq(chip, &irq, "bat-ov", smb5_handle_batt_overvoltage);
	if (rc < 0)
		return rc;

	rc = smb5_init_irq(chip, &chip->cable_irq, "usbin-plugin",
			   smb5_handle_usb_plugin);
	if (rc < 0)
		return rc;

	rc = smb5_init_irq(chip, &irq, "usbin-icl-change",
			   smb5_handle_usb_icl_change);
	if (rc < 0)
		return rc;
	rc = smb5_init_irq(chip, &irq, "wdog-bark", smb5_handle_wdog_bark);
	if (rc < 0)
		return rc;

	rc = dev_pm_set_wake_irq(chip->dev, chip->cable_irq);
	if (rc < 0)
		return dev_err_probe(chip->dev, rc, "Couldn't set wake irq\n");
	chip->wakeup_enabled = true;
	rc = devm_add_action_or_reset(chip->dev, smb5_wake_irq_clear, chip);
	if (rc)
		return rc;

	if (chip->tcpm_psy) {
		rc = devm_device_add_group(chip->dev, &smb5_pps_group);
		if (rc)
			return rc;
	}

	/* Initialise charger state */
	schedule_delayed_work(&chip->status_change_work, 0);

	return 0;
}

static int smb5_suspend(struct device *dev)
{
	struct smb5_chip *chip = dev_get_drvdata(dev);
	int ret;

	if (!chip->tcpm_psy)
		return 0;
	WRITE_ONCE(chip->pd_stopping, true);
	cancel_delayed_work_sync(&chip->status_change_work);
	mutex_lock(&chip->pd_lock);
	chip->pps_enabled = false;
	ret = smb5_pps_stop(chip);
	if (ret) {
		chip->pps_fault = true;
		chip->pps_error = ret;
	}
	mutex_unlock(&chip->pd_lock);
	if (ret) {
		WRITE_ONCE(chip->pd_stopping, false);
		schedule_delayed_work(&chip->status_change_work, 0);
	}
	return ret;
}

static int smb5_resume(struct device *dev)
{
	struct smb5_chip *chip = dev_get_drvdata(dev);

	if (chip->tcpm_psy) {
		WRITE_ONCE(chip->pd_stopping, false);
		schedule_delayed_work(&chip->status_change_work, 0);
	}
	return 0;
}
static DEFINE_SIMPLE_DEV_PM_OPS(smb5_pm_ops, smb5_suspend, smb5_resume);

static void smb5_shutdown(struct platform_device *pdev)
{
	smb5_pd_cleanup(platform_get_drvdata(pdev));
}

static const struct of_device_id smb5_match_id_table[] = {
	{ .compatible = "qcom,pm8150b-charger", .data = "pm8150b" },
	{ /* sentinal */ }
};
MODULE_DEVICE_TABLE(of, smb5_match_id_table);

static struct platform_driver qcom_spmi_smb5 = {
	.probe = smb5_probe,
	.shutdown = smb5_shutdown,
	.driver = {
		.name = "qcom-pm8150b-charger",
		.of_match_table = smb5_match_id_table,
		.pm = pm_sleep_ptr(&smb5_pm_ops),
		},
};

module_platform_driver(qcom_spmi_smb5);

MODULE_AUTHOR("Caleb Connolly <caleb.connolly@linaro.org>");
MODULE_DESCRIPTION("Qualcomm SMB5 Charger Driver");
MODULE_LICENSE("GPL");
