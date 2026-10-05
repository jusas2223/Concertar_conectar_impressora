$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$source=[IO.File]::ReadAllText((Join-Path $root 'src\AssistenteImpressoras.ps1'))
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$t,[ref]$e)
if($e.Count){throw $e[0].Message}
$fn=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-SelectedPrinterTab'},$true)|Select-Object -First 1
if(-not $fn){throw 'Inicialização sob demanda ausente'}
. ([scriptblock]::Create($fn.Extent.Text))
$tab1=[pscustomobject]@{Name='Diagnosis'};$tab2=[pscustomobject]@{Name='Local'}
$tab5=[pscustomobject]@{Name='IP'};$tab6=[pscustomobject]@{Name='Spool'};$tab7=[pscustomobject]@{Name='RDP'}
$tabControl=[pscustomobject]@{SelectedTab=$tab1}
$script:printerTabDataLoaded=@{};$script:uiShown=$false
$script:localCalls=0;$script:driverCalls=0;$script:spoolCalls=0;$script:rdpCalls=0
function Refresh-PrintersGrid {$script:localCalls++;Initialize-SelectedPrinterTab}
function Populate-DriversList {$script:driverCalls++;Initialize-SelectedPrinterTab}
function Update-SpoolTabStatus {$script:spoolCalls++}
function Update-RDPDiagnostics {$script:rdpCalls++}
foreach($page in @($tab1,$tab2,$tab5,$tab6,$tab7)){$tabControl.SelectedTab=$page;Initialize-SelectedPrinterTab}
if($script:localCalls -or $script:driverCalls -or $script:spoolCalls -or $script:rdpCalls){throw 'Consultas executadas antes da janela pronta'}
$script:uiShown=$true;$tabControl.SelectedTab=$tab1;Initialize-SelectedPrinterTab
if($script:localCalls -or $script:driverCalls){throw 'Diagnóstico inicial carregou dados de outra aba'}
foreach($page in @($tab2,$tab5,$tab1,$tab2,$tab5)){$tabControl.SelectedTab=$page;Initialize-SelectedPrinterTab}
if($script:localCalls -ne 1 -or $script:driverCalls -ne 1){throw 'Primeira visita não carregou dados, ou reentrância repetiu consultas'}
foreach($page in @($tab6,$tab7)){$tabControl.SelectedTab=$page;Initialize-SelectedPrinterTab}
if($script:spoolCalls -ne 1 -or $script:rdpCalls -ne 1){throw 'Abas de serviço/sessão deixaram de carregar'}
$script:printerTabDataLoaded.Local=$false;$tabControl.SelectedTab=$tab2
function Refresh-PrintersGrid {throw 'Fixture: consulta recusada'}
try{Initialize-SelectedPrinterTab;throw 'Erro não propagado'}catch{if($_.Exception.Message -ne 'Fixture: consulta recusada'){throw}}
if($script:printerTabDataLoaded.Local){throw 'Falha de consulta bloqueou nova tentativa'}
$shown=[regex]::Match($source,'(?s)\$form\.Add_Shown\(\{(?<body>.*?)\r?\n\}\)')
if(-not $shown.Success -or $shown.Groups['body'].Value -match 'Refresh-PrintersGrid|Populate-DriversList|Get-WmiObject|Get-CimInstance|Invoke-AutoNetworkScan'){throw 'Abertura executa consultas lentas'}
'OK: zero consultas antes de abrir; dados por aba, sem repetição/reentrância e com recuperação de falha.'
