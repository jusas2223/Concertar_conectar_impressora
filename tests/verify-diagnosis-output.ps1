$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$diagnosis = Join-Path $root 'Diagnostico_Compartilhamento.ps1'
$assistant = [IO.File]::ReadAllText((Join-Path $root 'src\AssistenteImpressoras.ps1'))
if (-not $assistant.Contains('-OutputDirectory $LogsDir')) {
    throw 'O botao de diagnostico nao usa a pasta de logs validada.'
}

$blockedDirectory = Join-Path $env:TEMP ('PrinterDiagnosisBlocked_' + [Guid]::NewGuid().ToString('N'))
$reportPath = $null
try {
    # Um arquivo com o nome do diretorio simula um destino onde CreateDirectory falha.
    [IO.File]::WriteAllText($blockedDirectory, 'blocked')
    $result = @(& $diagnosis -Servidor 'localhost' -Compartilhamento 'Teste' -OutputDirectory $blockedDirectory)
    $reportLine = @($result | Where-Object { $_ -like 'REPORT_PATH=*' } | Select-Object -First 1)
    if (-not $reportLine.Count) { throw 'O diagnostico nao retornou o caminho do relatorio.' }
    $reportPath = ([string]$reportLine[0]).Substring('REPORT_PATH='.Length).Trim()
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw 'O relatorio nao foi criado.' }
    if ($reportPath.StartsWith($blockedDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'O diagnostico nao usou o destino alternativo.'
    }
    $reportText = [IO.File]::ReadAllText($reportPath, [Text.Encoding]::UTF8)
    if (-not $reportText.Contains('usuário')) { throw 'O relatorio perdeu a codificacao UTF-8 dos acentos.' }
    Write-Output 'OK: relatorio criado em pasta local quando o destino solicitado nao aceita escrita.'
} finally {
    if ($reportPath -and [IO.File]::Exists($reportPath)) { [IO.File]::Delete($reportPath) }
    if ([IO.File]::Exists($blockedDirectory)) { [IO.File]::Delete($blockedDirectory) }
}
