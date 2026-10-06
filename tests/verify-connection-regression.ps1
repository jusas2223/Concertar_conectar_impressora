$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\scripts\IMPRESSAO-COMUM.ps1')
# Exercise restoration and host preparation without changing this PC.
function Assert-PrinterAdmin {}
$script:registry=@{};$script:writes=0;$script:restarts=0
function Get-PrinterPolicyValue {param($Path,$Name) return $script:registry[($Path+'|'+$Name)].Clone()}
function Set-PrinterPolicyValue {param($State) $script:writes++;$script:registry[($State.Path+'|'+$State.Name)]=$State.Clone()}
function Restart-Service {param($Name,[switch]$Force,$ErrorAction) $script:restarts++}
function Start-Service {param($Name,$ErrorAction) $script:starts++}
function Set-Service {param($Name,$StartupType,$ErrorAction) $script:startup=$StartupType}
function Get-Service {param($Name,$ErrorAction)
 $service=[pscustomobject]@{Status='Running'}
 $service | Add-Member ScriptMethod WaitForStatus {param($Status,$Timeout)}
 return $service
}
$temp=Join-Path $env:TEMP ('ConnectionRegression_'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try{
 foreach($role in @('Client','Host')){
  $plan=@(Get-PrinterCompatibilityPolicyEntries -Role $role)
  $original=@();$later=@();$script:registry=@{};$script:writes=0;$script:restarts=0
  foreach($entry in $plan){
   $original+=@{Path=$entry.Path;Name=$entry.Name;Exists=$false;Value=$null;Kind=''}
   $applied=@{Path=$entry.Path;Name=$entry.Name;Exists=$true;Value=$entry.Value;Kind='DWord'}
   $later+=$applied.Clone();$script:registry[($entry.Path+'|'+$entry.Name)]=$applied
  }
  # Ignore malformed backups even if they are older.
  @{Role=$role;Time=[DateTime]'2025-01-01';Values=@(@{Path='SOFTWARE\Unrelated';Name='Unsafe';Exists=$false})} |
   Export-Clixml -LiteralPath (Join-Path $temp ('Politicas_'+$role+'_invalid.clixml'))
  @{Role=$role;Time=[DateTime]'2026-01-01';Values=$original} |
   Export-Clixml -LiteralPath (Join-Path $temp ('Politicas_'+$role+'_first.clixml'))
  @{Role=$role;Time=[DateTime]'2026-02-01';Values=$later} |
   Export-Clixml -LiteralPath (Join-Path $temp ('Politicas_'+$role+'_later.clixml'))
  # A subsequent configuration belongs to its owner and must be preserved.
  $last=$plan[-1];$script:registry[($last.Path+'|'+$last.Name)].Value=99
  $first=Import-Clixml -LiteralPath (Join-Path $temp ('Politicas_'+$role+'_first.clixml'))
  if(@($first.Values).Count -ne 4){throw 'Fixture sem quatro valores: '+@($first.Values).Count}
  $result=Restore-PrinterCompatibilityPolicies -Role $role -StateDirectory $temp
  if(-not $result.Success -or $result.Restored -ne 3 -or $result.Skipped -ne 1 -or
     $script:writes -ne 3 -or $script:restarts -ne 1 -or $result.SnapshotPath -notlike '*_first.clixml'){
   throw ('Restauração incorreta em {0}: restauradas={1}; preservadas={2}; escritas={3}; reinícios={4}; cópia={5}' -f $role,$result.Restored,$result.Skipped,$script:writes,$script:restarts,$result.SnapshotPath)
  }
  if(-not (Test-Path -LiteralPath $result.StatePath)){throw 'Restauração não salvou cópia antes de gravar'}
  $again=Restore-PrinterCompatibilityPolicies -Role $role -StateDirectory $temp
  if($again.Restored -ne 0 -or $script:writes -ne 3 -or $script:restarts -ne 1){throw 'Restauração repetida reiniciou/grava de novo'}
 }
 $script:writes=0;$script:restarts=0;$empty=Join-Path $temp 'Empty';[void][IO.Directory]::CreateDirectory($empty)
 $refused=$false
 try{Restore-PrinterCompatibilityPolicies -Role Client -StateDirectory $empty | Out-Null}catch{$refused=$true}
 if(-not $refused -or $script:writes -or $script:restarts){throw 'Restauração sem cópia fez alterações'}

 $script:rules=@{};$script:created=0;$script:updated=0;$script:bindings=@();$script:listener=$true
 function Get-NetAdapterBinding {param($ComponentID,$ErrorAction)
  return @([pscustomobject]@{Name='Ativo';Enabled=$false},[pscustomobject]@{Name='Desligado';Enabled=$false},[pscustomobject]@{Name='Pronto';Enabled=$true})
 }
 function Get-NetAdapter {param($Name,$ErrorAction) return [pscustomobject]@{Status=$(if($Name -eq 'Desligado'){'Disconnected'}else{'Up'})}}
 function Enable-NetAdapterBinding {param($Name,$ComponentID,$ErrorAction) $script:bindings+=$Name}
 function Get-NetFirewallRule {param($Name,$ErrorAction) return $script:rules[$Name]}
 function New-NetFirewallRule {param($Name,$DisplayName,$Direction,$Action,$Enabled,$Profile,$Protocol,$LocalPort,$Program,$RemoteAddress,$ErrorAction)
  $script:created++;$script:rules[$Name]=[pscustomobject]@{Enabled=$Enabled;Action=$Action;Port=$LocalPort;Program=$Program;Profile=$Profile;Direction=$Direction;Protocol=$Protocol}
 }
 function Set-NetFirewallRule {param($Name,$Direction,$Action,$Enabled,$Profile,$Protocol,$LocalPort,$Program,$RemoteAddress,$ErrorAction)
  $script:updated++;$script:rules[$Name]=[pscustomobject]@{Enabled=$Enabled;Action=$Action;Port=$LocalPort;Program=$Program;Profile=$Profile;Direction=$Direction;Protocol=$Protocol}
 }
 function Test-PrinterLocalSMBListener {return $script:listener}
 $network=Enable-PrinterHostNetworkAccess
 if(-not $network.Success -or $script:created -ne 3 -or $script:bindings.Count -ne 1 -or $script:bindings[0] -ne 'Ativo' -or $script:startup -ne 'Automatic'){throw 'Preparação explícita do host incompleta'}
 if($script:rules['AssistenteImpressoras-SMB-In'].Port -ne '445' -or
    $script:rules['AssistenteImpressoras-RPC-In'].Port -ne '135' -or
    $script:rules['AssistenteImpressoras-Spooler-In'].Port -ne 'RPC' -or
    $script:rules['AssistenteImpressoras-Spooler-In'].Program -notlike '*\System32\spoolsv.exe'){throw 'Regras SMB/RPC incorretas'}
 foreach($rule in $script:rules.Values){if($rule.Profile -ne 'Any' -or $rule.Direction -ne 'Inbound' -or $rule.Protocol -ne 'TCP'){throw 'Regra de host incorreta'}}
 Enable-PrinterHostNetworkAccess | Out-Null
 if($script:created -ne 3 -or $script:updated -ne 3){throw 'Preparação duplicou regras'}
 $script:listener=$false;$refused=$false
 try{Enable-PrinterHostNetworkAccess | Out-Null}catch{$refused=$true}
 if(-not $refused){throw 'Preparação aceitou porta SMB fechada como sucesso'}
}finally{
 $resolved=[IO.Path]::GetFullPath($temp)
 if($resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP)+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
'OK: restauração limitada às políticas conhecidas, estado anterior, idempotência e preparação explícita de SMB/RPC.'
