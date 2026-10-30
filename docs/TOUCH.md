# Touchscreen

**Part:** STMicroelectronics FTS, I2C address `0x49`
**Bus:** `i2c@a94000` (QUPV3 wrap1 SE5) → mainline label `&i2c13`
**Driver:** `patches/fts-umi.c`

## How the part was identified

The vendor device tree has **two** touch nodes on the same I2C controller,
both `status = "ok"`:

```
i2c@a94000 {
        qcom,i2c-touch-active = "st,fts";
        fts@49   { compatible = "st,fts";     ... };   /* ST  */
        goodix@5d{ compatible = "goodix,gt9889"; ... };/* Goodix */
};
```

Only one of them is populated on any given unit, so the DT cannot answer the
question. The live device can:

```
$ adb shell getevent -pl | grep -A2 'name:'
  add device 6: /dev/input/event5
    name:     "fts"
...
$ adb shell su -c 'cat /sys/bus/i2c/devices/*/name'
/sys/bus/i2c/devices/3-0049: fts
/sys/bus/i2c/devices/3-005d: gt9889      <- instantiated, never bound
```

and the vendor driver says so in `dmesg`:

```
[    1.538773] [ FTS ] fts_get_config: Choose config 1: st_fts_j2_2.ftb
[    1.538830] [ FTS ] flash_burn: Firmware in the chip newer or equal to the
                      one to burn! NO UPDATE ERROR 8000000C
```

Two conclusions:

1. This unit is **ST FTS**, not Goodix.
2. **Firmware and configuration already live in the controller's own flash.**
   Nothing has to be uploaded, and the driver must never write to the flash.

## Wiring (from the vendor device tree)

| Signal | Value | Vendor property |
|---|---|---|
| SDA / SCL | GPIO37 / GPIO36, function `qup13` | `qupv3_se13_i2c_active` |
| reset | GPIO38, active high (high = out of reset) | `fts,reset-gpio = <&tlmm 0x26 0x00>` |
| interrupt | GPIO39, level low | `fts,irq-gpio = <&tlmm 0x27 0x2008>` |
| AVDD 3.3 V | enable GPIO69 (`touch_vddio_vreg`) | `avdd-supply` |
| VDD 1.8 V | pm8150a LDO1 | `vdd-supply` |

Neither rail is touched by the kernel. Both are enabled by ABL before the
kernel starts, the vendor driver only ever *enables* them, and this driver
reproduces that state exactly. If a rail were off, the first I2C transfer
would fail with `-ENXIO`/`-ETIMEDOUT` and the log would say so.

## Protocol

Every transfer is a plain I2C write of a command byte, optionally followed by
a read of the answer:

```
S addr+W  <cmd>            S addr+R  <data...>
```

| Command | Meaning |
|---|---|
| `0x80` | read information, 8 bytes: chip version, firmware version, config id/version, chip id |
| `0x85` | read one event from the FIFO (8 bytes) |
| `0xA1` | flush the FIFO |
| `0x92` / `0x93` | sense off / on |

Events are drained one at a time; byte 0 == `0x00` means "FIFO empty".

### Event layout (8 bytes)

```
byte 0   <class><object>
           object = bits 3..0 : 3 = touch point, other values = gestures
           class  = bits 7..4 : 1 = enter/motion, 3 = leave
byte 1   bits 3..0 touch id, bits 7..4 number of remaining contacts
byte 2   x >> 4
byte 3   y >> 4
byte 4   bits 7..4 = x & 0xf, bits 3..0 = y & 0xf
byte 5   bits 7..6 touch size, bits 4..0 major
byte 6   minor
byte 7   unused
```

Coordinates are therefore 12-bit:

```
x = (ev[2] << 4) | ((ev[4] & 0xf0) >> 4)
y = (ev[3] << 4) | (ev[4] & 0x0f)
```

Older ST parts use flat event codes `0x03` (enter) / `0x04` (leave) /
`0x05` (motion) instead of the class/object byte. The driver accepts both
spellings, because the vendor log on this unit shows `Event 0x13 - Press`
/ `Event 0x33 - release`, which is the class/object form, while the vendor
header still defines the flat codes.

### Why the first 96 events are dumped verbatim

```
[   35.611777] fts-umi 3-0049: ev 13 00 21 4c 7a 11 03 00
```

If a different controller revision ever turns up, having the raw bytes in the
log is worth more than any amount of guessing about the protocol.

## Reset sequence

```
reset = 0
20 ms
reset = 1
120 ms
flush FIFO (0xA1), sense on (0x93)
```

The vendor power cycle path waits 300 ms after releasing reset; 120 ms is
comfortably within what the datasheet allows and keeps the probe fast.

## Known limitations

* No gestures, no swipe-to-wake, no in-display-fingerprint area reporting —
  plain multi-touch only.
* The interrupt is a threaded handler that drains the whole FIFO per
  interrupt; no ESD recovery yet.
* Only the `st,fts` variant is driven. A Goodix GT9889 unit needs a different
  driver (mainline `goodix_berlin*` is a reasonable starting point, but the
  firmware/config handling will have to be adapted).

## Where the bring-up actually stands

Everything below was measured on umi with a serial console, not inferred.
Three protocol mistakes had been keeping the whole thing down, and once they
were fixed the AFE finally came up.

### 1. Three protocol facts

| what | wrong before | right |
|---|---|---|
| load-data selector | `0xA4 01 <type>` | **`0xA4 06 <type>`** |
| framebuffer address width | 32 bit after `0xA6` | **16 bit after `0xA6`** |
| register address width | 16 bit | **32 bit after `0xFA`** |

The vendor map for the `0xA4` selector byte is `0x00` special, `0x01` FW
interrupt control, `0x02` force cal, `0x03` CX tuning, **`0x06` load data**.
Every early raw-frame request went to the interrupt-control command instead,
which is also what first blacked the panel.

The framebuffer is a *different address space* from the `0xFA` registers.
Handing `0xA6` a 32 bit address still returns something that parses like a
header, so the mistake is silent — the tell is a frame counter that never
moves.

### 2. FULL panel init, not panel init

`A4 00 03`, not `A4 00 02`. The whole vendor function is:

```
reset the chip (GPIO 38 low 10 ms, high)
A4 00 03
A4 06 01          then read the system info back
```

The vendor picks which one from the AFE versions in the system info:

```
cfgAfeVer != cxAfeVer        -> SPECIAL_FULL_PANEL_INIT   0x03
cfgAfeVer != panelCfgAfeVer  -> SPECIAL_PANEL_INIT        0x02
```

This unit reads `cfgAfeVer 0x00 / cxAfeVer 0x05`, so it needs the **full**
one. `A4 00 02` alone changes nothing, which is why it looked like a dead end.

Measured effect (`echo 4 > enable`):

```
before:  sysinfo res 0x0        tx 0  rx 0   raw@0000
after:   sysinfo res 2339x1079  tx 17 rx 37 raw@9148
```

`2339x1079` is the panel minus one; `17x37` are the real TX/RX channel
counts. The three AFE versions also settle from `00/05/05` to `05/05/05`.

### 3. IER is read-only, and writing it causes the interrupt storm

`0x20000029` reads `0x40` on a freshly reset chip and the FW overwrites
whatever is written to it. Writing `0x41` after every interrupt produced
**1370 interrupts per second with an empty FIFO behind them** and made the
console crawl. The vendor's `fts_enableInterrupt()` only enables the Linux
irq; it never touches the register. Removing the write drops the counter to
2 and the line releases.

### 4. Frame addresses and what the data says

Frame addresses live in the system info at these offsets:

```
[136] raw      0x9148
[138] filter   0x4904
[140] strength 0x4f40
[142] baseline 0x5d82
```

Sampled on this unit:

```
raw      @ 9148:  6a cb 6a cb ...    (0xCB6A = -13462)
baseline @ 5d82:  6a cb 6a cb ...    identical
filter   @ 4904:  00 00 00 ...       delta when nothing touches the panel
strength @ 4f40:  00 00 00 ...
```

So the `EVT_TYPE_STATUS_FORCE_CAL` / subtype `0x01` ("mutual negative
detect") that kept firing was **not** a broken baseline — the baseline had
correctly absorbed the `-13462` offset.

### 5. The remaining problem, stated plainly

`raw` stays exactly `6a cb`, sample after sample, while the frame counter
keeps incrementing. Real sampling has noise; a value that never moves one
LSB means the AFE is not receiving a real signal. With the baseline equal to
it, `filter` is a constant zero, no finger can cross the detection
threshold, and no ENTER event is ever generated.

Related observations:

* `A0 00 01` really starts the scan — `0x2000004a` goes `00 -> 50`. But if
  the gesture write `A2 03 00 00 00 03` follows it, the register drops back
  to `00`. Sending `A0 00 01` by hand afterwards brings it to `50` again, so
  the scan command is fine and something after it is not.
* Two error events show up after the full panel init,
  `f374010000000000` and `f384100000000000`. Neither type is in the vendor
  table, so they are firmware extensions, most likely reporting the same
  thing measured above.

The two explanations left are a Cx/panel dataset that does not match this
unit's routing, or excitation the vendor stack sets up somewhere still
unaccounted for. Either one wants a logic analyser capture of the working
MIUI stack on SDA/SCL (GPIO36/GPIO37) to diff against — guessing further has
stopped paying.

### 6. Controls that exist in this driver

```
/sys/devices/platform/4900000003.touchscreen/enable
    0  controller unpowered (display safest)
    1  powered and handshaked, sensing off
    2  sensing on
    3  panel init (A4 00 02) then sensing on
    4  full panel init (A4 00 03) then sensing on   <-- the one that works

/sys/devices/platform/4900000003.touchscreen/frame
    echo 30|31|32|33   request raw|filter|baseline|strength frame and report
                       whether the frame counter moved

/sys/devices/platform/4900000003.touchscreen/dbg
    echo 1             log every event, past the boot budget

/sys/devices/platform/4900000003.touchscreen/cmd
    w <bytes...>       raw write          (0xA4 is filtered, see below)
    r <op> <len>       write one byte, read len
    x <bytes...> <len> write, then read
    h <addr32> <len>   read a 32 bit addressed hardware register

/sys/devices/platform/soc@0/ae00000.display-subsystem/ae94000.dsi/ae94000.dsi.0/repower
    echo 1             re-send the 59 packet panel on-sequence
```

`repower` matters: poking the touch controller can leave the command mode
AMOLED dark while the SoC keeps scanning, and this brings it back without a
reboot.

### 7. Display safety

`0xA4` is filtered in the `cmd` poke box because it can kill the panel:

```
A4 00 01  FIFO flush      harmless, used by the driver
A4 00 02  panel init      did not black the panel in the end
A4 00 03  full panel init did black it once, `repower` recovered it
A4 01 xx  interrupt ctrl  the old "load data" mistake, do not send
A4 06 xx  load data       safe, this is how frames are requested
```


## p66 - ioff trim, gesture feature, frame statistics

Three new tools, all driven from `enable` and one new attribute, so a whole
experiment fits into a single boot:

```
echo 4 > .../enable   full panel init + scan          (unchanged)
echo 5 > .../enable   full init + ioff trim + scan
echo 6 > .../enable   full init + ioff trim + gesture + scan
echo 1 > .../raw      stop scan, read raw/flt/base, restart scan
```

`raw` prints one line per frame: node count, min, max, average and the first
eight samples. `min == max` over all 629 nodes is the whole story of this
bring-up: a live capacitance matrix never looks like that.

### What the build measured

```
sysinfo frames raw@9148 flt@4904 str@4f40 base@5d82
raw  @9148 n 629 min -13462 max -13462 avg -13462 head -13462 -13462 ...
base @5d82 n 629 min -13462 max -13462 avg -13462 head -13462 -13462 ...
flt  @4904 n 629 min -32742 max  32751 avg    470 head 19997 4045 20475 ...
```

Both SYS_CMD_SPECIAL_TUNING / SPECIAL_TUNING_IOFF (`A4 08 02 00`) and the
gesture feature the vendor writes right after sense on (`A2 03 00 00 00 03`)
are accepted by the controller (both return 0) and change nothing: raw and
baseline stay at one repeated -13462, which is also what the FW complains
about as FORCE_CAL / 0x01 "mutual negative detect". The filter frame is
uninitialised memory - it does not change between reads either, so it is not
a live matrix.

So the analog front end is not the lever. What is left is the FW's own panel
(CX) data, i.e. whether it ever ran a real mutual scan for this panel.

### New display safety fact

Running the full panel init **twice in one boot** wedges the DSI:

```
[drm:dpu_encoder_frame_done_timeout] [dpu error]enc32 frame done timeout
dsi_cmds2buf_tx: cmd dma tx failed, type=0x15, data0=0xfc, len=4, ret=-110
panel-xiaomi-umi: on-sequence: packet 37 dtype 0x15 failed (-110)
```

and this time `repower` did **not** recover it - the re-sent on-sequence dies
with -110 because the command DMA is already stuck. Only a reboot brought the
panel back. Rule for the next builds: at most one panel init per boot, and
`repower` is not a general escape hatch any more.

### Vendor reference, from a booted MIUI

MIUI is locked down (`ro.build.type=user`, `ro.debuggable=0`, no `su`, dmesg
and sysfs touch nodes denied to the `shell` user), so the vendor's raw frame
dump is out of reach. What could be read without root:

```
getevent -p  ->  /dev/input/event5 name "fts"
                 ABS 0x35 X 0..1079      ABS 0x36 Y 0..2339
                 ABS 0x30/0x31 area, ABS 0x39 tracking id
```

i.e. the vendor reports the panel resolution, not the 37x17 sensor matrix,
and touch events do reach the framework. The controller, the panel and the
flex are fine; the difference is on our side.

## The vendor's own boot log (root on MIUI)

MIUI is `user`/non-debuggable, but Magisk's `su` is present, so a direct
`adb shell su -c dmesg` works - the earlier "no root" conclusion was wrong
(PowerShell 5.1 mangles nested quotes in `su -c "..."`, which is what made it
look like `su` was missing; a single-token command needs no quoting at all).

What a real probe looks like:

```
[ FTS ] fts_probe: Probe start
[ FTS ] parse_dt:fw_name: st_fts_j2_1.ftb / j2_2.ftb / j2_3.ftb
[ FTS ] FW VER = 0132
[ FTS ] CONFIG VER = 004C
[ FTS ] CX VER = FFFF
[ FTS ] AFE VER: CFG = 05 - CX = 05 - PANEL = 05
[ FTS ] Lockdown:0x53,0x42,0x32,0x01,0x74,0x02,0x32,0x01
[ FTS ] parseBinFile: FILE Fw Version = 0132
[ FTS ] parseBinFile: FILE Config Version = 0000004C
[ FTS ] parseBinFile: CX Version = FFFF
[ FTS ] fts_mode_handler: Sense ON
```

Three things fall out of it:

1. **`CX VER = FFFF` is normal.** MIUI reads the same value, so the CX data
   is not missing on this unit. Our log printed `d[22..23]` as `cfg`; the real
   CONFIG VER is `d[20..21]` = `004C` and `d[22..23]` is the config project id.
2. **Our system info read matches MIUI byte for byte** - FW 0132, CFG 004C,
   AFE 05/05/05, same lockdown code. The protocol side of this driver is done.
3. **The probe does no panel init at all.** The whole sequence is
   `fts_init` = soft reset (`FA 20000024 80`) + `readSysInfo(0)` (plain
   framebuffer read, no `A4 06 01`) followed by
   `fts_mode_handler` = `setScanMode(ACTIVE, 0x01)` + gesture feature.
   There is no `A4 00 02`, no `A4 00 03`, no ioff trim.

## The reference frame

`cat /sys/bus/i2c/devices/3-0049/ms_raw` with root returns the vendor's own
`MsTouchRaw,17,37` matrix. It is node specific and small, roughly -300..+340,
with the first two columns larger (865..2201). That is what a healthy raw
frame on this panel looks like - against the single repeated `-13462` this
driver reads on every node.

## Why this points at the panel init

The full panel init is the one thing this driver does that the vendor does not,
and the "mutual negative detect" storm plus the frozen raw frame both started
right after the first one. p67 therefore adds

```
echo 7 > .../enable    soft reset + read sysinfo + scan, no panel init
```

which is the vendor's probe sequence, and keeps `enable 4/5/6` for comparison
and for a controller that was already poked into a bad state.

## p67 / p68 - vendor parity does not fix the frame

p67 added

```
echo 7 > .../enable    soft reset (FA 20000024 80) + readSysInfo + scan
```

which is the vendor's whole probe sequence - no panel init. The system info
comes back identical to MIUI's (FW 0132, TX 17, RX 37, same frame addresses),
and the raw frame is still one repeated -13462 on all 629 nodes.

p68 added two ways to read a frame:

```
echo 1 > .../raw    keep scanning, wait 200 ms, read   (vendor shape)
echo 2 > .../raw    sense off, 50 ms, flush, read, resume
```

and a scan mask sweep (0x01, 0x03, 0x05, 0x09, 0xFF). Raw stays -13462 in
every single combination, while the filter frame tracks it exactly
(raw == baseline, filter == 0), which is what the controller believes.

This is the same read procedure the vendor's own `ms_raw` attribute uses
(`setScanMode(ACTIVE,01)`, 200 ms, `setScanMode(ACTIVE,00)`, 50 ms, flushFIFO,
getMSFrame3(MS_RAW)), and on MIUI the same attribute returns a node specific
matrix around -300..+340. So the procedure is not the difference; the AFE
state at read time is.

Poking the same framebuffer address with the other memory opcodes shows the
two views are different engines: `FA 00009148` returns code-like repeats
(`28 68 40 1c`), `A8 9148` returns zeros, `A6 9148` returns `6a cb`. The 0xA6
window is the FW framebuffer and it is only meaningful for data the FW has
actually produced.

Open question, next measurement: MIUI can also be asked for its own CX data
(`cat /sys/bus/i2c/devices/3-0049/ms_cx_total`). If that is populated on MIUI
and the compensation it describes is what the AFE needs, the remaining step is
to get the same CX data into the controller at boot - the one thing this
driver has never done and never checked.

## p69 - p71 - and what the event log actually says

Three more things were matched to the vendor and changed nothing:

- p69: the vendor power sequence exactly (vdd first, 15 ms, `regulator_set_load`
  100 mA vote on avdd, then avdd).  The load vote is accepted and the rail
  stays at 3300 mV; raw is unchanged.
- p70: a runtime DSI poke (`echo "<7 byte header> <payload> ..." > dsi` on the
  panel device).  The MIUI `mi,mdss-dsi-vi-setting-low/high` commands
  (`page 1` + `B9 1A...` / `B9 1F...`) go through and change nothing either.
- p71: Sense ON with the full active mask `0xFF`, which is what the working
  upstream mainline port uses, instead of `0x01`.  Accepted, scan register
  reads 0x50, raw is still one repeated -13462.

The chip's stored panel data is *identical* to MIUI's, byte for byte:

```
echo "w a4 06 50" > .../cmd      # LOAD_PANEL_CX_TOT_MS_TOUCH
echo "x a6 00 00 40" > .../cmd   # -> a5 50 02 00 | 08 00 18 00 1c 00 1c 00 ...
```

A5 signature, load type 0x50, then 8, 24, 28, 28, ... which is exactly the
`ms_cx_total` matrix MIUI prints (`MsTouchTotalCx,20,37`, `R00, 8, 24, 28, ...`
and its last node -16).  So the controller's CX/panel compensation is intact.

### The event log

With the whole FIFO drained the boot looks like this:

```
ev 4301a40001000005   echo of A4 00 01 (FIFO flush)
ev 4301a00000000004   echo of A0 00 00 (sense off)
ev 4301a000ff000003   echo of A0 00 FF (sense on)
ev 4303f82a00000003   STATUS / FRAME_DROP, and then hundreds more
ev 4303f82a00000002
ev 4303f82a00000001
...
ev 4303b1430000000f
```

`0x43` is STATUS, `0x03` is EVT_TYPE_STATUS_FRAME_DROP, and byte 7 counts down
because the FIFO is full and we are draining it.  The controller produces a
frame drop for *every single frame* from the moment sensing comes on, and it
also reports FORCE_CAL / 0x01 "mutual negative detect" once.

That is the missing half of the picture: the analog front end is not silent, it
samples and its result is rejected as negative on every frame.  Raw, baseline
and filter are consistent with that (raw == baseline == -13462, filter == 0).

### What is left

Every digital difference that could be found has been removed: reset, sysinfo,
CX data, scan mode and mask, gesture feature, ioff trim, frame read procedure,
interrupt model, power sequencing, load votes, VI setting.  The remaining
suspect is the analog side of the panel/controller interface, i.e. something
that neither the DT nor the command set above can express.

### Upstream status (found by searching, not by guessing)

A mainline driver for exactly this chip family exists and is being upstreamed:

- `[PATCH v4 00/11] Input: support for STM FTS5`
  https://lkml.iu.edu/hypermail/linux/kernel/2604.1/01858.html
- a working port already in a mainline tree:
  https://github.com/sm7150-mainline/linux/commit/36f473a81f63ecfbe58d5d13f6ed998ce7885c50

Reading that driver against this one turned up the two differences that were
then tested (the 0xFF scan mask, and the CRC driven init selection), and it is
also the cheapest way to stop guessing: it is the reference implementation, it
uses plain `i2c_transfer()`, and it carries the full init flow including the
`pollForErrorType()` CRC checks that decide between no init, panel init and
full panel init.  The plan that follows from this is to wrap the bit-banged bus
in a real `i2c_algorithm`/`i2c_adapter` (the bus works; only the QUP DMA path is
broken) and let that driver probe 0x49 unchanged.

## The .ftb image has no CX section - do not force flash

Checked before touching the controller flash, because the user asked whether
MIUI would really re-program it.

`fts_fwupdate_store()` parses `path force keep_cx`:

    path    NULL -> use the compiled in image (getFWdata() checks "NULL")
    force   1    -> skip the version comparison in flash_burn()
    keep_cx 1    -> keep the CX/panel init pages, 0 -> erase and rewrite them

`flash_burn()` does honour force: with force=1 the `if (!force_burn)` version
check is skipped and the programming path (reset, hold_m3, UVLO, unlock, erase,
write, verify) runs unconditionally.  So a forced flash is real.

But the CX rewrite only happens when `keep_cx <= 0` *and* the image actually
carries CX data:

    if (keep_cx > 0)  erase SKIP_PANEL_CX_INIT        // CX preserved
    else              erase SKIP_PANEL_INIT           // CX pages erased
    ...
    if (fw.sec2_size != 0 && (force == CRC_CX || keep_cx <= 0))
            fillFlash(CX area, ...)

And the image built into the vendor driver has no CX section at all.  Parsing
`downstream-kernel/.../fts_521/fts_fw.h` (`myArray`, 100476 bytes):

    signature  55 aa 55 aa
    sections   sec0 = 97768 (fw code)
               sec1 =  2640 (config)
               sec2 =     0   <- CX / panel init data: EMPTY
               sec3 =     0
    68 + 97768 + 2640 = 100476  (closes exactly)

So `echo "NULL 1 1"` would rewrite FW+CFG and leave the CX alone, and
`echo "NULL 1 0"` would erase the CX area with nothing to put back - the driver
even warns about exactly this case:

    WARNING!!! Erasing CX memory but no CX in fw file!
    touch will not work right after fw update!

Neither helps and the second one damages a working MIUI touch.  The controller's
CX/panel data is only ever (re)generated by `production_test_initialization(
SPECIAL_FULL_PANEL_INIT)`, which is the full panel init this driver already
does (and which correctly brings back the panel geometry in sysinfo).

## The real .ftb from the panel/image author - still no CX, and older

The image author supplied the actual firmware file that ships with these builds
(`st_fts_j2_2.ftb`, 117552 bytes) plus the production limit table.  Parsed with
`tools/ftb-parse.py`:

    signature  55aa55aa
    ftb_ver    1
    chip id    36 39              <- this controller
    svn rev    0x3444
    fw ver     0x0124             <- chip runs 0x0132
    cfg ver    0x0048             <- chip runs 0x004c
    sections   fw code  113996 bytes
               config     3488 bytes
               CX/panel      0 bytes   <- EMPTY
               sec3          0 bytes

Two conclusions, both negative:

1. **No CX section here either.**  So neither MIUI's compiled in image
   (`fts_fw.h`, sec2 = 0) nor the shipped `.ftb` carries the panel
   compensation data.  It only ever exists inside the controller, (re)generated
   by the firmware from the panel config during a full panel init.
2. **It is older than what the chip runs** (fw 0x0124 vs 0x0132, config 0x0048
   vs 0x004c).  `flash_burn()` refuses such an image unless force is set, and
   forcing it would *downgrade* a working controller - with no CX to gain.

So the .ftb avenue is closed for good, and the question "did you put the .ftb
in" is answered: the file exists, but it is neither the one the controller runs
nor does it contain the data this bring-up is missing.

For the record, what the controller reports about itself (and what MIUI reads
identically): FW 0132, CONFIG VER 004C, CX VER FFFF, AFE 05/05/05.


## 10. 2026-10-25：刷 FW 把 CX 擦空，控制器变空片（当前状态：触摸不可用）

### 10.1 起因

补上 pinctrl（驱动要的状态名是 default/sleep，见 ts521/fts.h 对
PINCTRL_STATE_ACTIVE 的重定义）之后，控制器仍然只在上电时发几十个
EV_STATUS（43 03 F8 28 ...），之后完全静默、evtest 零事件，
而 raw 帧依旧是全节点 -13462 —— 和本节前面几轮的结论一致：CX 无效。

于是按「最小 FW 下载」方案，把厂商的 tsFlash.c 移植进来（连带
tsTest.c 180 KB、tsCompensation.c、224 个缺失常量）并在
/sys/bus/i2c/devices/13-0049/fwupdate 开了入口。

### 10.2 致命的一步：keep_cx = 0

lashProcedure(path, force, keep_cx)：

- keep_cx = 1 → SKIP_PANEL_CX_INIT，**保留** CX
- keep_cx = 0 → ERASE_ALL，**擦掉** CX

而 st_fts_j2_2.ftb 自身没有 CX 段（sec2_size = 0），厂商代码警告得很清楚：

`
WARNING!!! Erasing CX memory but no CX in fw file! touch will not work right after fw update!
`

CX 被擦空后：断电重启 → FW 不跑 → 所有系统命令 checkEcho 超时
（ERROR 80000007 = ERROR_TIMEOUT）→ 之后 chip id 读成 0000 →
现在 w = 0xFFFF cfg = 0xFFFF（flash 全 0xFF，空片）。

### 10.3 为什么救不回来

厂商的恢复序列（ts_fw_update()）：

`
flashProcedure(force) → fts_system_reset() → pollForErrorType(CX CRC)
  → 有 CRC 错 → flashProcedure(default_fw_name, CRC_CX, 0)
  → 比较 u8_cfgAfeVer / u8_cxAfeVer / u8_panelCfgAfeVer
  → fts_chip_initialization(SPECIAL_FULL_PANEL_INIT)   ← 用它重建 CX
  → fts_init_sensing()
`

阻塞点：lash_burn() **先**发 FW 的 ts_system_reset()，成功了才
hold_m3() 进下载模式。空片没有 FW → 第一步就超时 → 永远进不了下载模式：

`
flash_burn: system reset FAILED!
Wait for flash TIMEOUT! ERROR 80000007
flash erase FAILED! ERROR 80080000
flashProcedure: ERROR 82000000
`

ts_chip_powercycle() 之后再试（echo 9）也一样：chip 仍读 0xFFFF。

### 10.4 现存的开关与安全措施

/sys/bus/i2c/devices/13-0049/fwupdate 按位组合：

| 值 | 动作 |
|---|---|
| 1 | 刷 FW |
| 2 | production_test_initialization(SPECIAL_FULL_PANEL_INIT) + cleanUp |
| 4 | ts_system_reset |
| 8 | ts_chip_powercycle（echo 9 = 硬复位 + 刷写） |

- 刷写期间 disable_irq()：第一次没有这层保护时整机挂死过一次（IRQ 处理函数
  与刷写路径互锁）。
- FLASH_RETRY_COUNT 从 200 降到 20，失败快速返回。
- 驱动初始化失败时**保持绑定**，否则 sysfs 全消失、连救的入口都没有。
- 救急镜像 out/boot-umi-notouch.img：DT 里触摸 status = "disabled"。

### 10.5 结论

- 触摸控制器**当前不可用**（空片 + 无 ROM 下载模式入口）。
- 不能靠启动 MIUI 恢复：userdata 已是我们的 Arch 根分区，MIUI 起不来。
- 想恢复只剩：产线/服务工具，或者把 userdata 让给 MIUI 重装。
- 其它一切正常：WiFi（固定 MAC 00:03:7f:12:a4:a4）、USB RNDIS 网卡、
  串口控制台、SSH 都不受影响。

### 10.6 ROM 下载模式探针（用户态，2026-10-25 晚）

内核路径看不到中间状态，所以写了 	mp/fts_hw.py：用 I2C_RDWR 直接对
/dev/i2c-13 发 FTS 的 HW 寄存器协议，每一步都能看到返回值。需要
python3（pacman -S python；/dev/i2c-13 来自 i2c-dev）。

协议（全部来自厂商 tsFlash.c / tsHardware.h）：

`
0xFA <addr:4B> <data...>    写 HW 寄存器
0xFB <addr:4B>              读（再取 N 字节）

0x20000000  ADDR_DCHIP_ID          芯片 ID（正常应为 36 39）
0x20000004  ADDR_DCHIP_FW_VER      FW 版本
0x20000024  ADDR_SYSTEM_RESET      SYSTEM_RESET_VALUE = 0x80；hold_m3 写 0x01
0x20000025  ADDR_BOOT_OPTION       "REMAP / Boot option"，flash_unlock 写 0x20
0x2000006A  erase                  flash_unlock 后写 0xA0 启动擦除
0x2000006B  unlock 第二段          写 0x00
0x20000071  FLASH_DMA_CODE0        0x71 / 0xC0
0x20000078  ADDR_CRC               低 2 位 = CRC 错误标志
`

实测（空片状态）：

| 操作 | 结果 |
|---|---|
| i2c 地址扫描 0x20–0x77 | 只有 **0x49** 应答 |
| 裸读 8 字节 | 00 00 00 00 00 00 00 00 |
| HW 寄存器读（0xFB 框） | 全部 FF FF（读长度 1 时直接 EIO） |
| 写 0x24 = 0x01（hold_m3） | 写入 ACK，事后读回仍 FF |
| 写 0x24 = 0x80（system reset） | 同上 |
| lash_unlock（0x25=0x20、0x6B=0x00） | 同上 |
| 单字节命令扫描（0xA0–0xAB、0xF0–0xFF、0x00/01/02/05/0x40） | 之后裸读全是 00，无有效响应 |
| 长复位（RESET 拉低 200 ms 再释放） | chip id 仍 FF FF |
| 整轨断电 8 s（unbind→bind） | 芯片状态无变化；且 unbind 不释放 legacy gpio_request，重绑时报 Failed to get gpio 589 (-16 EBUSY)，必须重启才能重新绑定 |

结论：**控制器在硬件层面还活着（ACK i2c），但下载/寄存器接口不响应任何
我们能构造的时序**。要么需要 ST 的 boot ROM 协议文档，要么需要产线工具；
纯靠猜时序已经到尽头。

另外注意：lush 后 load program DONE/load config DONE 说明当初那次刷写
是成功的（代码页写进去了），所以现在芯片里是**有效代码 + 空 CX**；它之所以
不再响应，是 FW 在 CX 无效时不会启动应用层，而 ROM 又不实现 HW 寄存器读。

### 10.7 彻底断电重上电（unbind → 等 10 s → bind）也无效

先修了一个真 bug：ts_remove() 不释放 ts_set_gpio() 里用 legacy API
gpio_request() 拿的引脚，导致重新 bind 时报
ts_gpio_setup: Failed to get gpio 589 (code: -16)（EBUSY）。补上
ts_gpio_setup(gpio, false, 0, 0) 之后，unbind/bind 可以正常重来了。

但即使这样：**拔掉两路电源 10 秒再上电**，初始化后仍然是

`
[ FTS ] Device Initialization:
[ FTS ] chip id: FF FF!
[ FTS ] wrong chip id detected!
...
[ FTS ] fts_system_reset...failed after 3 attempts: ERROR 80000B07
`

也就是说芯片的固件确实起不来，ROM 也不吐事件/不实现寄存器读。软件侧到此为止。

备份信息：D:\project\UMIBackup 是这台机器的 TWRP 全分区备份
（HyperOS 1.0.5 / MIUI v816）：oot.emmc.win、dtbo.emmc.win、
ecovery.emmc.win、super.emmc.win（9.1 GB，里面是 system 1148 MiB /
vendor 1661 MiB / product 4120 MiB / odm 128 MiB / system_ext 634 MiB /
mi_ext 3 MiB）。super 里没有 .ftb 文件（HyperOS 的 vendor 是压缩 erofs），
FW 是编在内核里的（ts_fw.h）。
## 11. 2026-10-25 深夜：控制器完全救活（真凶是两个 SPI/I2C opcode + 缺一条存盘命令）

### 11.1 根因一：硬件寄存器读用的是 SPI 的 opcode

`fts_lib/ftsHardware.h` 里有两份常量表：上面一份按 `#ifdef I2C_INTERFACE`
区分 I2C/SPI，下面（第 340 行往后）还有一份 V521 的"统一"表，**无条件**重新
定义同名宏，把 I2C 的值覆盖成 SPI 的值：

| 宏 | I2C 正确值 | 被覆盖成（SPI） | 后果 |
|---|---|---|---|
| `FTS_CMD_HW_REG_R` | `0xFA` | `0xFB` | 所有 HW 寄存器读（chip id / fw ver / 状态位）全部返回 0x00 或 0xFF |
| `FIFO_CMD_READALL` | `0x86` | `0x87` | 事件 FIFO 读错命令 → 触摸报文从来没被解析过 |
| `FTS_CMD_FRAMEBUFFER_R` | `0xA6` | `0xA7` | raw 帧读错命令 |
| `FTS_CMD_CONFIG_R` | `0xA8` | `0xA9` | 配置区读错命令 |

删掉下面那份里的这四条（保留同值的写命令）后：

    chip id: 36 39!                    <- 之前永远是 FF FF / 00 00
    Screen Resolution = 2339 x 1079

用 `tmp/fts_hw.py raw "fa 20 00 00 00" 4` 可以现场验证：`0xFA <addr>` 读回
`36 39 03 00`，`0xFB <addr>` 读回全 0。**这颗芯片的 I2C 读就是 0xFA**（和
新版权威头文件 `I2C_INTERFACE` 分支一致）。

### 11.2 救砖：写-only 盲刷（FW 全丢时也能刷）

FW 被擦掉后 `0x200000xx` 状态寄存器读不回来，`wait_for_flash_ready()` 永远
超时，于是 `flash_burn()` 在擦除后就 abort，**再也没有人把代码写回去**。

按 `fts_flash_blind` 开关走盲刷：`wait_for_flash_ready()` 超时后改成固定等
2.5 s 继续，因为擦除/DMA 全是纯写命令，状态位只是"确认"用。整条链路：

    system reset -> hold_m3 -> uvlo/autopowerdown -> flash_unlock
    -> erase_unlock -> 按页擦除 -> fillFlash(code) -> fillFlash(config)
    -> DMA -> system reset

刷完 `chip id` 立刻变回 `36 39`（`echo 256 > fwupdate`）。

### 11.3 根因二：全屏初始化算完 CX 不写 flash

`production_test_initialization(SPECIAL_FULL_PANEL_INIT)` 只让 FW 在 RAM 里
算补偿数据，**厂商代码里没有落盘那一步**，于是每次复位又是 CX CRC 错：

    echo found after 3 error event(s)      <- CX CRC 事件排在 echo 前面
    after PI cx 0x0000 afe cfg 0x05 cx 0x00 panel 0x00

补上一条 `SYS_CMD_SAVE_FLASH (0xA4 0x05)` + `SAVE_CX|SAVE_PANEL_CONF (0x06)`
之后：

    after save: cx 0xFFFF  afe cfg/cx/panel = 08/08/08

`0xFFFF` 正是原厂 CX 版本号。这条命令已经写进 `fwupdate` 的 `mode 2`。

### 11.4 原厂固件从 HyperOS boot 里挖出来

`D:\project\UMIBackup\boot.emmc.win` 的内核里编着 `fts_fw.h`，用
`tools/extract-boot-fw.py` 可以直接把 `.ftb` 抠出来（magic
`55 aa 55 aa 01 00 00 00 36 39`）：

| | `st_fts_j2_2.ftb`（镜像作者给的） | `st_fts_umi.ftb`（从 stock boot 提取） |
|---|---|---|
| fw ver | 0x0124 | 0x0123 |
| cfg ver | 0x0048 | **0x004F** |
| svn | 0x3444 | 0x3956 |
| 文件内 CX ver | 无 CX 段 | **0xFFFF**（和芯片原状一致）|
| AFE ver | 05 | 08 |
| 传感器节点 | 629 | 560 |

super 里的 system/vendor/product/odm/system_ext 全部是 ext4，**没有任何
`.ftb`**（只有 product 里一处 `.ftb` 字样，落在压缩流里，是假命中），所以
触控固件唯一的来源就是内核里那个数组。

### 11.5 现在的状态

    6.12.94-umi-dirty, boot-umi-touchfix7.img
    chip 3639 / fw 0x0123 / cfg 0x004F / cx 0xFFFF / afe 08/08/08
    初始化一次通过，零 CRC 错误，mode_active = 00FF0000, IRQ 正常

**唯一剩下的问题**：AFE 采到的 raw 帧是常数。

    nodes=560  min=-15774 max=0 mean=-7887
    head: -15774 0 -15774 0 ...        (16x35 节点，奇数节点恒为 0)
    addr raw=0x8AB0 filt=0x4274 stren=0x48B0

也就是每两个 16bit 字里只有一个有值、且 560 个节点**全同一个值**，等于前台
模拟前端没有任何信号进；FIFO 里每秒只有 3 个 `43 03`(STATUS/FRAME_DROP)，
没有任何 `0x13/0x23/0x33`（进入/移动/离开）触摸报文。这个症状和**动驱动
之前**完全一样，说明它不是我们刷坏的，而是从 bring-up 第一天就在的。

供电已排除：`vreg_l1c_1p8` 1800 mV、`touch_vddio_vreg` 3300 mV 都是 enabled
且带负载。剩下只能是传感器/AFE 侧的硬件问题（触控 FPC、面板换过、或
VTX/VRX 未连），或 MIUI 在别处开启了某个我们还没打开的硬件使能。

### 11.6 又对齐了三处和 MIUI 的差异（AFE 仍然没信号）

继续和厂商 `downstream-kernel/.../fts_521` 逐行对比，又找到三处：

1. **扫描掩码**：厂商 `fts_mode_handler()` 发的是
   `setScanMode(SCAN_MODE_ACTIVE, 0x01)`（只开多点触控），我们从 sm7150
   移植来的那份发 `0xFF`（"开 config 支持的所有扫描"）。
   0xFF 会让固件去做 key/hover/proximity/force 这些这颗面板没有的扫描，
   结果**每帧 elaboration 失败**，FIFO 里只有 `43 03`(STATUS/FRAME_DROP)，
   一个触摸点都不报。已改成 `ACTIVE_MULTI_TOUCH`。
2. **sense 重启**：厂商 `fts_init_sensing()` 在 `fts_mode_handler()` 之后还有
   一段（原在 `CONFIG_TOUCHSCREEN_FOD` 里）：`setScanMode(0,00)` → 等 50 ms
   → `setScanMode(0,01)`。已无条件补上。
3. **中断使能**：厂商末尾有 `fts_enableInterrupt()`，我们这行原来是注释掉的。
   已恢复（并保留 `fts_resetDisableIrqCount()`）。

改完掩码之后 `mode_active = { 00010000 }`，FRAME_DROP 洪水消失（IRQ 从
2.7 次/秒变 0），但**仍然没有任何触摸报文**：

    FIFO 直读 25 秒（25 × mode 1024 直方图）: 0 个事件
    按住屏幕 45 次 raw 采样: spread=0（完全不变）
    requestSyncFrame(MS_RAW/FILTER/STRENGTH/BASELINE) -> 80020007 = ERROR_REQU_DATA|ERROR_TIMEOUT

顺带把**工厂 lockdown/production 区**读出来了（用 `A4 06 7x` 加载 +
`A6 00 00` 读 28 字节），这块**没被我们擦坏**：

    lockdown 0x70: A5 70 02 00 ... 53 42 32 01 74 02 32 01
                   -> lockdown_info = 53 42 32 01 74 02 32 01

按厂商 DT 的选择表：

| | tp-vendor | tp-module | 固件 |
|---|---|---|---|
| cfg_0 | 0x38 | 0x00 | `st_fts_j2_1.ftb` |
| **cfg_1** | **0x42** | **0x01** | **`st_fts_j2_2.ftb`** ← 我们这颗 |
| cfg_2 | 0x42 | 0x02 | `st_fts_j2_3.ftb` |

`lockdown_info[1]=0x42`、`lockdown_info[7]=0x01` → **`j2_2` 是对的**（镜像作者
给的原始文件）。0x71..0x77 返回 `temp[4]=0x32`（NO_DATA），即只有 0x70 这条
记录存在，符合预期。

判定帧读取链路是否正常的方法：`raw` 现在一次读四种帧，结果是

    MS_RAW      = -13462 (全节点一致)
    MS_FILTER   = 0
    MS_STRENGTH = 0        <- strength = baseline - raw，和 raw 自洽
    MS_BASELINE = -13462

四种帧自洽，说明**读链路是好的**，是模拟前端本身给出了一条平坦的基线。

结论：数字侧（固件、配置、CX、lockdown、中断、扫描）已经全部对齐 MIUI，
剩下的缺口在模拟前端拿不到信号，而动驱动之前 `raw` 就已经是 `-13462`，
说明这一环从 bring-up 第一天起就没通。下一步只能靠「跑一次 MIUI」来判定
是硬件/工厂数据问题，还是仍有我们没对齐的初始化步骤。

### 11.7 与 LineageOS 的 umi 移植逐项对照（结论：驱动侧已完全对齐）

参考树：`AstideLabs/android_kernel_xiaomi_sm8250`（LineageOS sm8250 的 fork，
`arch/arm64/boot/dts/vendor/qcom/umi-sm8250.dtsi` 里有 umi 的 `fts@49`）。
（`sm8250-mainline/linux` 里**没有 umi**，那棵树帮不上忙。）

| 项目 | LineageOS umi | 我们 | 结果 |
|---|---|---|---|
| 触摸供电/GPIO | `avdd=<&touch_vddio_vreg>`、`vdd=<&pm8150a_l1>`、rst 38、irq 39 | 同 | 一致 |
| 触摸调参表 | up-threshold 40/120/80、tolerance 5/35/25、各 zone 矩形 | 同 | 一致 |
| 面板 | `xiaomi 42 02 0b`（mp 变体 `j2-mp-42-02-0b`）| `j2_mp_42_02_0b` | 一致 |
| 面板 on-command | **653 字节** | **652 字节**（DT 存储少 1 字节）| 一致 |
| 初始化流程 | `fts_fw_update()`：crc_check → flashProcedure → reset → CX/panel CRC → 依 AFE 版本选 init → chip_init → init_sensing | 同 | 一致 |
| `PRE_SAVED_METHOD` / `FW_UPDATE_ON_PROBE` | 都定义 | 都定义 | 一致 |
| `fts_init_sensing` | threaded irq → mode_handler → sense off/50ms/on → enable_irq | 同（§11.6 补齐）| 一致 |
| 中断方式 | `request_threaded_irq(NULL, handler, IRQF_ONESHOT)` | 同 | 一致 |
| I2C opcode | 头文件里同样被 SPI 值覆盖（0xFB/0x87/0xA7）| 已修正 | 对方的坑 |
| 编进内核的 FW | 100476 B，实测刷入是 **2559x1439 / 15x30**（别的面板）| 试过，不可用 | 不可用 |
| `.ftb` 固件文件 | TheMuppets 的 umi blobs 里 **没有**（firmware/ 只有音频/IPA/相机 31 个文件）| 我们也没有 | 拿不到 |

### 11.8 代码段 / 配置段混搭实验：固件拒绝

`j2_2` 的 code（113996 B）+ MIUI 镜像的 config（3480 B, cfg 0x004F, AFE 08）
拼成 `hybridA.ftb` 刷入：

    flashProcedure -> 0x8219xxxx (失败)
    之后 sysinfo: fw 0x0000, txrx 0x0

说明**固件会校验 code 与 config 的配对**，不能混用。已恢复 `j2_2` 全套：

    chip 3639 / fw 0x0124 / cfg 0x0048 / cx 0xFFFF / afe 05/05/05 / 17x37 / 2339x1079

（两份 config 前 3480 字节有 **23.9%** 不同；cfg 头部 byte14-15 是 cfg 版本
`48 00` vs `4f 00`，byte17 是 AFE 版本 `05` vs `08`。）

至此驱动、DT、面板时序、中断方式与 MIUI/LineageOS **已无可对比的差异**，
剩下的缺口是出厂烧在芯片里的 FW 与 CX 内容 —— MIUI 和 LineageOS 都因为
"芯片版本更新就不刷"而从未写过它，公开渠道也没有。

## 12. 定案：缺的是 PM8150B GPIO5 的 boost 电源（已修好）

§11 的推断里只有一条是错的：**模拟前端不是"坏了"，也不是缺出厂 FW/CX，
而是这颗板级 boost 电源从来没被打开过。**

### 12.1 线索来源

`https://github.com/reAAAq/UniXNU-umi`（iPadOS 17 on umi）第 80 版
commit `138d6cb`：

```
fix(touch): enable the native always-on boost before FTS startup

The inherited PM8150B GPIO5 was output-low while the native board DT marks
vdd_boost_vreg always-on. Require the observed PMIC/pin profile and EE0
ownership, enable only SID2/C444 bit7, wait 4 ms and verify the readback.
```

也就是说，**这颗 GPIO 在别人的移植里同样是 output-low，把它拉高之后
ST FTS 触摸才真正可用**（原话：机主确认触摸有效）。

### 12.2 下游 DT 里的这颗电源

`dump/downstream.dts`：

```dts
vdd_boost_vreg {
    compatible = "regulator-fixed";
    regulator-name = "vdd_boost_vreg";
    startup-delay-us = <0xfa0>;      /* 4000 us */
    enable-active-high;
    regulator-always-on;
    gpio = <0x654 0x05 0x00>;        /* PM8150B GPIO5 */
};
```

它**没有任何 consumer**，原厂就是靠 `regulator-always-on` 常开。

### 12.3 为什么主线上它没开

原厂 dtbo 补进来的那份节点用的是**写死的 phandle**（`00 00 03 2d` = 813），
而主线 DTB 里 PM8150B 的 gpio 控制器 phandle 是 `0xdb`（219），于是：

```
platform soc@0:vdd_boost_vreg: deferred probe pending:
    reg-fixed-voltage: can't get GPIO
```

—— 节点在，但永远拿不到 GPIO，boost 一直是低电平。

### 12.4 修法

`dts/sm8250-xiaomi-umi-common.dtsi` 里用 label 重新声明一份（不用同名，
避免和 dtbo 补进来的坏节点打架）：

```dts
vdd_boost_reg: regulator-vdd-boost {
    compatible = "regulator-fixed";
    regulator-name = "vdd_boost_reg";
    enable-active-high;
    gpio = <&pm8150b_gpios 5 GPIO_ACTIVE_HIGH>;
    regulator-always-on;
    regulator-boot-on;
    startup-delay-us = <4000>;
};
```

### 12.5 结果：触摸当场活了

同一颗芯片、同一份 FW/CX，只多了这颗 GPIO 和 4 ms 上电延时：

| | boost 关 | boost 开 |
|---|---|---|
| `raw` MS_RAW | `-13462` 全节点一致，spread=0 | `min=-6178 max=9491 mean=321 spread=15669`，头两节点 `4140 / -2505` |
| MS_FILTER | 0 | `-30..20` |
| 中断计数（45 s） | 不动（3） | **3 → 485** |
| input 事件（45 s） | 0 | **1400 个**：`ABS_MT_POSITION_X/Y`、`BTN_TOUCH` |

`abs_x 439 / abs_y 1787` 落在 1080×2340 内，量纲正确；多点报文的
`ABS_MT_TOUCH_MAJOR/MINOR/PRESSURE` 也都有值。

### 12.6 顺带把出厂 FW 也找回来了

§11 说"出厂 `0x0132/0x004C` 拿不到"—— 其实它就在**我们自己的原厂 boot
分区**（`dump/boot-stock.img`）里，以 `fts_fw.h` 的形式编进内核：

```
python tmp/ftb-scan.py dump/boot-stock.img tmp/stockfw
```

8 个 `.ftb` 里第 4 个就是 **svn 0x5072 / fw 0x0132 / cfg 0x004C**。已刷入，
芯片现在报的就是出厂版本：

```
fw 0x0132 svn 0x5072 cfg 0x004C | afe cfg 0x05 cx 0x05 panel 0x05 | txrx 17x37
```

（`0x0132` 比仓库里那批 `j2_2` 0x0128 和 MIUI vendor 的 0x0124 都新。）

### 12.7 产线 MP 测试现在能跑完

`fts521/fts_lib/ftsTest.c` 里本来就有完整的产线测试。把 MIUI
`/vendor/firmware/stm_fts_production_limits_2.csv`（`FORCE_LENGTH 17` /
`SENSE_LENGTH 37`，正是 17×37 的 j2_2 模组）装上之后：

```
echo 2048 > /sys/bus/i2c/devices/13-0049/fwupdate   # 只跑 ITO -> 0 (PASS)
echo 4096 > /sys/bus/i2c/devices/13-0049/fwupdate   # ITO+初始化+数据测试
```

boost 没开时 4096 死在 `MS RAW MIN MAX TEST`（全节点 `-13462` 超出
`[-8000, 8000]`）；boost 打开后 `raw` 与中断都正常。

### 12.8 结论修正

§11 的结论"差的是出厂 FW 与 CX"**是错的**。真正的缺口是**一颗板级电源
使能**：`PM8150B GPIO5`（`vdd_boost_vreg`）。有它，自算的 CX 和
`j2_2`/出厂 `0x0132` 都能正常出帧；没它，任何 FW/CX 组合都只有 `-13462`。

## 13. "用一阵子就点不动"：fb blank 把驱动永久停在 suspend（已修）

上一节解决的是"一点都点不动"，这一节是另一个更阴的问题：**刚开机触摸好的，
用一会儿（尤其是屏幕灭过一次之后）就彻底没反应了**，中断计数冻结，FIFO 里一个
事件都没有，只能重开会话/重启内核。

### 13.1 现象量化

```
# 用户在正常点屏幕，中断计数一动不动
$ grep fts /proc/interrupts
165:       4321  ...  fts        # 15 秒里点了 20 下，4321 还是 4321
$ cat /sys/class/graphics/fb0/blank   # 空
$ cat /sys/class/drm/card1-DSI-1/dpms # On   ← 屏其实是亮的
$ cat /sys/class/i2c/devices/13-0049/mode_active
{ 00010000 }                          # 驱动自己认为 sense on
```

而芯片本身是活的：`echo 512 > fwupdate` 能读出 `fw 0x0132 / cfg 0x004C`，
`raw` 帧数据也还在（只是不再更新）。

### 13.2 根因

drivers/input/touchscreen/fts521/fts.c 的 fb notifier：

```c
case FB_BLANK_POWERDOWN:
        queue_work(info->event_wq, &info->suspend_work);
case FB_BLANK_UNBLANK:
        queue_work(info->event_wq, &info->resume_work);
```

`fts_suspend_work()` 里做了三件致命的事：

```c
fts_disableInterrupt();                  // 关 IRQ
pinctrl_select_state(..., suspend);      // IRQ 脚下拉
fts_mode_handler(info, 0);               // resume_bit=0 → sense off
info->sensor_sleep = true;
if (info->gesture_enabled)               // 我们没开 gesture
        fts_enableInterrupt();           // ← 所以 IRQ 一直关着
```

问题在于**屏的亮灭现在由合成器（KWin/Wayland）直接操作 DRM**，根本不再走
fbdev 的 blank 接口 —— 驱动只偶尔收到一次 `FB_BLANK_POWERDOWN`，之后
永远等不到 `FB_BLANK_UNBLANK`，于是永久卡在 suspend：IRQ 关、sensing 关。

修复前后（`fts_fb_state_chg_callback`）：

```
- 按 FB_BLANK_* 派发 suspend_work / resume_work
+ 直接忽略 FB_EVENT_BLANK（只打日志）：
+   fb blank event ignored (compositor drives DPMS, keep sensing on)
```

反正我们不做系统 suspend（真省电该走 PM 回调），sensing 一直开着代价只是
灭屏时多耗一点电。

### 13.3 验证

`tmp/verify-touch.sh`：正常点 10 下 → 脚本自己 `blank=4 → blank=0` 模拟灭屏亮屏
→ 再点 10 下，比对中断增量。

```
正常点 10 下        ->  497 次中断
灭屏亮屏后点 10 下  ->   35 次中断      （旧版这里是 0）
驱动日志：fts_fb_state_chg_callback: fb blank event ignored ...
```

### 13.4 还没解决的：极短按（< ~40 ms）偶尔丢

实测：让用户"极短按 10 次"，evdev 只收到 2 次（44 ms / 56 ms 的那两次），
其余的时间太短，触摸 IC 在低活动状态下的一帧扫描没抓到。这只是"手感"问题，
不是失效：

- 正常按（≥60 ms）100% 有事件；
- 拖动时上报 ~6.5 ms 一个点（≈150 Hz），说明链路本身不慢；
- 芯片在"一段时间没摸"之后会降扫描率，第一个短按容易漏。

要做的话得动 FW 的 scan/idle 参数（厂商配置里 `touch-idletime` 那一组），
主线驱动目前没接。

## 14. 抄来一份厂商驱动：`stfts`（来自 zhaoyuanwang123/armbian）

参考：<https://github.com/zhaoyuanwang123/armbian> 的
`patch/kernel/archive/sm8250-7.2/0043-umi-touch-stfts-panel-qdefconfig.patch`
（2.5 MB，含整棵 `drivers/input/touchscreen/stfts/` + 一个专用面板驱动 +
`q_defconfig`）。同一系列还有 `0042-umi-board-dtsi-gpi-panel-touch-cs35l41.patch`
和 `0044-dts-add-xiaomi-umi-board.patch`。

已经把它搬进本仓库并**编过**，作为可切换的第二套触摸驱动：

```
stfts/                     厂商驱动 5.2.4（fts.c 190KB + fts_lib + fts_fw.h + fts_limits.h）
TOUCH=stfts sh scripts/build.sh      # 换这套驱动编译
python tools/pack-umi.py --dtb out/sm8250-xiaomi-umi-wifi.dtb --name stfts
# -> out/boot-umi-stfts.img
```

### 14.1 移植时遇到的三个问题

1. **补丁里的文件是 CRLF**，内核构建直接报
   `drivers/input/touchscreen/stfts/Kconfig:7: syntax error`。
   `scripts/fix-stfts-crlf.sh` 已经把仓库里的副本规范成 LF（build.sh 拷进树时
   也会再 `sed 's/\r$//'` 一遍）。
2. **`BTN_INFO` 未定义**：厂商 7.x 树的 `input-event-codes.h` 里有这个小
   米私有键值，主线没有。在 `stfts/fts.h` 里补了 fallback（`0x2c6`）。
3. **DT 属性缺**：它要 `fts,pwr-reg-name` / `fts,bus-reg-name` /
   `fts,config-array-size` / `fts,cfg_N`。已在
   `dts/sm8250-xiaomi-umi-touch.dtsi` 里补齐（`fts,cfg_0` 放在**所有属性之后**，
   否则 dtc 报 “Properties must precede subnodes”），tp-vendor 用本机 lockdown
   的 `0x42`/module `1`。fts521 那边多出来的属性无害。

### 14.2 和 fts521 的差别（值得试的地方）

| | fts521（我们的主线移植） | stfts（厂商 5.2.4） |
|---|---|---|
| FW 烧写 | 手动 `echo 1 > fwupdate` | `FW_UPDATE_ON_PROBE`，probe 时自动判断版本 |
| 预存补偿 | 无 | `PRE_SAVED_METHOD` 定义 |
| FOD | 无 | `CONFIG_FTS_FOD_AREA_REPORT=y`（会发 `C0 02` / `A2 03` 那一组） |
| 事件上报 | 纯 MT-B（无 `BTN_TOUCH`） | 带 `BTN_TOUCH` + `BTN_INFO` |
| proc 接口 | 无 | `fts_proc.c`（`/proc/fts/...`，含产线/调试项） |
| FW 来源 | `/lib/firmware/st_fts_j2_2.ftb` | 同（`FW_H_FILE` 被注释掉，用文件） |

`fts_fw.h` 里那份 100476 B 的 `myArray` 是**别的面板**（2559×1439 / 15×30），
但 `FW_H_FILE` 没有定义，所以不会被烧进去 —— 它只在没有 .ftb 文件时才可能
被用到，真要用的话得把 `st_fts_j2_2.ftb` 放进 `/lib/firmware/`。

### 14.3 试机时重点看什么

1. `dmesg | grep -i -e "TOUCHSCREEN_ST_FTS" -e "fts_probe" -e "FW VER"`
   —— probe 是否走到、有没有尝试烧 FW；
2. `grep fts /proc/interrupts` 是否随触摸增长；
3. 空闲 20 秒后**第一下**快按是否跟手（这正是 fts521 没解决的问题）；
4. `/proc/fts/` 下有没有能用的调试节点（帧数据/产线项）。

⚠️ 风险：这套驱动会自己判断要不要烧 FW，而我们芯片里是**出厂 0x0132**
（比任何 .ftb 文件都新），理论上不会烧；但如果不幸触发，`fts_fw_download`
失败可能把芯片留在 bootloader —— 真出问题就 `echo 256 > fwupdate`（blind
flash）救，命令见 §11。

## 15. "按一会才跟手"：FW idle 时间 + 发送时机（已修）

前情：屏幕静止一阵之后，第一下/极短的点击接不住，要"按一会"才跟手。原因是芯片
空闲时会降扫描率，而主线的 fts521 从来没给芯片设过"进入 idle 的时间"。

厂商驱动用的是原始 FW 命令（`fts_update_enter_idle_time()`）：

```
C0 00 00 xx     进入 idle 的时间 = xx * 50 ms
C0 0A 00/01     关 / 开"动态扫描频率切换"
```

我们要的是 **0xFF = 12.75 s**（厂商 DT 的 `fts,touch-idletime-def` 就是 12450 ms，
除以 50）。

### 15.1 关键是发送时机（踩了两次）

| 做法 | 结果 |
|---|---|
| 不发 | 静置 20 s 后极短按 10 下 → **0** 次中断（这就是"按一会才跟手"） |
| **在 `fts_init_sensing` 里、sense-on 之后紧接着发**（还带 `C0 0A 01`） | **触摸直接不响应**，IRQ 冻结，只有 `system_reset` 能救 |
| 只发 `C0 00 00 FF`，仍在 init 里紧接着发 | 同样把触摸打死 |
| **延迟 3 秒**（`delayed_work`）再发 | **27** 次中断，触摸正常且空闲后第一下就能接住 |

所以 `fts521/fts.c` 里的最终写法是：

```c
static void fts_idle_time_work(struct work_struct *work)
{
	struct fts_ts_info *info = container_of(work, struct fts_ts_info,
						idle_work.work);
	u8 idle_time[4] = { 0xC0, 0x00, 0x00, 0xFF };
	int ret = fts_write(idle_time, sizeof(idle_time));

	logError(1, "%s %s: idle-time set to 12.75s (%d)\n", tag, __func__, ret);
}
...
	/* fts_init_sensing(): 先让芯片正常扫起来，3 秒后再改 idle 参数 */
	schedule_delayed_work(&info->idle_work, msecs_to_jiffies(3000));
```

`C0 0A xx`（动态扫描频率切换）**没有加**：它风险最大，配合起来会让芯片停止上报。

### 15.2 验证

`tmp/test-idle3.sh`：静置 20 s → 背光灭一下当信号 → 10 s 内极短按 10 下 → 看
`/proc/interrupts` 的 `fts` 增量。

```
不发命令            ->  0
延迟 3 秒发 0xFF     -> 27
```
