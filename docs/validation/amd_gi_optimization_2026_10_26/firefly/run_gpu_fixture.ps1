param(
    [string]$Engine = '',
    [string]$Python = '',
    [switch]$SkipTiming
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
if ([string]::IsNullOrEmpty($Engine)) {
    $Engine = Join-Path $repoRoot 'bin/godot.windows.editor.x86_64.console.exe'
}
if ([string]::IsNullOrEmpty($Python)) {
    $localPython = Join-Path $repoRoot '.artifacts/publish-tools/Scripts/python.exe'
    $Python = if (Test-Path -LiteralPath $localPython) { $localPython } else { 'python' }
}
$artifactRoot = Join-Path $repoRoot '.artifacts/gi-opt-20261026/firefly'
$fixture = Join-Path $artifactRoot 'generated'
& $Python (Join-Path $PSScriptRoot 'prepare_gpu_fixture.py') --output $fixture
if ($LASTEXITCODE -ne 0) { throw 'GPU fixture preparation failed.' }
$output = Join-Path $artifactRoot ('gpu-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $output | Out-Null
Copy-Item -LiteralPath (Join-Path $fixture 'fixture_manifest.json') -Destination $output
$oldAppData = $env:APPDATA
$oldOutput = $env:FIREFLY_GPU_OUTPUT
$oldSkip = $env:FIREFLY_GPU_SKIP_TIMING
try {
    $env:APPDATA = Join-Path $output 'userdata'
    $env:FIREFLY_GPU_OUTPUT = $output
    $env:FIREFLY_GPU_SKIP_TIMING = if ($SkipTiming) { '1' } else { '0' }
    New-Item -ItemType Directory -Path $env:APPDATA | Out-Null
    & $Engine --path $fixture --script "$fixture/gpu_fixture.gd" --windowed --resolution 320x180 --rendering-driver vulkan --audio-driver Dummy --log-file "$output/run.log" 2>&1 | Out-File -LiteralPath "$output/console.log"
    $code = $LASTEXITCODE
} finally {
    $env:APPDATA = $oldAppData
    $env:FIREFLY_GPU_OUTPUT = $oldOutput
    $env:FIREFLY_GPU_SKIP_TIMING = $oldSkip
}
[ordered]@{ engine=$Engine; engineSha256=(Get-FileHash -LiteralPath $Engine -Algorithm SHA256).Hash; exitCode=$code; output=$output } | ConvertTo-Json | Set-Content -LiteralPath "$output/run_manifest.json"
Get-Content -LiteralPath "$output/console.log" -Tail 8
Write-Output "Evidence: $output"
if ($code -ne 0 -or -not (Test-Path -LiteralPath "$output/gpu_result.json")) { exit 1 }
$result = Get-Content -Raw -LiteralPath "$output/gpu_result.json" | ConvertFrom-Json
if ($result.result -ne 'pass') { exit 1 }
exit 0
