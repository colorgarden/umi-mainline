#!/usr/bin/env python3
"""Execute the SMB5 policy with a simulated TCPM source and injected I/O failures.

No phone, PD messages, PMIC registers or kernel modules are used by these tests.
"""
from pathlib import Path
import ast
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'power/qcom_pm8150b_charger.c').read_text(encoding='utf-8')
SOURCE = re.sub(r'^static void smb5_pd_work\([^\n]+;\n', '', SOURCE, flags=re.M)


def function(source, name):
    start = re.search(r'^static [^\n]*\b' + re.escape(name) + r'\(', source, re.M).start()
    return source[start:source.index('\n}', start) + 2]


class PpsTests(unittest.TestCase):
    def run_c(self, source):
        compiler = shutil.which('cc') or shutil.which('clang')
        self.assertIsNotNone(compiler, 'C compiler required for the actual driver function tests')
        with tempfile.TemporaryDirectory(prefix='umi-pps-c-') as tmp:
            path = Path(tmp)
            (path / 'test.c').write_text(source)
            compiled = subprocess.run([compiler, '-std=c11', '-Wall', '-Werror',
                                       '-Wno-unused-function', str(path / 'test.c'), '-o', str(path / 'test')],
                                      capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(path / 'test')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

    def test_rescue_audit_rejects_modular_vbus_provider(self):
        audit = ROOT / 'tools/config-audit.py'
        tree = ast.parse(audit.read_text(encoding='utf-8'))
        lists = {node.targets[0].id: ast.literal_eval(node.value) for node in tree.body
                 if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
                 and node.targets[0].id in {'MUST', 'MUST_NOT'}}
        values = {name: value for name, value, _ in lists['MUST']}
        values.update({name: 'n' for name, _ in lists['MUST_NOT']})
        self.assertEqual(values['REGULATOR_QCOM_USB_VBUS'], 'y')
        with tempfile.TemporaryDirectory(prefix='umi-pps-config-') as tmp:
            path = Path(tmp) / 'config'
            fragment = Path(tmp) / 'fragment'
            fragment.write_text('CONFIG_REGULATOR_QCOM_USB_VBUS=y\n')
            for provider, expected in [('y', 0), ('m', 1), ('n', 1)]:
                with self.subTest(provider=provider):
                    values['REGULATOR_QCOM_USB_VBUS'] = provider
                    path.write_text(''.join(f'CONFIG_{k}={v}\n' for k, v in values.items()))
                    result = subprocess.run([sys.executable, str(audit), str(path),
                                             '--fragment', str(fragment)],
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def harness(self):
        constants = ['SMB5_PPS_MIN_UV', 'SMB5_PPS_MAX_UV', 'SMB5_PPS_STEP_UV',
                     'SMB5_PPS_STEP_UA', 'SMB5_PPS_POLL_MS', 'SDP_CURRENT_UA',
                     'CURRENT_SCALE_FACTOR', 'USBIN_ADAPTER_ALLOW_OVERRIDE',
                     'USBIN_ADAPTER_ALLOW_MASK', 'USBIN_ADAPTER_ALLOW_CONTINUOUS',
                     'FLOAT_VOLTAGE_CFG', 'FLOAT_VOLTAGE_SETTING_MASK',
                     'FAST_CHARGE_CURRENT_CFG', 'FAST_CHARGE_CURRENT_SETTING_MASK']
        defines = '\n'.join(re.search(r'^#define\s+' + name + r'\s+[^\n]+',
                                      SOURCE, re.M).group(0) for name in constants)
        return r'''
#include <stdbool.h>
#include <stdio.h>
#include <errno.h>
#define min(a,b) ((a)<(b)?(a):(b))
#define round_down(a,b) ((a)&~((b)-1))
#define rounddown(a,b) ((a)/(b)*(b))
#define BIT(n) (1U<<(n))
#define GENMASK(h,l) (((~0U)<<(l))&(~0U>>(31-(h))))
#define READ_ONCE(x) (x)
#define mutex_lock(p) ((void)0)
#define mutex_unlock(p) ((void)0)
#define dev_err_ratelimited(d,fmt,...) ((void)(d),(void)printf(fmt,__VA_ARGS__))
#define msecs_to_jiffies(x) (x)
''' + defines + r'''
enum power_supply_property {POWER_SUPPLY_PROP_ONLINE,POWER_SUPPLY_PROP_USB_TYPE,
 POWER_SUPPLY_PROP_VOLTAGE_NOW,POWER_SUPPLY_PROP_CURRENT_NOW,POWER_SUPPLY_PROP_VOLTAGE_MIN,
 POWER_SUPPLY_PROP_VOLTAGE_MAX,POWER_SUPPLY_PROP_CURRENT_MAX};
enum {POWER_SUPPLY_HEALTH_GOOD=1,POWER_SUPPLY_USB_TYPE_PD_PPS=8};
struct battery_info {int voltage_max_design_uv,constant_charge_current_max_ua;};
struct smb5_chip {bool pps_enabled,pps_active,pps_fault,user_inhibit,pd_stopping;
 int pps_error,pps_voltage_uv,pps_current_ua,input_max_ua,pd_lock,base,status_change_work;
 void *dev,*regmap;struct battery_info *batt_info;};
static int calls,fail_at,online,voltage,current,source_max,health,usb_type;
static int input_limit,charging,enabled_calls,refuse,disable_calls,reg_calls,fv_reg,fcc_reg;
static int step(void) {return ++calls==fail_at ? -EIO : 0;}
static int smb5_source_get(struct smb5_chip *c,enum power_supply_property p) {
 int ret=step(); if(ret)return ret;
 switch(p) {case POWER_SUPPLY_PROP_ONLINE:return online;
 case POWER_SUPPLY_PROP_USB_TYPE:return usb_type;
 case POWER_SUPPLY_PROP_VOLTAGE_NOW:return voltage;
 case POWER_SUPPLY_PROP_CURRENT_NOW:return current;
 case POWER_SUPPLY_PROP_VOLTAGE_MIN:return 3300000;
 case POWER_SUPPLY_PROP_VOLTAGE_MAX:return 11000000;
 case POWER_SUPPLY_PROP_CURRENT_MAX:return source_max;}
 return -EINVAL;}
static int smb5_source_set(struct smb5_chip *c,enum power_supply_property p,int v) {
 int ret=step();if(ret)return ret;
 if(p==POWER_SUPPLY_PROP_ONLINE) {if(!refuse)online=v;if(v==1){voltage=5000000;current=1500000;}}
 if(p==POWER_SUPPLY_PROP_CURRENT_NOW)current=v;
 if(p==POWER_SUPPLY_PROP_VOLTAGE_NOW)voltage=v;
 return 0;}
static int smb5_set_prop_charging_enabled(struct smb5_chip *c,unsigned v) {
 if(!v) {disable_calls++;}
 int ret=step();if(ret)return ret;
 charging=v;if(v)enabled_calls++;return 0;}
static int smb5_set_current_limit(struct smb5_chip *c,unsigned v) {
 int ret=step();if(ret)return ret;input_limit=v;return 0;}
static int smb5_get_prop_health(struct smb5_chip *c,int *v) {
 int ret=step();if(ret)return ret;*v=health;return 0;}
static int regmap_update_bits(void *m,int reg,int mask,int val) {
 reg_calls++;int ret=step();if(ret)return ret;
 if(reg==FLOAT_VOLTAGE_CFG)fv_reg=val;
 if(reg==FAST_CHARGE_CURRENT_CFG)fcc_reg=val;
 return 0;}
static void schedule_delayed_work(int *w,int delay) {}
static struct smb5_chip reset(void) {
 calls=0;fail_at=0;online=1;voltage=5000000;current=1500000;
 source_max=3000000;health=POWER_SUPPLY_HEALTH_GOOD;usb_type=POWER_SUPPLY_USB_TYPE_PD_PPS;
 input_limit=500000;charging=0;enabled_calls=0;refuse=0;disable_calls=0;reg_calls=0;
 return (struct smb5_chip){.pps_enabled=true,.pps_voltage_uv=9000000,
 .pps_current_ua=1500000,.input_max_ua=1500000};}
''' + '\n'.join(function(SOURCE, name) for name in [
            'smb5_pps_valid_target', 'smb5_pps_stop', 'smb5_pps_update',
            'smb5_pd_work', 'smb5_battery_config'])

    def test_success_and_every_policy_io_failure_latches_off(self):
        self.run_c(self.harness() + r'''
int main(void) {
 struct smb5_chip c=reset();smb5_pd_work(&c);int total=calls;
 if(!c.pps_active||c.pps_fault||!charging||online!=2||voltage!=9000000||
    input_limit!=1500000)return 1;
 /* Every operation before the final enable is an independently fallible I/O. */
 for(int i=1;i<=total;i++) {
  c=reset();fail_at=i;smb5_pd_work(&c);
  if(!c.pps_fault||c.pps_enabled||c.pps_error!=-EIO||charging||enabled_calls||
     !disable_calls||input_limit>500000||online==2) {
   printf("unsafe failure at %d/%d online=%d enabled=%d limit=%d\n",i,total,online,charging,input_limit);
   return 2;}
 }
 printf("PPS operation failure points: %d\n",total);return 0;
}
''')

    def test_contract_readback_refusal_health_limits_and_disconnect(self):
        self.run_c(self.harness() + r'''
int main(void) {
 struct smb5_chip c=reset();refuse=1;smb5_pd_work(&c);
 if(charging||!c.pps_fault||enabled_calls)return 1;
 c=reset();health=2;smb5_pd_work(&c);
 if(charging||!c.pps_fault||enabled_calls)return 2;
 c=reset();source_max=1000000;smb5_pd_work(&c);
 if(!charging||input_limit!=1000000||current!=1000000)return 3;
 c=reset();online=0;smb5_pd_work(&c);
 if(charging||c.pps_enabled||c.pps_active||c.pps_fault)return 4;
 c=reset();usb_type=1;smb5_pd_work(&c);
 if(charging||!c.pps_fault||enabled_calls)return 5;
 c=reset();c.user_inhibit=true;smb5_pd_work(&c);
 if(charging||enabled_calls)return 6;
 c=reset();c.pps_fault=true;smb5_pd_work(&c);
 if(charging||enabled_calls)return 7;
 c=reset();c.pps_enabled=false;current=100000;smb5_pd_work(&c);
 if(!charging||input_limit>current||c.pps_active)return 8;
 c=reset();c.pps_enabled=false;voltage=12000000;smb5_pd_work(&c);
 if(charging||!c.pps_fault)return 9;
 c=reset();current=100000;smb5_pd_work(&c);
 if(charging||!c.pps_fault||enabled_calls)return 10;
 c=reset();voltage=12000000;smb5_pd_work(&c);
 if(charging||!c.pps_fault||enabled_calls)return 11;
 return 0;
}
''')

    def test_heartbeat_sends_new_request_and_stop_attempts_all_operations(self):
        self.run_c(self.harness() + r'''
int main(void) {
 struct smb5_chip c=reset();smb5_pd_work(&c);int first=calls;
 smb5_pd_work(&c);
 if(calls<=first||!charging||c.pps_fault||online!=2)return 1;
 /* APDO CURRENT_MAX below the user target must keep the capped contract. */
 c=reset();source_max=1000000;smb5_pd_work(&c);first=calls;
 smb5_pd_work(&c);
 if(calls<=first||c.pps_fault||!charging||online!=2||
    current!=1000000||input_limit!=1000000)return 2;
 for(int i=1;i<=6;i++) {
  c=reset();online=2;c.pps_active=true;charging=1;fail_at=i;
  int ret=smb5_pps_stop(&c);
  if(!ret||!disable_calls||calls<i)return 3;
  /* A failed load-disable must not skip the protocol fallback attempt. */
  if(i==1 && online!=1)return 4;
 }
 return 0;
}
''')

    def test_target_boundaries_and_pm8150b_register_encoding(self):
        self.run_c(self.harness() + r'''
int main(void) {
 struct smb5_chip c=reset();
 if(smb5_pps_valid_target(5000000,500000,1500000)||
    smb5_pps_valid_target(9000000,1500000,1500000))return 1;
 int bad[][2]={{-1,500000},{4999999,500000},{9000001,500000},{5020001,500000},
 {5000000,-1},{5000000,499999},{5000000,1500001},{5000000,550001}};
 for(unsigned i=0;i<sizeof(bad)/sizeof(*bad);i++)
  if(smb5_pps_valid_target(bad[i][0],bad[i][1],1500000)!=-EINVAL)return 2;
 struct battery_info b={4400000,1500000};c.batt_info=&b;
 if(smb5_battery_config(&c)||fv_reg!=80||fcc_reg!=30||c.input_max_ua!=1500000)return 3;
 for(int i=1;i<=2;i++) {c=reset();c.batt_info=&b;fail_at=i;
  if(smb5_battery_config(&c)!=-EIO||calls!=i)return 4;}
 b.voltage_max_design_uv=4790001;c=reset();c.batt_info=&b;
 if(smb5_battery_config(&c)!=-EINVAL||reg_calls)return 5;
 b.voltage_max_design_uv=4400000;b.constant_charge_current_max_ua=-1;
 if(smb5_battery_config(&c)!=-EINVAL||reg_calls)return 6;
 return 0;
}
''')

    def test_hardware_health_is_not_good_on_fault_or_read_failure(self):
        names = ['BATTERY_CHARGER_STATUS_2', 'BATTERY_CHARGER_STATUS_7_REG',
                 'CHARGER_ERROR_STATUS_BAT_OV_BIT', 'CHARGER_ERROR_STATUS_SFT_EXPIRE_BIT',
                 'CHARGER_ERROR_STATUS_BAT_TERM_MISSING_BIT', 'BAT_TEMP_STATUS_TOO_COLD_BIT',
                 'BAT_TEMP_STATUS_TOO_HOT_BIT', 'BAT_TEMP_STATUS_COLD_SOFT_BIT',
                 'BAT_TEMP_STATUS_HOT_SOFT_BIT']
        defines = '\n'.join(re.search(r'^#define\s+' + name + r'\s+[^\n]+',
                                      SOURCE, re.M).group(0) for name in names)
        self.run_c(r'''
#include <errno.h>
#define BIT(n) (1U<<(n))
#define dev_err(...) ((void)0)
enum {POWER_SUPPLY_HEALTH_GOOD=1,POWER_SUPPLY_HEALTH_OVERVOLTAGE,
 POWER_SUPPLY_HEALTH_UNSPEC_FAILURE,POWER_SUPPLY_HEALTH_COLD,POWER_SUPPLY_HEALTH_OVERHEAT,
 POWER_SUPPLY_HEALTH_COOL,POWER_SUPPLY_HEALTH_WARM};
struct smb5_chip {void *dev,*regmap;int base;};
static unsigned fault,temp;static int calls,fail;
static int regmap_read(void *m,int r,unsigned *v) {
 if(++calls==fail) {return -EIO;}
 *v=calls==1?fault:temp;return 0;}
''' + defines + '\n' + function(SOURCE, 'smb5_get_prop_health') + r'''
int main(void) {struct smb5_chip c={0};int val=77;
 for(fail=1;fail<=2;fail++) {calls=0;
  if(smb5_get_prop_health(&c,&val)!=-EIO||val!=77)return 1;}
 fail=0;
 unsigned faults[]={CHARGER_ERROR_STATUS_BAT_OV_BIT,CHARGER_ERROR_STATUS_SFT_EXPIRE_BIT,
  CHARGER_ERROR_STATUS_BAT_TERM_MISSING_BIT};
 for(unsigned i=0;i<3;i++) {calls=0;fault=faults[i];
  if(smb5_get_prop_health(&c,&val)||val==POWER_SUPPLY_HEALTH_GOOD)return 2;}
 fault=0;
 unsigned temps[]={BAT_TEMP_STATUS_TOO_COLD_BIT,BAT_TEMP_STATUS_TOO_HOT_BIT,
  BAT_TEMP_STATUS_COLD_SOFT_BIT,BAT_TEMP_STATUS_HOT_SOFT_BIT};
 for(unsigned i=0;i<4;i++) {calls=0;temp=temps[i];
  if(smb5_get_prop_health(&c,&val)||val==POWER_SUPPLY_HEALTH_GOOD)return 3;}
 temp=0;calls=0;
 if(smb5_get_prop_health(&c,&val)||val!=POWER_SUPPLY_HEALTH_GOOD)return 4;
 return 0;}
''')

    def test_pd_init_never_enables_load_or_overwrites_tcpm_roles(self):
        defines = '\n'.join(re.findall(r'^#define[^\n]+', SOURCE, re.M))
        start = SOURCE.index('static const struct smb5_register smb5_init_seq[]')
        array = SOURCE[start:SOURCE.index('\n};', start) + 3]
        self.run_c(r'''
#include <stdio.h>
#include <stdbool.h>
#include <errno.h>
#define BIT(n) (1U<<(n))
#define GENMASK(h,l) ((1U<<((h)+1))-(1U<<(l)))
#define ARRAY_SIZE(x) (sizeof(x)/sizeof(*(x)))
#define dev_dbg(...) ((void)0)
#define dev_err_probe(d,r,...) (r)
typedef unsigned char u8;typedef unsigned short u16;
struct smb5_register {u16 addr;u8 mask,val;};
struct smb5_chip {void *tcpm_psy,*dev,*regmap;int base;};
''' + defines + r'''
static int calls,fail,role_write,enable_write,icl,load,apsd;
static int regmap_update_bits(void *m,int reg,int mask,int value) {
 if(++calls==fail)return -EIO;
 if(reg>=0x500 && reg<0x600)role_write++;
 if(reg==CHARGING_ENABLE_CMD && value)enable_write++;
 if(reg==CMD_ICL_OVERRIDE)icl=value;
 if(reg==USBIN_LOAD_CFG)load=value;
 if(reg==USBIN_OPTIONS_1_CFG)apsd=value;
 return 0;}
''' + array + '\n' + function(SOURCE, 'smb5_init_hw') + r'''
int main(void) {struct smb5_chip c={.tcpm_psy=(void *)1};
 if(smb5_init_hw(&c)||role_write||enable_write||icl!=ICL_OVERRIDE_BIT||
    load!=ICL_OVERRIDE_AFTER_APSD_BIT||apsd)return 1;
 int total=calls;
 for(int i=1;i<=total;i++) {calls=0;fail=i;
  if(smb5_init_hw(&c)!=-EIO||calls!=i||role_write||enable_write)return 2;}
 return 0;}
''')


if __name__ == '__main__':
    unittest.main()
