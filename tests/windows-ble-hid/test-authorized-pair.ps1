param([string]$TabletSshWsl, [string]$Distro = 'Ubuntu', [switch]$RunOnce)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'load-profile.ps1')
if (-not $RunOnce) { 'HOST_GUARDED_FIXTURE_COMPILED'; return }
if ($TabletSshWsl -notmatch '^/[A-Za-z0-9_./-]+$') { throw 'A fixed-host SSH wrapper is required' }
$address = (wsl -d $Distro -u root --exec bash $TabletSshWsl 'cat /etc/y700/bluetooth-address').Trim().Replace(':','')
if ($LASTEXITCODE -ne 0 -or $address -notmatch '^[A-Fa-f0-9]{12}$') { throw 'Cannot verify the live tablet identity' }
$dir = (wsl -d $Distro -u root --exec wslpath -u $PSScriptRoot).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the fixture path' }
$snapshot = [HidPeripheral]::BondInventory()
if (-not $snapshot.Wait(5000)) { throw 'Host bond snapshot timed out' }
$initial = [string[]]$snapshot.Result
$bond = [HidPeripheral]::IsTabletPaired($address)
if (-not $bond.Wait(5000) -or $bond.Result) { throw 'Existing or unknown Windows bond for this tablet' }
$adapter = [HidPeripheral]::AdapterAddress()
if (-not $adapter.Wait(5000)) { throw 'Windows adapter lookup timed out' }
$fixture = New-Object HidPeripheral
if (-not $fixture.Prepare().Wait(10000)) { throw 'HID profile preparation timed out' }
$token = [byte[]]([Guid]::NewGuid().ToByteArray()[0..7])
$runtime = '/run/y700-pair-' + [Guid]::NewGuid().ToString('N')
$sampleSent = $false
$pairVerified = $false
$inputReady = $false
$requestIssued = $false
try {
    $fixture.Advertise($token)
    $deadline = [DateTime]::UtcNow.AddSeconds(6)
    while ($fixture.Status() -ne 'Started' -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if ($fixture.Status() -ne 'Started') { throw ('HID advertisement failed: ' + $fixture.AdvertisementError()) }
    'HOST_TEMPORARY_HID_STARTED'
    wsl -d $Distro -u root --exec bash "$dir/run-guarded-tablet.sh" $TabletSshWsl $runtime ($token -join '-') $adapter.Result | ForEach-Object {
        $line = $_.Trim()
        $line
        if ($line -eq 'TABLET_SINGLE_PAIR_REQUEST') { $requestIssued = $true }
        if ($line -eq 'TABLET_PAIR_VERIFIED') { $pairVerified = $true }
        if ($line -eq 'TABLET_INPUT_READY' -or $line -eq 'TABLET_PAIR_VERIFIED') {
            if ($line -eq 'TABLET_INPUT_READY') { $inputReady = $true }
            if ($inputReady -and $pairVerified -and -not $sampleSent) {
                $sampleSent = $true
                try {
                    if (-not $fixture.SendFixedSample($address).Wait(4000)) { throw 'HID notification timed out' }
                    'HOST_FIXED_SAMPLE_SENT_TO_BONDED_TABLET'
                } catch {
                    'HOST_FIXED_SAMPLE_UNCONFIRMED'
                }
            }
        }
    }
    $tabletResult = $LASTEXITCODE
} finally {
    $fixture.Stop()
    if (-not [HidPeripheral]::RestoreTemporaryBond($address,$initial,$requestIssued).Wait(12000)) { throw 'Host bond cleanup timed out' }
    'HOST_BOND_INVENTORY_RESTORED'
}
if ($tabletResult -ne 0) { throw "Tablet guard exited with status $tabletResult" }
