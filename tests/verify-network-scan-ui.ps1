$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root=Split-Path -Parent $PSScriptRoot
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src\AssistenteImpressoras.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0].Message}
foreach($name in @('Show-LoadingIndicator','Hide-LoadingIndicator','Update-StatusStrip','Invoke-AutoNetworkScan','Resolve-ComputerNameFromIpFast','Get-HostAndIpDisplay')){
 $definition=$ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true) | Select-Object -First 1
 if(-not $definition){throw 'Função ausente: '+$name}
 if($name -eq 'Show-LoadingIndicator'){
  . ([scriptblock]::Create($definition.Extent.Text.Replace('function Show-LoadingIndicator {','function Show-LoadingIndicatorReal {')))
 }else{. ([scriptblock]::Create($definition.Extent.Text))}
 if($name -in @('Invoke-AutoNetworkScan','Resolve-ComputerNameFromIpFast') -and
   $definition.Extent.Text -match 'Get-WmiObject'){throw 'Varredura ainda contém WMI sem limite'}
}
function Show-LoadingIndicator {param($Message,$Button)
 Show-LoadingIndicatorReal -Message $Message -Button $Button
 if($script:scenario -eq 'setup-error'){throw 'Fixture: falha depois de iniciar indicador'}
}
function Write-AppLog {param([Parameter(Mandatory=$true)][string]$Message,$Level) $script:lastLog=$Message}
function cmd.exe {return @()}
function Get-InstalledPrintersWmi {if($script:scenario -eq 'error'){throw 'Fixture: inventário recusado'};return @()}
function Get-CimInstance {param($ClassName,$Filter,$OperationTimeoutSec,$ErrorAction)
 if($OperationTimeoutSec -ne 4){throw 'Consulta local sem prazo'}
 if($ClassName -eq 'Win32_ComputerSystem'){return [pscustomobject]@{PartOfDomain=$false}}
 if($ClassName -eq 'Win32_Share' -and $script:scenario -notin @('empty','deadline')){return [pscustomobject]@{Name='Local'}}
}
function Get-WmiObject {$script:unboundedWmiCalls++;throw 'Não usar WMI remoto para descobrir nome'}
function Get-PrinterDiscoveryTargets {param($InitialIps) if($script:scenario -eq 'empty'){return @()};return @('192.0.2.7')}
function Test-OpenPrinterPorts {param($Addresses)
 $script:networkCalls++
 if(-not $pnlLoading.Visible -or -not $tmrSpinner.Enabled -or $pnlNetBottom.Enabled -or $pnlNetSearch.Enabled -or $btnToggleManual.Enabled){throw 'Estado de busca/ações incorreto'}
 if($script:scenario -eq 'reentrant'){Invoke-AutoNetworkScan}
 if($script:scenario -eq 'deadline'){Start-Sleep -Milliseconds 1100}
 return @{'192.0.2.7'=@{445=$true}}
}
function Invoke-NetViewSafe {param($Server) $script:netViewCalls++;return @('Rede    Print    Fixture','Rede    Print    Duplicada')}
function Test-PrinterShareInstalled {param($UNCPath,$InstalledPrinters) return $false}
function Get-NetBiosNameDirect {param($TargetIP) return ''}
function Resolve-PrinterEndpointAddresses {param($Server,$Mode) $script:boundedDnsCalls++;return @('192.0.2.7')}

foreach($script:scenario in @('success','empty','error','setup-error','reentrant','deadline')){
 $script:networkScanRunning=$false;$script:networkCalls=0;$script:netViewCalls=0;$script:unboundedWmiCalls=0;$script:boundedDnsCalls=0
 $script:ipHostCache=@{'192.0.2.7'='SERVIDOR'}
 $form=[Windows.Forms.Form]::new();$pnlLoading=[Windows.Forms.Panel]::new();$pnlLoading.Visible=$false
 $pbLoadingMarquee=[Windows.Forms.ProgressBar]::new();$pbLoadingMarquee.Style='Marquee';$pnlLoading.Controls.Add($pbLoadingMarquee)
 $tmrSpinner=[Windows.Forms.Timer]::new();$lblLoadingText=[Windows.Forms.Label]::new()
 $btnAutoScan=[Windows.Forms.Button]::new();$btnAutoScan.Text='Buscar na rede'
 $btnToggleManual=[Windows.Forms.Button]::new();$btnCancelConnection=[Windows.Forms.Button]::new()
 $lblScanStatus=[Windows.Forms.Label]::new();$statusLabel=[Windows.Forms.ToolStripStatusLabel]::new();$statusTag=[Windows.Forms.ToolStripStatusLabel]::new()
 $pnlNetBottom=[Windows.Forms.Panel]::new();$pnlNetSearch=[Windows.Forms.Panel]::new();$pnlNetSearch.Enabled=($script:scenario -ne 'reentrant')
 $searchEnabled=$pnlNetSearch.Enabled
 $dgvNetPrinters=[Windows.Forms.DataGridView]::new();$dgvNetPrinters.AllowUserToAddRows=$false
 foreach($column in @('ShareName','Type','UNC','Server','Status')){[void]$dgvNetPrinters.Columns.Add($column,$column)}
 try{
  Invoke-AutoNetworkScan -TimeoutSeconds $(if($script:scenario -eq 'deadline'){1}else{60})
  if($script:networkScanRunning -or $pnlLoading.Visible -or $tmrSpinner.Enabled -or $form.UseWaitCursor -or
     $pbLoadingMarquee.MarqueeAnimationSpeed -ne 0 -or $lblLoadingText.Text -or -not $btnAutoScan.Enabled -or
     $btnAutoScan.Text -ne 'Buscar na rede' -or $btnAutoScan.Tag -or $btnCancelConnection.Visible){throw 'Indicador/botão ficou carregando: '+$script:scenario}
  if(-not $pnlNetBottom.Enabled -or $pnlNetSearch.Enabled -ne $searchEnabled -or -not $btnToggleManual.Enabled){throw 'Ações não foram restauradas'}
  switch($script:scenario){
   success {if($dgvNetPrinters.Rows.Count -ne 2 -or $statusTag.Text -ne 'REDE: OK' -or $statusLabel.Text -notlike '*2 impressora*'){throw 'Conclusão não preservada'}}
   empty {if($dgvNetPrinters.Rows.Count -or $statusTag.Text -ne 'REDE: AVISO'){throw 'Busca vazia ficou ativa'}}
   error {if($statusTag.Text -ne 'REDE: ERRO' -or $script:networkCalls){throw 'Erro não concluiu indicador'}}
   setup-error {if($statusTag.Text -ne 'REDE: ERRO' -or $script:networkCalls){throw 'Erro de preparação deixou indicador aberto'}}
   reentrant {if($script:networkCalls -ne 1 -or $dgvNetPrinters.Rows.Count -ne 2){throw 'Varredura duplicada por reentrância'}}
   deadline {if($script:netViewCalls -or $statusTag.Text -ne 'REDE: PARCIAL'){throw 'Limite não encerrou busca preservando resultado'}}
  }
  if($script:unboundedWmiCalls){throw 'Descoberta usou WMI remoto'}
 }finally{
  foreach($control in @($tmrSpinner,$pnlLoading,$lblLoadingText,$btnAutoScan,$btnToggleManual,$btnCancelConnection,$lblScanStatus,$statusLabel,$statusTag,$pnlNetBottom,$pnlNetSearch,$dgvNetPrinters,$form)){$control.Dispose()}
 }
}
$script:ipHostCache=@{};$script:unboundedWmiCalls=0
[void](Resolve-ComputerNameFromIpFast -IpOrHost '192.0.2.77')
if($script:unboundedWmiCalls){throw 'Resolução de nome iniciou WMI remoto'}
'OK: seis cenários; indicador encerra em sucesso/erro/prazo, ações restauradas, sem reentrância ou WMI remoto.'
