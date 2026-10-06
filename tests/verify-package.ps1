$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exePath = Join-Path $root 'Arrumar_impressoraVG.exe'
$scripts = @(
    @{ Path = (Join-Path $root 'src\AssistenteImpressoras.ps1'); Resource = 'AssistenteImpressoras.AssistenteImpressoras.ps1' },
    @{ Path = (Join-Path $root 'src\scripts\CORRIGIR-ERRO-IMPRESSORA.ps1'); Resource = 'AssistenteImpressoras.CORRIGIR-ERRO-IMPRESSORA.ps1' },
    @{ Path = (Join-Path $root 'src\scripts\RESTAURAR-ERRO-IMPRESSORA.ps1'); Resource = 'AssistenteImpressoras.RESTAURAR-ERRO-IMPRESSORA.ps1' },
    @{ Path = (Join-Path $root 'src\scripts\CORRIGIR-ACESSO-REDE-24H2.ps1'); Resource = 'AssistenteImpressoras.CORRIGIR-ACESSO-REDE-24H2.ps1' },
    @{ Path = (Join-Path $root 'src\scripts\RESTAURAR-ACESSO-REDE.ps1'); Resource = 'AssistenteImpressoras.RESTAURAR-ACESSO-REDE.ps1' },
    @{ Path = (Join-Path $root 'src\scripts\INSTALAR-PORTA-LOCAL.ps1'); Resource = 'AssistenteImpressoras.INSTALAR-PORTA-LOCAL.ps1' },
    @{ Path = (Join-Path $root 'src\scripts\CONECTAR-IMPRESSORA.ps1'); Resource = 'AssistenteImpressoras.CONECTAR-IMPRESSORA.ps1' },
    @{ Path = (Join-Path $root 'src\scripts\DRIVER-DO-SERVIDOR.ps1'); Resource = 'AssistenteImpressoras.DRIVER-DO-SERVIDOR.ps1' },
    @{ Path = (Join-Path $root 'src\scripts\IMPRESSAO-COMUM.ps1'); Resource = 'AssistenteImpressoras.IMPRESSAO-COMUM.ps1' },
    @{ Path = (Join-Path $root 'src\scripts\INTERFACE.ps1'); Resource = 'AssistenteImpressoras.INTERFACE.ps1' },
    @{ Path = (Join-Path $root 'Diagnostico_Compartilhamento.ps1'); Resource = 'AssistenteImpressoras.Diagnostico_Compartilhamento.ps1' }
)

if (-not (Test-Path -LiteralPath $exePath)) { throw 'Compile o EXE antes deste teste.' }
$assembly = [Reflection.Assembly]::LoadFile($exePath)
if ($assembly.GetName().Version.ToString() -ne '1.10.9.0') { throw 'Versao do EXE incorreta.' }
$mainSource=[IO.File]::ReadAllText($scripts[0].Path)
$logVersion=[regex]::Match($mainSource,'Versão do app: ([0-9.]+) \|')
if(-not $logVersion.Success -or $logVersion.Groups[1].Value -ne $assembly.GetName().Version.ToString(3)){throw 'Versão do cabeçalho do log diverge do EXE.'}
$launcherType = $assembly.GetType('AssistenteImpressorasLauncher.Program', $true)
$quoteMethod = $launcherType.GetMethod('Quote', [Reflection.BindingFlags]'NonPublic,Static')
if (-not $quoteMethod -or $quoteMethod.Invoke($null, @('T:\')) -cne '"T:\\"') {
    throw 'O iniciador não preserva a barra final da unidade compartilhada.'
}

foreach ($entry in $scripts) {
    $resource = $assembly.GetManifestResourceStream($entry.Resource)
    if (-not $resource) { throw "Recurso ausente: $($entry.Resource)" }
    $buffer = New-Object IO.MemoryStream
    try {
        $resource.CopyTo($buffer)
        $sourceBytes = [IO.File]::ReadAllBytes($entry.Path)
        if ([Convert]::ToBase64String($buffer.ToArray()) -cne [Convert]::ToBase64String($sourceBytes)) {
            throw "Recurso incorporado difere do arquivo revisado: $($entry.Path)"
        }
    } finally {
        $buffer.Dispose()
        $resource.Dispose()
    }
}

# Exercita a citacao de caminhos com espacos usada ao iniciar uma rotina externa.
$tempDirectory = Join-Path $env:TEMP ('PrinterFixLaunchTest_' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempDirectory) | Out-Null
$fixture = Join-Path $tempDirectory 'launch test.bat'
try {
    [IO.File]::WriteAllText($fixture, "@echo off`r`nexit /b 23`r`n", [Text.Encoding]::ASCII)
    $arguments = '/c ""' + $fixture + '""'
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 23) { throw "Chamada do BAT com espacos falhou: $($process.ExitCode)" }
} finally {
    if ([IO.File]::Exists($fixture)) { [IO.File]::Delete($fixture) }
    if ([IO.Directory]::Exists($tempDirectory)) { [IO.Directory]::Delete($tempDirectory) }
}

Write-Output 'OK: versão, script principal, dez rotinas incorporadas e chamada com caminho contendo espaços.'
