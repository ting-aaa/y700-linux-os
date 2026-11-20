# Compile and export the fixture's report map for the Linux guest without opening a radio.
param([Parameter(Mandatory=$true)][string]$Directory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'load-profile.ps1')
$target = (New-Item -ItemType Directory -Path $Directory -ErrorAction Stop).FullName
$fields = @{ 'report-map.bin' = 'reportMap'; 'motion.bin' = 'mouseStep' }
foreach ($name in $fields.Keys) {
    $field = [HidPeripheral].GetField($fields[$name], [Reflection.BindingFlags]'NonPublic,Static')
    [IO.File]::WriteAllBytes((Join-Path $target $name), $field.GetValue($null))
}
