$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'src\AssistenteImpressoras.ps1'), [Text.Encoding]::UTF8)

$definition = [regex]::Match($source, "(?s)Add-Type -TypeDefinition @'\r?\n(?<code>.*?)\r?\n'@ -ErrorAction Stop")
if (-not $definition.Success) { throw 'A API de autenticacao de rede nao foi encontrada.' }
Add-Type -TypeDefinition $definition.Groups['code'].Value -ErrorAction Stop
if (-not [PrinterNetworkAuth].GetMethod('WNetAddConnection2')) {
    throw 'A API nativa de conexao de rede nao compilou corretamente.'
}

$manual = [regex]::Match($source, '(?s)# Acao: Buscar Impressoras Compartilhadas \(Manual\)(?<handler>.*?)\$btnDiagnoseShare\.Add_Click')
if (-not $manual.Success) { throw 'Busca manual nao encontrada.' }
$handler = $manual.Groups['handler'].Value
if (-not $handler.Contains('Connect-PrinterServerAuthenticated') -or
    -not $handler.Contains('$resolvedServer = $server') -or
    $handler.Contains('net.exe') -or
    $handler.Contains('mappedIpc')) {
    throw 'A busca manual nao preserva a sessao autenticada e o mesmo nome/IP.'
}
$localPort = [regex]::Match($source, '(?s)function Invoke-LocalPortInstallElevated \{(?<body>.*?)\r?\n\}\r?\n\r?\nfunction Show-LocalPortFallbackDialog')
if (-not $localPort.Success -or
    -not $localPort.Groups['body'].Value.Contains("if (-not (Test-IsAdmin)) { `$start.Verb = 'RunAs' }")) {
    throw 'O instalador local nao preserva o contexto SMB quando o aplicativo ja esta elevado.'
}
Write-Output 'OK: autenticacao nativa compila, senha nao vai para net.exe e sessao continua disponivel para a fila.'
