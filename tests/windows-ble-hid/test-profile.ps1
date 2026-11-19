param([string]$TabletSshWsl, [string]$Distro = 'Ubuntu', [switch]$CheckPairing, [switch]$CheckReconnect, [string]$ChildMarker)
$ErrorActionPreference = 'Stop'
if (($CheckPairing -or $CheckReconnect) -and -not $TabletSshWsl) { throw 'A fixed-host SSH wrapper is required' }
if ($CheckPairing -and $CheckReconnect) { throw 'Choose one additional radio check' }
if ($ChildMarker -and $ChildMarker -notmatch '^(\d{1,3}-){7}\d{1,3}$') { throw 'Invalid marker' }
$fx = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319'
$facades = Join-Path ${env:ProgramFiles(x86)} 'Reference Assemblies/Microsoft/Framework/.NETFramework/v4.8/Facades'
$kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/UnionMetadata'
$metadata = Get-ChildItem -LiteralPath $kits -Directory | Where-Object { $_.Name -match '^10\.' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
$refs = @("$fx/System.dll", "$fx/System.Core.dll", "$facades/System.Runtime.dll",
    "$fx/System.Runtime.WindowsRuntime.dll", "$facades/System.Runtime.InteropServices.WindowsRuntime.dll",
    (Join-Path $metadata.FullName 'Windows.winmd'))
$references = $refs | ForEach-Object { '/reference:' + (Resolve-Path -LiteralPath $_).Path }
$dll = Join-Path ([IO.Path]::GetTempPath()) ("y700-hid-" + [Guid]::NewGuid().ToString('N') + ".dll")
try {
    & "$fx/csc.exe" /nologo /target:library /langversion:5 "/out:$dll" $references (Join-Path $PSScriptRoot 'HidPeripheral.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Fixture compile failed' }
    [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))
} finally {
    if (Test-Path -LiteralPath $dll) { Remove-Item -LiteralPath $dll }
}
$peer = New-Object HidPeripheral
if (-not $TabletSshWsl -or $ChildMarker) {
    if (-not $peer.Prepare().Wait(10000)) { throw 'Local HID profile setup timed out' }
    'HOST_HID_PROFILE_READY'
    if (-not $TabletSshWsl) { return }
}
if ($TabletSshWsl -notmatch '^/[A-Za-z0-9_./-]+$') { throw 'Expected the absolute WSL path of the SSH wrapper' }
$src = Join-Path $PSScriptRoot 'tablet-probe.py'
$linuxSrc = (wsl -d $Distro --exec wslpath -u $src).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot translate tablet probe path' }
$address = (wsl -d $Distro --exec bash $TabletSshWsl 'cat /etc/y700/bluetooth-address').Trim().Replace(':','').Replace('-','')
if ($LASTEXITCODE -ne 0 -or $address -notmatch '^[A-Fa-f0-9]{12}$') { throw 'Missing live tablet identity' }
function Assert-Unpaired {
    $query = [HidPeripheral]::IsTabletPaired($address)
    if (-not $query.Wait(10000) -or $query.Result) { throw 'Existing or unknown pairing with the Windows host' }
}
Assert-Unpaired
if ($ChildMarker) {
    $marker = $ChildMarker
    $bytes = [byte[]]($marker.Split('-'))
} else {
    $marker = [Guid]::NewGuid().ToByteArray()[0..7] -join '-'
    $options = @('-NoProfile','-File',$PSCommandPath,'-TabletSshWsl',$TabletSshWsl,'-Distro',$Distro,'-ChildMarker',$marker)
    if ($CheckPairing) { $options += '-CheckPairing' }
    if ($CheckReconnect) { $options += '-CheckReconnect' }
    & "$PSHOME/powershell.exe" @options
    $childResult = $LASTEXITCODE
    Assert-Unpaired
    $witness = [Guid]::NewGuid()
}
try {
    if ($ChildMarker) { $peer.Advertise($bytes) }
    else { $peer.AdvertiseControl($witness) }
    $deadline = [DateTime]::UtcNow.AddSeconds(6)
    while ($peer.Status() -ne 'Started' -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if ($peer.Status() -ne 'Started') {
        throw ("Host HID advertisement status: " + $peer.Status() + ", BluetoothError: " + $peer.AdvertisementError())
    }
    if ($ChildMarker) {
        'HOST_HID_ADVERTISEMENT_STARTED'
        $adapter = [HidPeripheral]::AdapterAddress()
        if (-not $adapter.Wait(5000)) { throw 'Host adapter lookup timed out' }
        $options = @('--host-address', $adapter.Result)
        if ($CheckPairing) { $options += '--check-pairing' }
        if ($CheckReconnect) { $options += '--check-reconnect' }
    } else {
        $options = @('--verify-quiet', $witness.ToString())
    }
    # The tablet wrapper checks its SSH host key. Arguments other than the
    # wrapper and local script path are generated or fixed in this process.
    wsl -d $Distro --exec bash -c 'wrapper=$1; source_file=$2; shift 2; exec bash "$wrapper" uv run --offline --no-project --python /usr/bin/python3 python - "$@" < "$source_file"' -- $TabletSshWsl $linuxSrc $marker @options
    if ($LASTEXITCODE -ne 0) { throw 'Tablet probe failed' }
} finally {
    $peer.Stop()
}
Assert-Unpaired
if (-not $ChildMarker -and $childResult -ne 0) { throw 'HID fixture failed before control verification' }
'HOST_BONDS_PRESERVED'
