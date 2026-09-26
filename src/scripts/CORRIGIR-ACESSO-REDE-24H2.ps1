param(
    [Parameter(Mandatory=$true)][ValidateSet('Cliente','Host')][string]$Role,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [switch]$DiagnosticOnly
)

$ErrorActionPreference = 'Stop'
$logPath = Join-Path $OutputDirectory 'Acoes.log'
$statePath = Join-Path $OutputDirectory 'Estado-anterior.clixml'
$restorePath = Join-Path $OutputDirectory 'RESTAURAR-ACESSO-REDE.ps1'
$reportPath = Join-Path $OutputDirectory 'Relatorio.txt'
$clientPolicyKey = 'SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation'
$rpcPolicyKey = 'SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC'

function Test-NetworkRepairAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-NetworkRepairLog {
    param([string]$Message)
    $entry = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Message
    if (Test-Path -LiteralPath $OutputDirectory) {
        Add-Content -LiteralPath $logPath -Value $entry -Encoding UTF8
    }
    Write-Output $entry
}

function Get-NetworkRepairBuild {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion', $false)
    if (-not $key) { throw 'Nao foi possivel identificar a build do Windows.' }
    try { return [int]$key.GetValue('CurrentBuildNumber', '0') }
    finally { $key.Close() }
}

function Get-NetworkRepairRegistryState {
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

function Set-NetworkRepairDword {
    param([string]$KeyPath, [string]$ValueName, [int]$Value)
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($KeyPath)
    if (-not $key) { throw "Nao foi possivel abrir HKLM\$KeyPath para gravacao." }
    try { $key.SetValue($ValueName, $Value, [Microsoft.Win32.RegistryValueKind]::DWord) }
    finally { $key.Close() }
}

function Get-NetworkRepairPlan {
    param([ValidateSet('Cliente','Host')][string]$TargetRole, [int]$BuildNumber)
    if ($TargetRole -eq 'Cliente') {
        return @(
            'Permitir logon SMB como convidado no cliente',
            'Desativar exigencia de assinatura SMB no cliente',
            'Definir a politica AllowInsecureGuestAuth=1 no cliente'
        )
    }
    $actions = @('Desativar exigencia de assinatura SMB no servidor')
    if ($BuildNumber -ge 22621) {
        $actions += 'Definir RpcProtocols=7 para receber RPC por TCP e Named Pipes'
    }
    return $actions
}

$changed = $false
try {
    if (-not $DiagnosticOnly -and -not (Test-NetworkRepairAdmin)) { throw 'Execute a rotina como administrador.' }
    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    $build = Get-NetworkRepairBuild
    Write-NetworkRepairLog "Inicio da correcao de rede. Papel=$Role; build=$build; computador=$env:COMPUTERNAME"
    foreach ($action in (Get-NetworkRepairPlan -TargetRole $Role -BuildNumber $build)) {
        Write-NetworkRepairLog "Planejado: $action"
    }

    if ($Role -eq 'Cliente') {
        Get-Command Get-SmbClientConfiguration,Set-SmbClientConfiguration -ErrorAction Stop | Out-Null
        $current = Get-SmbClientConfiguration -ErrorAction Stop
        if ($null -eq $current.RequireSecuritySignature -or $null -eq $current.EnableInsecureGuestLogons) {
            throw 'Esta versao do Windows nao oferece todas as opcoes SMB de cliente necessarias.'
        }
        $registry = Get-NetworkRepairRegistryState -KeyPath $clientPolicyKey -ValueName 'AllowInsecureGuestAuth'
        $snapshot = [pscustomobject]@{
            Role=$Role; Build=$build; Registry=$registry
            RequireSecuritySignature=[bool]$current.RequireSecuritySignature
            EnableInsecureGuestLogons=[bool]$current.EnableInsecureGuestLogons
        }
    } else {
        Get-Command Get-SmbServerConfiguration,Set-SmbServerConfiguration -ErrorAction Stop | Out-Null
        $current = Get-SmbServerConfiguration -ErrorAction Stop
        if ($null -eq $current.RequireSecuritySignature) {
            throw 'Esta versao do Windows nao oferece a opcao SMB de servidor necessaria.'
        }
        $registry = if ($build -ge 22621) {
            Get-NetworkRepairRegistryState -KeyPath $rpcPolicyKey -ValueName 'RpcProtocols'
        } else { $null }
        $snapshot = [pscustomobject]@{
            Role=$Role; Build=$build; Registry=$registry
            RequireSecuritySignature=[bool]$current.RequireSecuritySignature
            EnableInsecureGuestLogons=$null
        }
    }

    $snapshot | Export-Clixml -LiteralPath $statePath -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'RESTAURAR-ACESSO-REDE.ps1') -Destination $restorePath -Force
    Write-NetworkRepairLog "Estado anterior salvo em $statePath"

    if ($DiagnosticOnly) {
        @(
            'DIAGNOSTICO DE ACESSO A REDE E IMPRESSORAS COMPARTILHADAS',
            "Computador: $env:COMPUTERNAME",
            "Papel: $Role",
            "Build do Windows: $build",
            'Resultado: somente leitura. Nenhuma configuracao SMB ou RPC foi alterada.',
            "Estado consultado: $statePath",
            "Log: $logPath"
        ) | Set-Content -LiteralPath $reportPath -Encoding UTF8
        Write-NetworkRepairLog "Diagnostico concluido. Relatorio: $reportPath"
        exit 0
    }

    $changed = $true
    if ($Role -eq 'Cliente') {
        Set-SmbClientConfiguration -EnableInsecureGuestLogons $true -RequireSecuritySignature $false -Force -ErrorAction Stop | Out-Null
        Set-NetworkRepairDword -KeyPath $clientPolicyKey -ValueName 'AllowInsecureGuestAuth' -Value 1
        $verified = Get-SmbClientConfiguration -ErrorAction Stop
        $policy = Get-NetworkRepairRegistryState -KeyPath $clientPolicyKey -ValueName 'AllowInsecureGuestAuth'
        if (-not $verified.EnableInsecureGuestLogons -or $verified.RequireSecuritySignature -or -not $policy.Exists -or [int]$policy.Value -ne 1) {
            throw 'O Windows nao confirmou todos os ajustes SMB do cliente.'
        }
        Write-NetworkRepairLog 'Cliente: convidado SMB permitido, assinatura nao obrigatoria e politica registrada.'
    } else {
        Set-SmbServerConfiguration -RequireSecuritySignature $false -Force -ErrorAction Stop | Out-Null
        if ($build -ge 22621) {
            Set-NetworkRepairDword -KeyPath $rpcPolicyKey -ValueName 'RpcProtocols' -Value 7
        }
        $verified = Get-SmbServerConfiguration -ErrorAction Stop
        if ($verified.RequireSecuritySignature) { throw 'O Windows ainda exige assinatura SMB no servidor.' }
        if ($build -ge 22621) {
            $policy = Get-NetworkRepairRegistryState -KeyPath $rpcPolicyKey -ValueName 'RpcProtocols'
            if (-not $policy.Exists -or [int]$policy.Value -ne 7) { throw 'O Windows nao confirmou RpcProtocols=7.' }
        }
        Write-NetworkRepairLog 'Host: assinatura SMB nao obrigatoria; politica RPC aplicada quando compativel.'
    }

    @(
        'CORRECAO DE ACESSO A REDE E IMPRESSORAS COMPARTILHADAS',
        ('Data: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        "Computador: $env:COMPUTERNAME",
        "Papel: $Role",
        "Build do Windows: $build",
        'Resultado: ajustes confirmados pelo Windows.',
        'Novas conexoes SMB podem exigir reconexao ou reinicio do computador.',
        "Estado anterior: $statePath",
        "Restauracao: $restorePath",
        "Log: $logPath"
    ) | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-NetworkRepairLog "Concluido. Relatorio: $reportPath"
    exit 0
} catch {
    $failure = $_.Exception.Message
    Write-NetworkRepairLog "FALHA: $failure"
    if ($changed -and (Test-Path -LiteralPath $restorePath) -and (Test-Path -LiteralPath $statePath)) {
        try {
            & $restorePath -StatePath $statePath | Out-Null
            Write-NetworkRepairLog 'Estado anterior restaurado apos a falha.'
        } catch {
            Write-NetworkRepairLog "Falha ao restaurar automaticamente: $($_.Exception.Message)"
        }
    }
    @(
        'CORRECAO DE ACESSO A REDE E IMPRESSORAS COMPARTILHADAS',
        "Computador: $env:COMPUTERNAME",
        "Papel: $Role",
        "Resultado: falha - $failure",
        "Log: $logPath",
        "Estado anterior: $statePath",
        "Restauracao: $restorePath"
    ) | Set-Content -LiteralPath $reportPath -Encoding UTF8
    exit 20
}
