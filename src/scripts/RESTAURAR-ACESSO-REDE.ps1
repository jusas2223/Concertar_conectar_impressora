param(
    [string]$StatePath = (Join-Path $PSScriptRoot 'Estado-anterior.clixml')
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Execute a restauracao como administrador.'
}
if (-not (Test-Path -LiteralPath $StatePath)) { throw "Estado anterior nao encontrado: $StatePath" }
$state = Import-Clixml -LiteralPath $StatePath
if ($state.Role -notin @('Cliente','Host')) { throw 'Papel invalido no estado anterior.' }

function Restore-NetworkRegistryValue {
    param($Saved)
    if (-not $Saved) { return }
    $root = [Microsoft.Win32.Registry]::LocalMachine
    if ($Saved.Exists) {
        $key = $root.CreateSubKey([string]$Saved.KeyPath)
        if (-not $key) { throw "Nao foi possivel restaurar HKLM\$($Saved.KeyPath)." }
        try {
            $kind = [Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$Saved.Kind)
            $key.SetValue([string]$Saved.Name, $Saved.Value, $kind)
        } finally { $key.Close() }
    } else {
        $key = $root.OpenSubKey([string]$Saved.KeyPath, $true)
        if ($key) {
            try {
                if ($key.GetValueNames() -contains [string]$Saved.Name) {
                    $key.DeleteValue([string]$Saved.Name, $false)
                }
            } finally { $key.Close() }
        }
    }
}

Restore-NetworkRegistryValue -Saved $state.Registry
if ($state.Role -eq 'Cliente') {
    Set-SmbClientConfiguration -EnableInsecureGuestLogons ([bool]$state.EnableInsecureGuestLogons) -RequireSecuritySignature ([bool]$state.RequireSecuritySignature) -Force -ErrorAction Stop | Out-Null
    $current = Get-SmbClientConfiguration -ErrorAction Stop
    if ([bool]$current.EnableInsecureGuestLogons -ne [bool]$state.EnableInsecureGuestLogons -or
        [bool]$current.RequireSecuritySignature -ne [bool]$state.RequireSecuritySignature) {
        throw 'A restauracao do cliente SMB nao foi confirmada.'
    }
} else {
    Set-SmbServerConfiguration -RequireSecuritySignature ([bool]$state.RequireSecuritySignature) -Force -ErrorAction Stop | Out-Null
    $current = Get-SmbServerConfiguration -ErrorAction Stop
    if ([bool]$current.RequireSecuritySignature -ne [bool]$state.RequireSecuritySignature) {
        throw 'A restauracao do servidor SMB nao foi confirmada.'
    }
}
Write-Output "Configuracao anterior restaurada. Papel: $($state.Role)."
