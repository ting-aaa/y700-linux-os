#!/usr/bin/env bash
# Cross-check the stock actuator and EEPROM routes against the pinned Linux board DTB.
set -euo pipefail
stock=${1:?merged CN350 PRC vendor DTB}
native=${2:?pinned Asphalt PRC Linux DTB}

printf '%s  %s\n' \
    7359763f57ceea931c6881581fa13c35198f0cb905116e00fdd20ec00cd181d5 "$stock" \
    1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d "$native" | sha256sum --strict -c

stock_cci=/soc/qcom,cci0@ac15000
stock_sensor=$stock_cci/qcom,cam-sensor0
stock_lens=$(fdtget -ts "$stock" /__symbols__ asphalt_actuator)
stock_eeprom=$(fdtget -ts "$stock" /__symbols__ eeprom_hi1339)
stock_bob=$(fdtget -ts "$stock" /__symbols__ pm8350c_bob)
[[ $stock_lens == "$stock_cci/qcom,actuator" ]]
[[ $stock_eeprom == "$stock_cci/qcom,eeprom0" ]]
[[ $(fdtget -tx "$stock" "$stock_cci" reg) == 'ac15000 1000' ]]
[[ $(fdtget -tu "$stock" "$stock_cci" cell-index) == 0 ]]
[[ $(fdtget -tu "$stock" "$stock_sensor" cell-index) == 0 ]]
[[ $(fdtget -tu "$stock" "$stock_sensor" cci-master) == 0 ]]
[[ $(fdtget -tu "$stock" "$stock_sensor" csiphy-sd-index) == 0 ]]
[[ $(fdtget -tu "$stock" "$stock_sensor" actuator-src) == "$(fdtget -tu "$stock" "$stock_lens" phandle)" ]]
[[ $(fdtget -tu "$stock" "$stock_sensor" eeprom-src) == "$(fdtget -tu "$stock" "$stock_eeprom" phandle)" ]]
[[ $(fdtget -tu "$stock" "$stock_lens" cci-master) == 0 ]]
[[ $(fdtget -tu "$stock" "$stock_eeprom" cci-master) == 0 ]]
for property in cam_vio-supply cam_v_custom2-supply cam_vana-supply cam_clk-supply gpios gpio-reset clocks clock-rates pinctrl-0 pinctrl-1; do
    [[ $(fdtget -tx "$stock" "$stock_sensor" "$property") == "$(fdtget -tx "$stock" "$stock_eeprom" "$property")" ]]
done
[[ $(fdtget -ts "$stock" "$stock_lens" regulator-names) == cam_vaf ]]
[[ $(fdtget -tu "$stock" "$stock_lens" cam_vaf-supply) == "$(fdtget -tu "$stock" "$stock_bob" phandle)" ]]
[[ $(fdtget -tu "$stock" "$stock_lens" rgltr-load-current) == 70000 ]]
[[ $(fdtget -ts "$stock" "$stock_bob" regulator-name) == pm8350c_bob ]]
[[ $(fdtget -ts "$stock" "${stock_bob%/*}" qcom,resource-name) == bobc1 ]]

native_cci=/soc@0/cci@ac15000
native_bus=$native_cci/i2c-bus@0
native_sensor=$native_bus/camera@20
native_regulators=/soc@0/rsc@17a00000/regulators-1
native_bob=$native_regulators/bob
native_pmic=/soc@0/cci@ac16000/i2c-bus@0/regulator@29
stock_pmic=/soc/qcom,cci1@ac16000/qcom,ic_power@0
[[ $(fdtget -tx "$native" "$native_cci" reg) == '0 ac15000 0 1000' ]]
[[ $(fdtget -tu "$native" "$native_bus" reg) == 0 ]]
[[ $(fdtget -tu "$native" "$native_bus" clock-frequency) == 400000 ]]
[[ $(fdtget -ts "$native" "$native_sensor" compatible) == hynix,hi1339 ]]
[[ $(fdtget -ts "$native" "$native_regulators" compatible) == qcom,pm8350c-rpmh-regulators ]]
[[ $(fdtget -ts "$native" "$native_regulators" qcom,pmic-id) == c ]]
[[ $(fdtget -tu "$stock" "$stock_pmic" cci-device) == 1 ]]
[[ $(fdtget -tu "$stock" "$stock_pmic" cci-master) == 0 ]]
[[ $(fdtget -ts "$native" "$native_pmic" compatible) == willsemi,wl2864c ]]
[[ $(fdtget -tx "$native" "$native_pmic" reg) == 29 ]]
[[ $(fdtget -tu "$stock" "$stock_cci/qcom,i2c_fast_mode" cci-clk-src) == 37500000 ]]
[[ $(fdtget -tu "$native" "$native_pmic/regulators/ldo5" regulator-min-microvolt) == 2800000 ]]
[[ $(fdtget -tu "$native" "$native_pmic/regulators/ldo5" regulator-max-microvolt) == 2800000 ]]
[[ $(fdtget -tu "$native" "$native_sensor" avdd-supply) == "$(fdtget -tu "$native" "$native_pmic/regulators/ldo4" phandle)" ]]
[[ $(fdtget -tu "$native" "$native_sensor" dvdd-supply) == "$(fdtget -tu "$native" "$native_pmic/regulators/ldo1" phandle)" ]]

for index in 0 1; do
    names=(active suspend)
    native_names=(default-state sleep-state)
    biases=(bias-pull-up bias-pull-down)
    stock_pin=/soc/pinctrl@f000000/cci0_${names[index]}
    native_pin=/soc@0/pinctrl@f100000/cci0-${native_names[index]}
    read -r native_first_pin _ <<<"$(fdtget -tu "$native" "$native_cci" "pinctrl-$index")"
    [[ $native_first_pin == "$(fdtget -tu "$native" "$native_pin" phandle)" ]]
    [[ $(fdtget -tu "$stock" "$stock_cci" "pinctrl-$index") == "$(fdtget -tu "$stock" "$stock_pin" phandle)" ]]
    [[ $(fdtget -ts "$stock" "$stock_pin/mux" pins) == 'gpio110 gpio111' ]]
    [[ $(fdtget -ts "$native" "$native_pin" pins) == 'gpio110 gpio111' ]]
    [[ $(fdtget -ts "$stock" "$stock_pin/mux" function) == cci_i2c ]]
    [[ $(fdtget -ts "$native" "$native_pin" function) == cci_i2c ]]
    [[ $(fdtget -tu "$stock" "$stock_pin/config" drive-strength) == 2 ]]
    [[ $(fdtget -tu "$native" "$native_pin" drive-strength) == 2 ]]
    fdtget "$stock" "$stock_pin/config" "${biases[index]}" >/dev/null
    fdtget "$native" "$native_pin" "${biases[index]}" >/dev/null
done
for property in min max; do
    voltage=$(fdtget -tu "$stock" "$stock_lens" "rgltr-$property-voltage")
    [[ $voltage == "$(fdtget -tu "$stock" "$stock_bob" "regulator-$property-microvolt")" ]]
    [[ $voltage == "$(fdtget -tu "$native" "$native_bob" "regulator-$property-microvolt")" ]]
done
if fdtget -p "$native" "$native_sensor" | grep -Fxq lens-focus; then
    echo 'Unexpected native lens-focus link in the baseline' >&2
    exit 1
fi
if fdtget -l "$native" "$native_bus" | grep -Fxq eeprom@58; then
    echo 'Unexpected native EEPROM node in the baseline' >&2
    exit 1
fi
echo 'CN350 camera slot 0 links to the CCI0 master 0 actuator and shared PM8350C BOB rail'
echo 'CN350 EEPROM shares the HI1339 VIO, custom L4, BOB VANA, MCLK and reset connections'
echo 'Pinned Linux uses the same CCI master and BOB regulator. HI1339 has no lens-focus link or EEPROM node.'
echo 'CCI0 master 0 pinmux and bias agree. The stock Fast mode requests a 37.5 MHz source.'
echo 'The WL2864C is on CCI1 master 0. Native HI1339 consumes LDO1 and LDO4, and LDO5 is declared at 2.8 V.'
