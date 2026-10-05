$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$t=$null;$e=$null;$path=Join-Path $root 'src\AssistenteImpressoras.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)
if($e.Count){throw $e[0].Message}
foreach($name in @('Resolve-PrinterConnectionEndpoint','Use-PrinterCredentialForEndpoint','Connect-PrinterUsingAvailableSession')){
 $fn=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)|Select-Object -First 1
 . ([scriptblock]::Create($fn.Extent.Text))
}
function Resolve-PrinterEndpointAddresses {
 param($Server,$Mode)
 $script:dnsCalls++
 if($Mode -eq 'Hostname'){return $script:reverseName}
 return $script:forwardIps
}
function Write-AppLog {param($Message,$Level)}
$script:dnsCalls=0;$script:forwardIps=@('192.0.2.11');$script:reverseName='SERVIDOR'
function Assert-Path($Result,[string]$Expected){
 if(-not $Result.Success -or $Result.UNCPath -cne $Expected -or $Result.ShareName -cne 'Fila (1)'){throw "Destino incorreto: $($Result.UNCPath), esperado $Expected"}
}
Assert-Path (Resolve-PrinterConnectionEndpoint -UNCPath '\\SERVIDOR\Fila (1)' -ServerDisplay 'SERVIDOR \ 192.0.2.10') '\\SERVIDOR\Fila (1)'
if($script:dnsCalls){throw 'Hostname existente provocou resolução desnecessária'}
Assert-Path (Resolve-PrinterConnectionEndpoint -UNCPath '\\192.0.2.10\Fila (1)' -ServerDisplay 'SERVIDOR \ 192.0.2.10') '\\SERVIDOR\Fila (1)'
Assert-Path (Resolve-PrinterConnectionEndpoint -UNCPath '\\192.0.2.10\Fila (1)' -Mode IP) '\\192.0.2.10\Fila (1)'
Assert-Path (Resolve-PrinterConnectionEndpoint -UNCPath '\\SERVIDOR\Fila (1)' -ServerDisplay 'SERVIDOR \ 192.0.2.10' -Mode IP) '\\192.0.2.11\Fila (1)'
Assert-Path (Resolve-PrinterConnectionEndpoint -UNCPath '\\192.0.2.10\Fila (1)') '\\SERVIDOR\Fila (1)'
Assert-Path (Resolve-PrinterConnectionEndpoint -UNCPath '\\servidor.exemplo.local\Fila (1)') '\\servidor.exemplo.local\Fila (1)'
$script:forwardIps=@('192.0.2.12','192.0.2.10')
Assert-Path (Resolve-PrinterConnectionEndpoint -UNCPath '\\SERVIDOR\Fila (1)' -ServerDisplay 'SERVIDOR \ 192.0.2.10' -Mode IP) '\\192.0.2.10\Fila (1)'
$script:forwardIps=@();$script:reverseName=''
Assert-Path (Resolve-PrinterConnectionEndpoint -UNCPath '\\SERVIDOR\Fila (1)' -ServerDisplay 'SERVIDOR \ 192.0.2.10' -Mode IP) '\\192.0.2.10\Fila (1)'
foreach($case in @(
 @{UNCPath='\\192.0.2.10\Fila (1)';Mode='Hostname'},
 @{UNCPath='\\SERVIDOR\Fila (1)';Mode='IP'},
 @{UNCPath='\\999.0.2.10\Fila (1)';Mode='IP'},
 @{UNCPath='\\SERVIDOR\Fila (1)\extra';Mode='Hostname'},
 @{UNCPath='\\SER VIDO R\Fila (1)';Mode='Hostname'}
)){
 $r=Resolve-PrinterConnectionEndpoint @case
 if($r.Success){throw 'Falha de resolução foi aceita ou trocou de modo silenciosamente'}
}
$before=$script:dnsCalls
Assert-Path (Resolve-PrinterConnectionEndpoint -UNCPath '\\SERVIDOR\Fila (1)' -ServerDisplay 'SERVIDOR \ 192.0.2.10' -Mode IP -Preview) '\\192.0.2.10\Fila (1)'
$preview=Resolve-PrinterConnectionEndpoint -UNCPath '\\192.0.2.10\Fila (1)' -Preview
if($preview.Success -or $script:dnsCalls -ne $before){throw 'Preview resolveu rede ou aceitou hostname desconhecido'}
# Identidade de rede acompanha a escolha e só usa aliases do mesmo registro.
$script:authenticatedPrinterServer='SERVIDOR'
$script:authenticatedPrinterCredential=New-Object Management.Automation.PSCredential('SERVIDOR\conta',(ConvertTo-SecureString 'Fixture-only' -AsPlainText -Force))
$credential=$script:authenticatedPrinterCredential
$endpoint=Resolve-PrinterConnectionEndpoint -UNCPath '\\SERVIDOR\Fila (1)' -ServerDisplay 'SERVIDOR \ 192.0.2.10' -Mode IP
function Connect-UNCPrinterSafe {
 param($UNCPath,$AlternateHost)
 if($UNCPath -cne '\\192.0.2.10\Fila (1)' -or $script:authenticatedPrinterServer -ne '192.0.2.10' -or $script:authenticatedPrinterCredential -ne $credential){throw 'Conexão/credencial não usou IP selecionado'}
 return @{Success=$true;QueueInstalled=$true}
}
$r=Connect-PrinterUsingAvailableSession -UNCPath $endpoint.UNCPath -CredentialServerAliases $endpoint.Aliases -RequestCredential {throw 'Conta repetida ao trocar nome por IP'}
if(-not $r.Success){throw 'Conexão com IP falhou'}
Use-PrinterCredentialForEndpoint -Server OUTRO -Aliases @('OUTRO','192.0.2.99')
if($script:authenticatedPrinterServer -ne '192.0.2.10'){throw 'Credencial foi aplicada a outro servidor'}
Use-PrinterCredentialForEndpoint -Server SERVIDOR -Aliases $endpoint.Aliases
if($script:authenticatedPrinterServer -ne 'SERVIDOR'){throw 'Conta não foi reutilizada no retorno ao hostname'}
'OK: hostname padrão, IP explícito/atual, DNS limitado, preview sem rede e credenciais no mesmo destino.'
