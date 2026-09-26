param(
    [Parameter(Mandatory=$true)][ValidateSet('709','11b')][string]$ErrorCode,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$PrinterServer = '',
    [switch]$DiagnosticOnly
)

$ErrorActionPreference = 'Stop'
$logPath = Join-Path $OutputDirectory 'Acoes.log'
$statePath = Join-Path $OutputDirectory 'Estado-anterior.clixml'
$restorePath = Join-Path $OutputDirectory 'RESTAURAR-ERRO-IMPRESSORA.ps1'
$reportPath = Join-Path $OutputDirectory 'Relatorio.txt'
$rpcKey = 'SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC'
$printKey = 'SYSTEM\CurrentControlSet\Control\Print'
$legacyKey = 'SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides'

function Test-PrinterRepairAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-PrinterRepairLog {
    param([string]$Message)
    $entry = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Message
    if (Test-Path -LiteralPath $OutputDirectory) {
        Add-Content -LiteralPath $logPath -Value $entry -Encoding UTF8
    }
    Write-Output $entry
}

function Get-PrinterRepairBuild {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion', $false)
    if (-not $key) { throw 'Nao foi possivel identificar a build do Windows.' }
    try { return [int]$key.GetValue('CurrentBuildNumber', '0') }
    finally { $key.Close() }
}

function Get-PrinterRepairPlan {
    param([ValidateSet('709','11b')][string]$Code, [int]$BuildNumber)
    if ($Code -eq '11b') {
        return @([pscustomobject]@{
            KeyPath='SYSTEM\CurrentControlSet\Control\Print'
            Name='RpcAuthnLevelPrivacyEnabled'; Value=0
        })
    }
    $plan = @()
    $rpc = 'SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC'
    $legacy = 'SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides'
    if ($BuildNumber -ge 22000) {
        $plan += [pscustomobject]@{ KeyPath=$rpc; Name='RpcUseNamedPipeProtocol'; Value=1 }
    }
    if ($BuildNumber -ge 22621) {
        $plan += [pscustomobject]@{ KeyPath=$rpc; Name='RpcProtocols'; Value=7 }
    }
    switch ($BuildNumber) {
        17763 { $plan += [pscustomobject]@{ KeyPath=$legacy; Name='3598754956'; Value=0 } }
        18363 { $plan += [pscustomobject]@{ KeyPath=$legacy; Name='1921033356'; Value=0 } }
        { $_ -ge 19041 -and $_ -le 19044 } {
            $plan += [pscustomobject]@{ KeyPath=$legacy; Name='713073804'; Value=0 }
        }
    }
    return $plan
}

function Get-PrinterRepairRegistryState {
    param([string]$KeyPath, [string]$ValueName)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($KeyPath, $false)
    if (-not $key) { return [pscustomobject]@{ KeyPath=$KeyPath; Name=$ValueName; Exists=$false; Kind=''; Value=$null } }
    try {
        if ($key.GetValueNames() -notcontains $ValueName) {
            return [pscustomobject]@{ KeyPath=$KeyPath; Name=$ValueName; Exists=$false; Kind=''; Value=$null }
        }
        return [pscustomobject]@{
            KeyPath=$KeyPath; Name=$ValueName; Exists=$true
            Kind=$key.GetValueKind($ValueName).ToString(); Value=$key.GetValue($ValueName, $null)
        }
    } finally { $key.Close() }
}

function Set-PrinterRepairDword {
    param([string]$KeyPath, [string]$ValueName, [int]$Value)
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($KeyPath)
    if (-not $key) { throw "Nao foi possivel abrir HKLM\$KeyPath para gravacao." }
    try { $key.SetValue($ValueName, $Value, [Microsoft.Win32.RegistryValueKind]::DWord) }
    finally { $key.Close() }
}

function Test-PrinterRepairSmb {
    param([string]$Server)
    if (-not $Server) { return $null }
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Server, 445, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(1500)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch { return $false }
    finally { $client.Close() }
}

function Test-PrinterRepairLocalServer {
    param([string]$Server)
    if (-not $Server) { return $true }
    return ($Server -ieq $env:COMPUTERNAME -or $Server -ieq 'localhost' -or $Server -eq '127.0.0.1')
}

$changed = $false
try {
    if (-not $DiagnosticOnly -and -not (Test-PrinterRepairAdmin)) { throw 'Execute a correcao como administrador.' }
    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    $build = Get-PrinterRepairBuild
    $plan = @(Get-PrinterRepairPlan -Code $ErrorCode -BuildNumber $build)
    $smbReachable = if ($ErrorCode -eq '709') { Test-PrinterRepairSmb -Server $PrinterServer } else { $null }
    $remoteHost = -not (Test-PrinterRepairLocalServer -Server $PrinterServer)
    Write-PrinterRepairLog "Inicio. Erro=$ErrorCode; build=$build; computador=$env:COMPUTERNAME; servidor=$PrinterServer"
    foreach ($item in $plan) { Write-PrinterRepairLog "Planejado: HKLM\$($item.KeyPath)\$($item.Name)=$($item.Value)" }
    if ($null -ne $smbReachable) { Write-PrinterRepairLog "Teste SMB 445 com $PrinterServer`: $smbReachable" }

    $previous = @($plan | ForEach-Object {
        Get-PrinterRepairRegistryState -KeyPath $_.KeyPath -ValueName $_.Name
    })
    [pscustomobject]@{ ErrorCode=$ErrorCode; Build=$build; Values=$previous } |
        Export-Clixml -LiteralPath $statePath -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'RESTAURAR-ERRO-IMPRESSORA.ps1') -Destination $restorePath -Force
    Write-PrinterRepairLog "Estado anterior salvo em $statePath"

    if ($DiagnosticOnly) {
        @(
            "DIAGNOSTICO DO ERRO 0x00000$ErrorCode",
            "Computador: $env:COMPUTERNAME",
            "Build: $build",
            "Ajustes previstos: $($plan.Count)",
            'Resultado: somente diagnostico; nada foi alterado.',
            "Servidor selecionado: $PrinterServer",
            "SMB 445 acessivel: $smbReachable",
            "Estado anterior: $statePath",
            "Log: $logPath"
        ) | Set-Content -LiteralPath $reportPath -Encoding UTF8
        Write-PrinterRepairLog "Diagnostico concluido. Relatorio: $reportPath"
        exit 0
    }

    if ($plan.Count -eq 0) {
        Write-PrinterRepairLog "Nenhum ajuste de Registro para erro $ErrorCode na build $build."
    } else {
        $changed = $true
        foreach ($item in $plan) {
            Set-PrinterRepairDword -KeyPath $item.KeyPath -ValueName $item.Name -Value $item.Value
            $verified = Get-PrinterRepairRegistryState -KeyPath $item.KeyPath -ValueName $item.Name
            if (-not $verified.Exists -or [int]$verified.Value -ne [int]$item.Value) {
                throw "O Windows nao confirmou $($item.Name)=$($item.Value)."
            }
            Write-PrinterRepairLog "Confirmado: $($item.Name)=$($item.Value)"
        }
    }

    $spooler = Get-Service -Name Spooler -ErrorAction Stop
    if ($spooler.Status -eq 'Running') {
        Restart-Service -Name Spooler -Force -ErrorAction Stop
    } else {
        Start-Service -Name Spooler -ErrorAction Stop
    }
    (Get-Service -Name Spooler -ErrorAction Stop).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    Write-PrinterRepairLog 'Spooler confirmado em execucao.'

    $warnings = @()
    if ($plan.Count -eq 0) { $warnings += "Nenhum ajuste especifico de Registro para 0x00000$ErrorCode nesta build." }
    if ($ErrorCode -eq '709' -and $smbReachable -eq $false) {
        $warnings += "O servidor $PrinterServer nao respondeu na porta SMB 445; verifique rede e compartilhamento."
    }
    if ($ErrorCode -eq '11b' -and -not $PrinterServer) {
        $warnings += 'Se a impressora estiver em outro PC, execute esta correcao tambem no PC que a compartilha.'
    } elseif ($ErrorCode -eq '11b' -and $remoteHost) {
        $warnings += "A impressora selecionada esta em $PrinterServer. O ajuste 11b deve ser aplicado tambem nesse PC host."
    }
    $result = if ($warnings.Count -gt 0) { 'Ajustes locais aplicados; verificacoes pendentes.' } else { 'Ajustes locais aplicados e confirmados.' }
    $lines = @(
        "CORRECAO DO ERRO 0x00000$ErrorCode",
        ('Data: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        "Computador: $env:COMPUTERNAME",
        "Build: $build",
        "Servidor selecionado: $PrinterServer",
        "Ajustes de Registro aplicados: $($plan.Count)",
        "Resultado: $result",
        "Estado anterior: $statePath",
        "Restauracao: $restorePath",
        "Log: $logPath"
    )
    foreach ($warning in $warnings) { $lines += "AVISO: $warning"; Write-PrinterRepairLog "AVISO: $warning" }
    $lines | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-PrinterRepairLog "Concluido. Relatorio: $reportPath"
    if ($warnings.Count -gt 0) { exit 10 }
    exit 0
} catch {
    $failure = $_.Exception.Message
    Write-PrinterRepairLog "FALHA: $failure"
    if ($changed -and (Test-Path -LiteralPath $restorePath) -and (Test-Path -LiteralPath $statePath)) {
        try {
            & $restorePath -StatePath $statePath | Out-Null
            Write-PrinterRepairLog 'Valores anteriores restaurados apos falha.'
        } catch {
            Write-PrinterRepairLog "Restauracao automatica falhou: $($_.Exception.Message)"
        }
    }
    @(
        "CORRECAO DO ERRO 0x00000$ErrorCode",
        "Computador: $env:COMPUTERNAME",
        "Resultado: falha - $failure",
        "Log: $logPath",
        "Estado anterior: $statePath"
    ) | Set-Content -LiteralPath $reportPath -Encoding UTF8
    exit 20
}
