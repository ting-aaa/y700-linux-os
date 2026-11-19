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
