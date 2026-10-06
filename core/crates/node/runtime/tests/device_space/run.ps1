param(
    [switch]$Run,
    [ValidateRange(1, 100)][int]$Repeat = 1
)
$ErrorActionPreference = 'Stop'
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../../../..'))
$python = Join-Path $repo '.venv/Scripts/python.exe'
& $python (Join-Path $PSScriptRoot 'check_structure.py')
if ($LASTEXITCODE -ne 0) { throw 'Device-space structural checks failed.' }
if (-not $Run) { return }
$oldFlags = $env:RUSTFLAGS
try {
    $env:RUSTFLAGS = "$oldFlags -Awarnings".Trim()
    for ($iteration = 1; $iteration -le $Repeat; $iteration++) {
        Write-Host "Device-space behavior run $iteration / $Repeat"
        & cargo test --manifest-path (Join-Path $repo 'core/Cargo.toml') -p operit-node-runtime --lib device_space -- --test-threads=1
        if ($LASTEXITCODE -ne 0) { throw "Device-space behavior run $iteration failed." }
    }
} finally {
    $env:RUSTFLAGS = $oldFlags
}
