$ErrorActionPreference = 'Stop'
$failed = @()
$scripts = Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'verify-*.ps1' -File | Sort-Object Name
foreach ($script in $scripts) {
    Write-Host "TEST $($script.Name)"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script.FullName
    if ($LASTEXITCODE -ne 0) { $failed += $script.Name }
}
if ($failed.Count -gt 0) {
    throw "Falharam $($failed.Count) teste(s): $($failed -join ', ')"
}
Write-Host "OK: $($scripts.Count) testes passaram."
