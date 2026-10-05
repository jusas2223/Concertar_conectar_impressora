$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\scripts\IMPRESSAO-COMUM.ps1')
$temp=Join-Path $env:TEMP ('DriverInfTest_'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try{
    # Driver store exit code alone must never count as registration.
    [IO.File]::WriteAllText((Join-Path $temp 'modelo.inf'),"[Version]`r`nClass=Printer`r`n",[Text.Encoding]::ASCII)
    function Assert-PrinterAdmin {}
    function Get-WindowsDriver {param([switch]$Online,[switch]$All,$ErrorAction) return @()}
    function Invoke-PrinterPnPProcess {param($InfPath,$Build) $script:pnpCalls++;return @{Code=$script:pnpCode;Output=@('Fixture')}}
    function Add-PrinterDriver {param($Name,$InfPath,$ErrorAction) $script:requestedName=$Name}
    function Get-PrinterDriver {param($Name,$ErrorAction) if($script:registered){return [pscustomobject]@{Name=$Name;MajorVersion=3}}}
    $script:pnpCode=0;$script:pnpCalls=0;$script:registered=$false
    $rejected=$false
    try{Invoke-PrinterPnPInstall -Directory $temp -DriverName 'Modelo exato' -InfName modelo.inf | Out-Null}catch{$rejected=$true}
    if(-not $rejected -or $script:pnpCalls -ne 1){throw 'PnPUtil sem driver no spooler foi aceito'}
    $script:registered=$true;$script:pnpCalls=0
    $result=Invoke-PrinterPnPInstall -Directory $temp -DriverName 'Modelo exato' -InfName modelo.inf
    if(-not $result.Success -or $result.DriverName -ne 'Modelo exato' -or $script:requestedName -ne 'Modelo exato'){throw 'Nome exato do driver perdido'}
    $script:pnpCode=5;$rejected=$false
    try{Invoke-PrinterPnPInstall -Directory $temp -DriverName 'Modelo exato' | Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Falha PnPUtil ignorada porque já havia driver'}
    $script:pnpCode=3010
    $result=Invoke-PrinterPnPInstall -Directory $temp -DriverName 'Modelo exato'
    if(-not $result.RebootRequired){throw 'Reinicialização necessária não informada'}

    $t=$null;$e=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src\scripts\DRIVER-DO-SERVIDOR.ps1'),[ref]$t,[ref]$e)
    foreach($name in @('Set-DriverStage','Copy-DriverSourceFile','Get-PackageKey','Get-SafeFileName','Find-RemoteInfPackage','Copy-ExactDriverDirectory')){
        $fn=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true) | Select-Object -First 1
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    Add-Type -TypeDefinition 'public static class PrinterDriverTransfer {public static string QueueDriver(string name){return "Modelo exato";} public static string DriverInf(string name,string environment){return "modelo.inf";}}'
    function Test-PrinterRemotePath {param($Path,[switch]$Directory)
        if($Path -like '\\*') {return -not $Path.EndsWith('package.json')}
        return (Microsoft.PowerShell.Management\Test-Path -LiteralPath $Path)
    }
    function Get-ChildItem {param($LiteralPath,$Filter,[switch]$Recurse,[switch]$File,[switch]$Directory,$ErrorAction)
        $where=if($LiteralPath -like '\\*'){$temp}else{$LiteralPath}
        $options=@{LiteralPath=$where;Recurse=[bool]$Recurse}
        if($Filter){$options.Filter=$Filter}
        if($File){$options.File=$true}
        if($Directory){$options.Directory=$true}
        return (Microsoft.PowerShell.Management\Get-ChildItem @options)
    }
    $package=Find-RemoteInfPackage -Server SERVIDOR -Share Fila -Architecture x64 -Environment 'Windows x64'
    if($package.Source -ne (Get-Item -LiteralPath $temp).FullName -or $package.InfName -ne 'modelo.inf' -or $package.DriverName -ne 'Modelo exato'){throw 'INF incorreto selecionado'}
    [void][IO.Directory]::CreateDirectory((Join-Path $temp 'duplicado'))
    Copy-Item (Join-Path $temp 'modelo.inf') (Join-Path $temp 'duplicado\modelo.inf')
    $rejected=$false
    try{Find-RemoteInfPackage -Server SERVIDOR -Share Fila -Architecture x64 -Environment 'Windows x64' | Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Pacotes INF ambíguos foram instalados arbitrariamente'}
}finally{
    if([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath($env:TEMP)+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $temp -Recurse -Force}
}
'OK: INF exato, ambiguidade recusada, código PnPUtil insuficiente e reinicialização informada.'
