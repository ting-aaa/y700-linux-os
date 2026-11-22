#!/usr/bin/env bash
# Comprehensive, objective, zero-cheat 9-subsystem physical hardware verification suite
# for Lenovo Legion Y700 Gen 2 (TB320FC_PRC) running the unified hw-bringup-02 kernel.
# Output is sanitized (no MACs, BD_ADDRs, SSIDs, serials, or raw images retained).
set -euo pipefail
export LC_ALL=C

echo "=================================================================="
echo "Y700 TB320FC_PRC FULL 9-SUBSYSTEM PHYSICAL HARDWARE VERIFICATION"
echo "=================================================================="
echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "UNAME=$(uname -a)"
echo "BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)"
echo "CMDLINE_TRIAL=$(grep -o 'y700.hw_trial=[0-9]*' /proc/cmdline || echo none)"
echo "STORAGE_RO sda=$(cat /sys/block/sda/ro 2>/dev/null || echo ?) sda17=$(cat /sys/block/sda/sda17/ro 2>/dev/null || echo ?)"

echo ""
echo "=== [0] KERNEL PROBE SUMMARY (DMESG) ==="
dmesg | grep -E 'Detected WCD938|aw86927|170 Hz LRA|gt9768|qcom-flash|pm8xxx-rtc|adreno|gmu|nvts|nt36523|ath11k|hci0|cs35l45' | tail -n 60 || true

echo ""
echo "=== [1] DISPLAY (60/120Hz) + BACKLIGHT (KTZ8866) + GPU (ADRENO 730) ==="
echo "DRM_STATUS=$(cat /sys/class/drm/card1-DSI-1/status 2>/dev/null || echo missing)"
echo "DRM_MODES=$(tr '\n' ' ' < /sys/class/drm/card1-DSI-1/modes 2>/dev/null || echo missing)"
BL_DIR=$(ls -d /sys/class/backlight/* 2>/dev/null | head -n1 || true)
if [[ -n "$BL_DIR" ]]; then
    BL_ORIG=$(cat "$BL_DIR/brightness")
    BL_MAX=$(cat "$BL_DIR/max_brightness")
    BL_TEST=$(( BL_ORIG + 20 ))
    if (( BL_TEST > BL_MAX )); then BL_TEST=$(( BL_ORIG - 20 )); fi
    echo "$BL_TEST" > "$BL_DIR/brightness"
    sleep 0.1
    BL_READ=$(cat "$BL_DIR/brightness")
    echo "$BL_ORIG" > "$BL_DIR/brightness"
    sleep 0.1
    BL_RESTORED=$(cat "$BL_DIR/brightness")
    echo "BACKLIGHT dev=$(basename "$BL_DIR") orig=$BL_ORIG step=$BL_READ restored=$BL_RESTORED max=$BL_MAX"
fi
GPU_DF=$(ls -d /sys/class/devfreq/*gpu* 2>/dev/null | head -n1 || true)
if [[ -n "$GPU_DF" ]]; then
    echo "GPU_DEVFREQ cur=$(cat "$GPU_DF/cur_freq") min=$(cat "$GPU_DF/min_freq") max=$(cat "$GPU_DF/max_freq")"
fi
echo "GPU_HFI_ERRORS=$(dmesg | grep -ciE 'gpu hang|HFI.*timeout|GMU.*fault' || true)"

# Live 120 Hz -> 60 Hz -> 120 Hz switch + Freedreno/Turnip check on active Xorg (:0)
XORG_PID=$(pidof Xorg 2>/dev/null | awk '{print $1}' || true)
if [[ -n "$XORG_PID" ]]; then
    XAUTH=$(tr '\0' '\n' < "/proc/$XORG_PID/cmdline" | awk '$0=="-auth"{getline; print; exit}')
    if [[ -n "$XAUTH" && -r "$XAUTH" ]]; then
        echo "XORG_ACTIVE=yes auth_present=1"
        DISPLAY=:0 XAUTHORITY="$XAUTH" xrandr --output DSI-1 --mode 1600x2560 --rate 60 && sleep 0.4
        echo "XRANDR_AT_60=$(DISPLAY=:0 XAUTHORITY="$XAUTH" xrandr --query | grep -F '*' | tr -s ' ')"
        DISPLAY=:0 XAUTHORITY="$XAUTH" xrandr --output DSI-1 --mode 1600x2560 --rate 120 && sleep 0.4
        echo "XRANDR_AT_120=$(DISPLAY=:0 XAUTHORITY="$XAUTH" xrandr --query | grep -F '*' | tr -s ' ')"
        if command -v glxinfo >/dev/null 2>&1; then
            DISPLAY=:0 XAUTHORITY="$XAUTH" glxinfo -B 2>/dev/null | grep -E 'OpenGL vendor|OpenGL renderer|OpenGL version|Accelerated' || true
        fi
        if command -v vulkaninfo >/dev/null 2>&1; then
            DISPLAY=:0 XAUTHORITY="$XAUTH" vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName|driverInfo|apiVersion' | head -n 8 || true
        fi
    fi
fi

echo ""
echo "=== [2] TOUCHSCREEN (NT36523N) ==="
python3 - <<'PY'
from pathlib import Path
for ev in sorted(Path("/sys/class/input").glob("event*")):
    name = (ev / "device/name").read_text().strip() if (ev / "device/name").exists() else ""
    if any(k in name.lower() for k in ("novatek", "nvt", "touch", "nt36523", "ts")):
        abs_cap = (ev / "device/capabilities/abs").read_text().strip() if (ev / "device/capabilities/abs").exists() else ""
        print(f"TOUCH_DEV=/dev/input/{ev.name} name={name!r} abs={abs_cap}")
PY

echo ""
echo "=== [3] WI-FI (WCN6855 ath11k) ==="
nmcli -t -f DEVICE,TYPE,STATE dev status 2>/dev/null | grep wifi || true
iw dev wlp1s0 link 2>/dev/null | awk '
    /Connected to/ { print "WIFI_CONNECTED=yes" }
    /freq:|signal:|tx bitrate:|rx bitrate:/ { gsub(/^[ \t]+/, ""); print "WIFI_" $0 }
' || true
GW=$(ip -4 route show dev wlp1s0 2>/dev/null | awk '/default/ {print $3; exit}')
if [[ -n "$GW" ]]; then
    echo "WIFI_IPV4_GW_PRESENT=yes"
    ping -I wlp1s0 -c 6 -W 2 "$GW" 2>&1 | tail -n 2 | sed -E 's/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/<GW>/g' || true
fi

echo ""
echo "=== [4] BLUETOOTH (WCN6855 hci0) ==="
hciconfig hci0 2>/dev/null | grep -E 'UP RUNNING|RX bytes|TX bytes' || true
bluetoothctl show 2>/dev/null | grep -E 'Powered:|Discoverable:|Pairable:|Discovering:' || true
BT_FOUND=$(bluetoothctl --timeout 6 scan on 2>/dev/null | grep -cE 'Device [0-9A-F:]{17}' || true)
echo "BT_LIVE_SCAN_6S_DEVICES_SEEN=$BT_FOUND"

echo ""
echo "=== [5 & 6] SPEAKERS (CS35L45) + INTERNAL MICROPHONES (WCD9385 VIA PRODUCTION UCM2!) ==="
python3 - <<'PY'
from pathlib import Path
for d in sorted(Path("/sys/bus/soundwire/devices").glob("sdw:*")):
    st = (d / "status").read_text().strip() if (d / "status").exists() else "?"
    print(f"SDW_BEFORE {d.name}={st}")
for r in sorted(Path("/sys/class/regulator").glob("regulator.*")):
    nf, uf = r / "name", r / "microvolts"
    if nf.exists() and nf.read_text().strip() == "vreg_bob" and uf.exists():
        print(f"VREG_BOB_UV={uf.read_text().strip()}")
PY
echo "ALSA_CAPTURE_PCMS:"
arecord -l 2>/dev/null | grep -E 'card|Subdevice' || true
echo "ALSA_PLAYBACK_PCMS:"
aplay -l 2>/dev/null | grep -E 'card|Subdevice' || true
echo "ALSAUCM_DEVICES:"
alsaucm -c hw:0 set _verb HiFi list _devices 2>&1

# Enable BOTH Speaker and Mic using the exact production ALSA UCM2 profile (ZERO debugfs writes!)
alsaucm -c hw:0 set _verb HiFi set _enadev Speaker set _enadev Mic
echo "ALSAUCM_APPLIED=Speaker+Mic"

python3 - <<'PY'
import glob, math, os, struct, subprocess, time, wave
from pathlib import Path

def sdw_status():
    return {d.name: (d / "status").read_text().strip()
            for d in sorted(Path("/sys/bus/soundwire/devices").glob("sdw:*"))
            if (d / "status").exists()}

def read_wcd_regs():
    out = {}
    for p in sorted(glob.glob("/sys/kernel/debug/regmap/*wcd*/registers")):
        txt = open(p).read()
        for line in txt.splitlines():
            for reg in ("3001", "3103", "312a", "3405", "34b0"):
                if line.lower().startswith(reg + ":"):
                    out[reg] = line.strip()
    return out

def gen_wav(path, dur, fl, fr, amp=16000, sr=48000):
    n = int(dur * sr)
    frames = bytearray()
    for i in range(n):
        t = i / sr
        sl = int(amp * math.sin(2 * math.pi * fl * t)) if fl > 0 else 0
        sr_s = int(amp * math.sin(2 * math.pi * fr * t)) if fr > 0 else 0
        frames += struct.pack("<hh", sl, sr_s)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(frames)

def goertzel(samples, target_hz, sr=48000):
    n = len(samples)
    if n == 0: return 0.0
    k = int(0.5 + (n * target_hz) / sr)
    w = (2.0 * math.pi / n) * k
    coeff = 2.0 * math.cos(w)
    s0 = s1 = s2 = 0.0
    for x in samples:
        s0 = x + coeff * s1 - s2
        s2, s1 = s1, s0
    mag = math.sqrt(max(0.0, s1*s1 + s2*s2 - s1*s2*coeff))
    return (2.0 * mag) / n

def analyze(wav_path, label):
    with wave.open(wav_path, "rb") as w:
        sr = w.getframerate()
        raw = w.readframes(w.getnframes())
    vals = struct.unpack(f"<{len(raw)//2}h", raw)
    skip = int(0.6 * sr)
    c0 = vals[2*skip::2]
    c1 = vals[2*skip+1::2]
    def stats(c):
        if not c: return (0, 0, 0)
        mean = sum(c) / len(c)
        ac = [x - mean for x in c]
        rms = math.sqrt(sum(x*x for x in ac) / len(ac))
        return (rms, goertzel(ac, 1000.0, sr), goertzel(ac, 1500.0, sr))
    s0, s1 = stats(c0), stats(c1)
    print(f"AUDIO_{label}: ch0(rms={s0[0]:.1f} 1k={s0[1]:.1f} 1.5k={s0[2]:.1f}) ch1(rms={s1[0]:.1f} 1k={s1[1]:.1f} 1.5k={s1[2]:.1f})")
    return s0, s1

gen_wav("/tmp/tone_left_1k.wav", 2.0, 1000.0, 0.0)
gen_wav("/tmp/tone_right_15k.wav", 2.0, 0.0, 1500.0)
gen_wav("/tmp/tone_both_1k.wav", 2.0, 1000.0, 1000.0)

# 1) Quiet baseline + mid-stream SoundWire & WCD9385 register check
rec = subprocess.Popen(["arecord", "-q", "-D", "hw:0,2", "-f", "S16_LE", "-r", "48000", "-c", "2", "-d", "2", "/tmp/rec_quiet.wav"])
time.sleep(0.8)
print("SDW_DURING_CAPTURE:", sdw_status())
print("WCD_REGS_DURING:", read_wcd_regs())
assert rec.wait() == 0
q0, q1 = analyze("/tmp/rec_quiet.wav", "QUIET_BASELINE")

# 2) Left speaker ONLY 1000 Hz + dual mic full-duplex
p = subprocess.Popen(["aplay", "-q", "-D", "hw:0,0", "/tmp/tone_left_1k.wav"])
subprocess.run(["arecord", "-q", "-D", "hw:0,2", "-f", "S16_LE", "-r", "48000", "-c", "2", "-d", "2", "/tmp/rec_left.wav"], check=True)
p.wait()
l0, l1 = analyze("/tmp/rec_left.wav", "SPK_LEFT_1000HZ")

# 3) Right speaker ONLY 1500 Hz + dual mic full-duplex
p = subprocess.Popen(["aplay", "-q", "-D", "hw:0,0", "/tmp/tone_right_15k.wav"])
subprocess.run(["arecord", "-q", "-D", "hw:0,2", "-f", "S16_LE", "-r", "48000", "-c", "2", "-d", "2", "/tmp/rec_right.wav"], check=True)
p.wait()
r0, r1 = analyze("/tmp/rec_right.wav", "SPK_RIGHT_1500HZ")

# 4) 5-second idle persistence check (prove WCD9385 stays alive across stream close/reopen!)
time.sleep(5.0)
print("SDW_AFTER_5S_IDLE:", sdw_status())
p = subprocess.Popen(["aplay", "-q", "-D", "hw:0,0", "/tmp/tone_both_1k.wav"])
subprocess.run(["arecord", "-q", "-D", "hw:0,2", "-f", "S16_LE", "-r", "48000", "-c", "2", "-d", "2", "/tmp/rec_repeat.wav"], check=True)
p.wait()
rep0, rep1 = analyze("/tmp/rec_repeat.wav", "REPEAT_AFTER_5S_IDLE_1000HZ")

snr_l_c0 = 20 * math.log10(max(l0[1], 1e-3) / max(q0[1], 0.1))
snr_l_c1 = 20 * math.log10(max(l1[1], 1e-3) / max(q1[1], 0.1))
snr_r_c0 = 20 * math.log10(max(r0[2], 1e-3) / max(q0[2], 0.1))
snr_r_c1 = 20 * math.log10(max(r1[2], 1e-3) / max(q1[2], 0.1))
snr_rep_c0 = 20 * math.log10(max(rep0[1], 1e-3) / max(q0[1], 0.1))
snr_rep_c1 = 20 * math.log10(max(rep1[1], 1e-3) / max(q1[1], 0.1))
print(f"SNR_DB left_1k=({snr_l_c0:+.1f},{snr_l_c1:+.1f}) right_1.5k=({snr_r_c0:+.1f},{snr_r_c1:+.1f}) repeat_after_idle=({snr_rep_c0:+.1f},{snr_rep_c1:+.1f})")

for f in ("/tmp/tone_left_1k.wav", "/tmp/tone_right_15k.wav", "/tmp/tone_both_1k.wav",
          "/tmp/rec_quiet.wav", "/tmp/rec_left.wav", "/tmp/rec_right.wav", "/tmp/rec_repeat.wav"):
    if os.path.exists(f):
        os.unlink(f)
PY

echo ""
echo "=== [7] DUAL VIBRATION MOTORS (AW86927 LEFT + RIGHT @ 170 Hz) ==="
python3 - <<'PY'
import fcntl, math, os, re, struct, subprocess, time, wave
from pathlib import Path

EVIOCSFF = 0x40304580
EVIOCRMFF = 0x40044581
EV_FF = 0x15
FF_RUMBLE = 0x50

devs = {}
for ev in sorted(Path("/sys/class/input").glob("event*")):
    nf = ev / "device/name"
    if nf.exists():
        n = nf.read_text().strip()
        if "haptic" in n.lower() or "aw86927" in n.lower():
            devs[n] = f"/dev/input/{ev.name}"
print("HAPTIC_DEVS:", devs)

def goertzel(samples, target_hz, sr=48000):
    n = len(samples)
    if n == 0: return 0.0
    k = int(0.5 + (n * target_hz) / sr)
    w = (2.0 * math.pi / n) * k
    coeff = 2.0 * math.cos(w)
    s0 = s1 = s2 = 0.0
    for x in samples:
        s0 = x + coeff * s1 - s2
        s2, s1 = s1, s0
    return (2.0 * math.sqrt(max(0.0, s1*s1 + s2*s2 - s1*s2*coeff))) / n

def parse_accel(txt):
    xs, ys, zs = [], [], []
    for line in txt.splitlines():
        m = re.search(r"X:\s*([-\d.]+).*Y:\s*([-\d.]+).*Z:\s*([-\d.]+)", line)
        if m:
            xs.append(float(m.group(1)))
            ys.append(float(m.group(2)))
            zs.append(float(m.group(3)))
    def ptp(a): return (max(a) - min(a)) if len(a) >= 2 else 0.0
    return len(xs), ptp(xs), ptp(ys), ptp(zs)

def measure_haptic(label, dev_path):
    wav = f"/tmp/hap_{label}.wav"
    rec = subprocess.Popen(["arecord", "-q", "-D", "hw:0,2", "-f", "S16_LE", "-r", "48000", "-c", "2", "-d", "2", wav])
    acc = subprocess.Popen(["timeout", "-s", "INT", "2", "stdbuf", "-oL", "ssccli", "--sensor", "accelerometer"],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(0.7)
    if dev_path:
        fd = os.open(dev_path, os.O_RDWR)
        try:
            buf = bytearray(48)
            struct.pack_into("<HhHHHHH2xHH", buf, 0, FF_RUMBLE, -1, 0, 0, 0, 800, 0, 0xFFFF, 0xFFFF)
            fcntl.ioctl(fd, EVIOCSFF, buf)
            eff_id = struct.unpack_from("<h", buf, 2)[0]
            os.write(fd, struct.pack("<qqHHi", 0, 0, EV_FF, eff_id, 1))
            time.sleep(0.9)
            os.write(fd, struct.pack("<qqHHi", 0, 0, EV_FF, eff_id, 0))
            fcntl.ioctl(fd, EVIOCRMFF, eff_id)
        finally:
            os.close(fd)
    rec.wait()
    acc_out, _ = acc.communicate()
    n_acc, px, py, pz = parse_accel(acc_out)
    with wave.open(wav, "rb") as w:
        sr = w.getframerate()
        raw = w.readframes(w.getnframes())
    os.unlink(wav)
    vals = struct.unpack(f"<{len(raw)//2}h", raw)
    i0, i1 = int(0.8 * sr), int(1.4 * sr)
    c0 = vals[2*i0:2*i1:2]
    c1 = vals[2*i0+1:2*i1:2]
    m0, m1 = sum(c0)/len(c0), sum(c1)/len(c1)
    ac0 = [x - m0 for x in c0]
    ac1 = [x - m1 for x in c1]
    g0_170 = goertzel(ac0, 170.2, sr)
    g1_170 = goertzel(ac1, 170.2, sr)
    g0_340 = goertzel(ac0, 340.4, sr)
    g1_340 = goertzel(ac1, 340.4, sr)
    print(f"HAPTIC_{label}: mic_170hz=({g0_170:.1f},{g1_170:.1f}) mic_340hz=({g0_340:.1f},{g1_340:.1f}) accel_n={n_acc} ptp=({px:.3f},{py:.3f},{pz:.3f})")

measure_haptic("BASELINE", None)
for name, path in sorted(devs.items()):
    tag = "LEFT" if "left" in name else ("RIGHT" if "right" in name else name)
    measure_haptic(tag, path)
PY
echo "AW86927_FAULTS=$(dmesg | grep -i aw86927 | grep -ciE 'fault|error|fail|over|short|under' || true)"

echo ""
echo "=== [8] CAMERAS (3 SENSORS + GT9768 AF) + REAR FLASH LED ==="
echo "MEDIA_SUBDEVS:"
for sd in /sys/class/video4linux/v4l-subdev*; do
    name=$(cat "$sd/name" 2>/dev/null || true)
    if echo "$name" | grep -qiE 'hi1339|s5k4h7|sc202cs|gt9768'; then
        echo "  $(basename "$sd"): $name"
    fi
done

AF_DEV=""
for sd in /sys/class/video4linux/v4l-subdev*; do
    if grep -qi gt9768 "$sd/name" 2>/dev/null; then
        AF_DEV="/dev/$(basename "$sd")"
    fi
done
if [[ -n "$AF_DEV" ]]; then
    echo "GT9768_AF_DEV=$AF_DEV"
    v4l2-ctl -d "$AF_DEV" --list-ctrls 2>&1 || true
    for pos in 360 420 480 540 605 480; do
        v4l2-ctl -d "$AF_DEV" --set-ctrl=focus_absolute="$pos" >/dev/null 2>&1 || echo "AF_SET_ERR=$pos"
        readback=$(v4l2-ctl -d "$AF_DEV" --get-ctrl=focus_absolute 2>&1 | awk '{print $2}')
        echo "  AF_POS set=$pos readback=$readback"
    done
fi

CAM_BIN=/opt/y700-camera/bin/cam
if [[ -x "$CAM_BIN" ]]; then
    echo "LIBCAMERA_LIST:"
    LD_LIBRARY_PATH=/opt/y700-camera/lib LIBCAMERA_SOFTISP_MODE=cpu "$CAM_BIN" -l 2>&1 | grep -E 'Available cameras|^[0-9]+:' || true
    rm -rf /tmp/y700_cam_verify && mkdir -p /tmp/y700_cam_verify
    for idx in 1 2 3; do
        echo "--- Capturing 5 frames from camera $idx ---"
        timeout 20 env LD_LIBRARY_PATH=/opt/y700-camera/lib LIBCAMERA_SOFTISP_MODE=cpu \
            "$CAM_BIN" --camera="$idx" --capture=5 --file="/tmp/y700_cam_verify/cam${idx}_#.bin" 2>&1 | grep -E 'Using camera|Stream configuration|fps|bytesused' | tail -n 8 || echo "CAM_${idx}_FAILED"
        python3 - "$idx" <<'PY'
import glob, sys
idx = sys.argv[1]
files = sorted(glob.glob(f"/tmp/y700_cam_verify/cam{idx}_*.bin"))
if not files:
    print(f"CAM{idx}_STATS: NO_FILES")
else:
    data = open(files[-1], "rb").read()
    step = max(1, len(data) // 65536)
    sample = data[::step]
    mean = sum(sample) / len(sample)
    nz = sum(1 for b in sample if b != 0) / len(sample) * 100.0
    print(f"CAM{idx}_STATS: frames={len(files)} last_bytes={len(data)} sample_mean={mean:.2f} nonzero_pct={nz:.1f}%")
PY
    done

    # Rear Flash LED physical optical proof using camera 2 (hi1339 13MP rear main) + ambient light
    FLASH_LED=/sys/class/leds/white:flash
    if [[ -d "$FLASH_LED" ]]; then
        echo "FLASH_LED_INFO max=$(cat "$FLASH_LED/max_brightness") fault_before=$(cat "$FLASH_LED/fault" 2>/dev/null || echo none)"
        echo 0 > "$FLASH_LED/brightness"
        rm -f /tmp/y700_cam_verify/flash_*.bin
        timeout 15 env LD_LIBRARY_PATH=/opt/y700-camera/lib LIBCAMERA_SOFTISP_MODE=cpu \
            "$CAM_BIN" --camera=2 --capture=4 --file="/tmp/y700_cam_verify/flash_off_#.bin" >/dev/null 2>&1 || true
        echo 64 > "$FLASH_LED/brightness"
        sleep 0.2
        FLASH_READ=$(cat "$FLASH_LED/brightness")
        timeout 15 env LD_LIBRARY_PATH=/opt/y700-camera/lib LIBCAMERA_SOFTISP_MODE=cpu \
            "$CAM_BIN" --camera=2 --capture=4 --file="/tmp/y700_cam_verify/flash_on_#.bin" >/dev/null 2>&1 || true
        echo 0 > "$FLASH_LED/brightness"
        FLASH_FAULT=$(cat "$FLASH_LED/fault" 2>/dev/null || echo none)
        python3 - "$FLASH_READ" "$FLASH_FAULT" <<'PY'
import glob, sys
def mean_of(pattern):
    fs = sorted(glob.glob(pattern))
    if not fs: return -1.0, 0
    d = open(fs[-1], "rb").read()
    step = max(1, len(d) // 65536)
    s = d[::step]
    return sum(s) / len(s), len(d)
moff, boff = mean_of("/tmp/y700_cam_verify/flash_off_*.bin")
mon, bon = mean_of("/tmp/y700_cam_verify/flash_on_*.bin")
print(f"FLASH_OPTICAL_PROOF torch_set={sys.argv[1]} fault={sys.argv[2]!r} hi1339_off_mean={moff:.2f}({boff}B) hi1339_on_mean={mon:.2f}({bon}B) delta={mon-moff:+.2f}")
PY
    fi
    rm -rf /tmp/y700_cam_verify
fi

echo ""
echo "=== [9] ALL SENSORS (SLPI SSC + IIO-SENSOR-PROXY) ==="
echo "SSC_SERVICES: y700-ssc=$(systemctl is-active y700-ssc 2>/dev/null || echo ?) iio-sensor-proxy=$(systemctl is-active iio-sensor-proxy 2>/dev/null || echo ?)"
for s in accelerometer light proximity magnetometer compass; do
    val=$(timeout -s INT 2 stdbuf -oL ssccli --sensor "$s" 2>&1 | grep -m1 -E 'X:|Lux:|Proximity:|Heading:|Magnetic|FAR|NEAR|measurement' || echo "NO_SAMPLE")
    echo "SSC_${s}=$val"
done
echo "MONITOR_SENSOR_2S:"
timeout 2 monitor-sensor 2>&1 | head -n 15 || true

echo ""
echo "=== [BONUS] BATTERY / UCSI / RTC / THERMAL ==="
for ps in /sys/class/power_supply/*; do
    echo "PSU $(basename "$ps"): type=$(cat "$ps/type" 2>/dev/null) status=$(cat "$ps/status" 2>/dev/null || echo -) cap=$(cat "$ps/capacity" 2>/dev/null || echo -) online=$(cat "$ps/online" 2>/dev/null || echo -)"
done
for r in /sys/class/rtc/rtc*; do
    echo "RTC $(basename "$r"): name=$(cat "$r/name" 2>/dev/null) date=$(cat "$r/date" 2>/dev/null) time=$(cat "$r/time" 2>/dev/null)"
done
echo "THERMAL_MAX_MC=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -n1 || echo ?)"
echo "=================================================================="
echo "VERIFY_ALL_9_SUBSYSTEMS_COMPLETE"
echo "=================================================================="
