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
if ($state.ErrorCode -notin @('709','11b')) { throw 'Codigo de erro invalido no estado salvo.' }

foreach ($saved in @($state.Values)) {
    $root = [Microsoft.Win32.Registry]::LocalMachine
    if ($saved.Exists) {
        $key = $root.CreateSubKey([string]$saved.KeyPath)
        if (-not $key) { throw "Nao foi possivel restaurar HKLM\$($saved.KeyPath)." }
        try {
            $kind = [Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$saved.Kind)
            $key.SetValue([string]$saved.Name, $saved.Value, $kind)
        } finally { $key.Close() }
    } else {
        $key = $root.OpenSubKey([string]$saved.KeyPath, $true)
        if ($key) {
            try {
                if ($key.GetValueNames() -contains [string]$saved.Name) {
                    $key.DeleteValue([string]$saved.Name, $false)
                }
            } finally { $key.Close() }
        }
    }
}

$spooler = Get-Service -Name Spooler -ErrorAction Stop
if ($spooler.Status -eq 'Running') {
    Restart-Service -Name Spooler -Force -ErrorAction Stop
} else {
    Start-Service -Name Spooler -ErrorAction Stop
}
(Get-Service -Name Spooler -ErrorAction Stop).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
Write-Output "Valores anteriores do erro $($state.ErrorCode) restaurados."
