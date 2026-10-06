$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\scripts\IMPRESSAO-COMUM.ps1')
foreach($code in @(5,86,1326,1331,1385,1909,87,1801,1219,53)){
 foreach($scope in @('Remote','Local')){
  try{throw [ComponentModel.Win32Exception]::new($code)}catch{$result=Get-PrinterOperationFailure -Record $_ -Stage Fixture -Resource '\\SERVIDOR\print$' -Scope $scope}
  $expected=$scope -eq 'Remote' -and $code -in @(5,86,1326,1331,1385,1909)
  if($result.NativeCode -ne $code -or $result.NeedsAuthentication -ne $expected){throw "Classificação incorreta $code/$scope"}
 }
}
try{throw [UnauthorizedAccessException]::new('Fixture denied')}catch{$r=Get-PrinterOperationFailure -Record $_ -Stage Read -Resource '\\SERVIDOR\print$' -Scope Remote}
if($r.Code -ne 5 -or -not $r.NeedsAuthentication){throw 'UnauthorizedAccess perdeu o código de acesso negado'}
$wrapped=[Management.Automation.ErrorRecord]::new([Exception]::new('Fixture CIM'),'HRESULT 0x80070005,Add-PrinterPort',[Management.Automation.ErrorCategory]::PermissionDenied,$null)
$r=Get-PrinterOperationFailure -Record $wrapped -Stage LocalPort -Scope Local
if($r.Code -ne 5 -or $r.NeedsAuthentication){throw 'HRESULT CIM local confundido com senha remota'}

$temp=Join-Path $env:TEMP ('PrinterAuthErrors_'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$utf8=[Text.UTF8Encoding]::new($true)
try{
 if(Test-PrinterRemotePath -Path (Join-Path $temp 'absent')){throw 'Arquivo ausente confundido com acesso negado'}
 Copy-Item -LiteralPath (Join-Path $root 'src\scripts\IMPRESSAO-COMUM.ps1') -Destination $temp
 $worker=[IO.File]::ReadAllText((Join-Path $root 'src\scripts\DRIVER-DO-SERVIDOR.ps1'))
 $mocks=@'
function Assert-PrinterAdmin {}
function Find-RemoteInfPackage {
 param($Server,$Share,$Architecture,$Environment,$RequestedDriver)
 Set-DriverStage 'Ler manifesto remoto do driver' -Scope Remote -Resource '\\SERVIDOR\print$\x64\manifest.json'
 if($global:scenario -eq 'read-denied'){throw [UnauthorizedAccessException]::new('Read denied fixture')}
 if($global:scenario -eq 'missing'){return $null}
 if($global:scenario -eq 'rpc-invalid'){
  Set-DriverStage 'Consultar driver da fila remota' -Scope Remote -Resource '\\SERVIDOR\Fila'
  throw [ComponentModel.Win32Exception]::new(1801)
 }
 return @{Source='\\SERVIDOR\print$\x64\pacote';InfName='modelo.inf';DriverName='Modelo fixture';Hashes=@()}
}
function Copy-ExactDriverDirectory {
 param($Source,$Destination)
 Set-DriverStage 'Criar pasta temporária do pacote' -Resource $Destination
 throw [UnauthorizedAccessException]::new('Local directory denied fixture')
}
function Test-PrinterRemotePath {param($Path,[switch]$Directory) return $false}
'@
 $worker=[regex]::Replace($worker,'(?m)^try \{\r?\n(?=    if\(\$Action)',[Text.RegularExpressions.MatchEvaluator]{param($m)$mocks+"`r`n"+$m.Value})
 [IO.File]::WriteAllText((Join-Path $temp 'DRIVER-DO-SERVIDOR.ps1'),$worker,$utf8)
 [IO.File]::WriteAllText((Join-Path $temp 'run.ps1'),@'
param($Scenario)
$global:scenario=$Scenario
$r=& (Join-Path $PSScriptRoot 'DRIVER-DO-SERVIDOR.ps1') -Server SERVIDOR -ShareName Fila
if($r.Success){throw 'Falha anunciada como sucesso'}
switch($Scenario){
 read-denied {if($r.Code -ne 5 -or -not $r.NeedsAuthentication -or $r.Resource -notlike '\\SERVIDOR\print$*' -or $r.Stage -ne 'Ler manifesto remoto do driver'){throw 'Falha remota mascarada como pacote ausente'}}
 local-denied {if($r.Code -ne 5 -or $r.NeedsAuthentication -or $r.FailureScope -ne 'Local' -or $r.Stage -ne 'Criar pasta temporária do pacote'){throw 'Falha local pediu senha de rede'}}
 missing {if($r.NeedsAuthentication -or $r.Code -ne 2 -or $r.PreparedPackageFound -ne $false -or $r.DriverAvailability -ne 'Unknown'){throw 'Pacote ausente pediu senha ou anunciou ausência comprovada do driver'}}
 rpc-invalid {if($r.Success -or $r.DriverQueryCode -ne 1801 -or $r.InfLookupStage -ne 'Consultar driver da fila remota' -or $r.PreparedPackageFound -ne $false -or $r.DriverAvailability -ne 'Unknown' -or $r.Message -notlike '*1801*'){throw 'Consulta RPC recusada perdeu a causa ou foi tratada como driver ausente'}}
}
'@,$utf8)
 foreach($scenario in @('read-denied','local-denied','missing','rpc-invalid')){
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $temp 'run.ps1') -Scenario $scenario
  if($LASTEXITCODE){throw "Worker driver falhou em $scenario"}
 }
}finally{
 if([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath($env:TEMP)+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $temp -Recurse -Force}
}

$source=[IO.File]::ReadAllText((Join-Path $root 'src\AssistenteImpressoras.ps1'))
foreach($pattern in @('(?s)\$received = Invoke-PrinterOperationUsingAvailableSession.*?-Method InstallDriver','(?s)\$attempt = Invoke-PrinterOperationUsingAvailableSession.*?Invoke-LocalPortInstallElevated','(?m)\$res = Connect-PrinterUsingAvailableSession -UNCPath \$unc[^\r\n]*-RequestCredential')){
 if($source -notmatch $pattern){throw 'Um caminho da interface ficou sem a solicitação de conta'}
}
'OK: códigos remotos/locais, erros reais do worker do driver e pedidos de conta em todos os caminhos.'
