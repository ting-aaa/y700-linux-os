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
[[ $(fdtget -tu "$stock" "$stock_sensor" cell-index) == 0 ]]
[[ $(fdtget -tu "$stock" "$stock_sensor" csiphy-sd-index) == 0 ]]
[[ $(fdtget -tu "$stock" "$stock_sensor" actuator-src) == "$(fdtget -tu "$stock" "$stock_lens" phandle)" ]]
[[ $(fdtget -tu "$stock" "$stock_sensor" eeprom-src) == "$(fdtget -tu "$stock" "$stock_eeprom" phandle)" ]]
[[ $(fdtget -tu "$stock" "$stock_lens" cci-master) == 0 ]]
[[ $(fdtget -tu "$stock" "$stock_eeprom" cci-master) == 0 ]]
for property in cam_vio-supply cam_v_custom2-supply cam_vana-supply cam_clk-supply gpios gpio-reset clocks clock-rates; do
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
[[ $(fdtget -tx "$native" "$native_cci" reg) == '0 ac15000 0 1000' ]]
[[ $(fdtget -tu "$native" "$native_bus" reg) == 0 ]]
[[ $(fdtget -tu "$native" "$native_bus" clock-frequency) == 400000 ]]
[[ $(fdtget -ts "$native" "$native_sensor" compatible) == hynix,hi1339 ]]
[[ $(fdtget -ts "$native" "$native_regulators" compatible) == qcom,pm8350c-rpmh-regulators ]]
[[ $(fdtget -ts "$native" "$native_regulators" qcom,pmic-id) == c ]]
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
