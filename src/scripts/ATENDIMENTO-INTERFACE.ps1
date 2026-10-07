# Integração WinForms dos serviços de atendimento. Carregamento sem consultas.
function Initialize-PrinterSupportFunctions {
    if($script:supportFunctionsLoaded){return}
    $folder=if($PrinterConnectionPath){Split-Path -Parent $PrinterConnectionPath}else{Join-Path $PSScriptRoot 'scripts'}
    if(-not(Test-Path -LiteralPath (Join-Path $folder 'IMPRESSAO-COMUM.ps1'))){$folder=$PSScriptRoot}
    . (Join-Path $folder 'IMPRESSAO-COMUM.ps1')
    . (Join-Path $folder 'ATENDIMENTO-COMUM.ps1')
    # Dot-sourced definitions belong to this function scope; publish them in script scope.
    foreach($file in @('IMPRESSAO-COMUM.ps1','ATENDIMENTO-COMUM.ps1')){
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $folder $file),[ref]$tokens,[ref]$errors)
        if($errors.Count){throw $errors[0].Message}
        foreach($fn in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [Management.Automation.Language.NamedBlockAst]},$true)){
            Set-Item -Path ('Function:script:'+ $fn.Name) -Value ([scriptblock]::Create($fn.Body.Extent.Text.Substring(1,$fn.Body.Extent.Text.Length-2)))
        }
    }
    $script:supportFunctionsLoaded=$true
}
function Save-PrinterSupportRecord {
    param([string]$Action,[string]$Destination,$Result)
    try{
        Initialize-PrinterSupportFunctions
        if(-not $script:supportDataDirectory){$script:supportDataDirectory=Join-Path $LogsDir ([IO.Path]::GetFileNameWithoutExtension($global:LogFilePath)+'_Dados');[void][IO.Directory]::CreateDirectory($script:supportDataDirectory)}
        $script:supportRecordCounter++
    $record=[ordered]@{Action=$Action;Destination=$Destination;Timestamp=(Get-Date).ToString('o');AppVersion='1.11.0';IdentityMode=$Result.IdentityMode;NetworkUser=$Result.NetworkUser;Result=$Result}
        $safe=ConvertTo-SupportSafeData $record
        $file=Join-Path $script:supportDataDirectory ('{0:D4}_{1}.json' -f $script:supportRecordCounter,[Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($file,($safe|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))
        $script:lastSupportRecord=$safe
        if($Action -eq 'Connection'){$script:lastPrinterConnectionRecord=$safe}
        Write-AppLog -Message ("Atendimento $Action | destino=$Destination | fila=$($Result.QueueName) | sucesso=$($Result.Success) | documento=$($Result.DocumentName) | JobId=$($Result.JobId) | etapa=$($Result.JobState) | servidor=$($Result.ServerObservation) | papel confirmado=$($Result.PhysicalPrintConfirmed)") -Level INFO
    }catch{Write-AppLog -Message ('Registro estruturado indisponível: '+$_.Exception.Message) -Level AVISO}
}
function Invoke-PrinterSupportOperation {
    param([hashtable]$Request,[int]$TimeoutSeconds=40,[pscredential]$NetworkCredential,[string]$CredentialServer='')
    if($global:SimulationMode -and $Request.Action -notin @('Snapshot','Compare','Bundle')){return @{Success=$true;Simulated=$true;Message='Simulação: nenhuma alteração ou impressão executada.'}}
    if($script:supportBusy){return @{Success=$false;Message='Aguarde a operação de atendimento em andamento.'}}
    $requestPath=Join-Path $env:TEMP ('PrinterSupportRequest_'+[Guid]::NewGuid().ToString('N')+'.xml')
    $controls=New-Object Collections.ArrayList;$previousCancel=$script:cancelPrinterConnection;$previousVisible=$btnCancelConnection.Visible
    try{
        $script:supportBusy=$true;$script:cancelPrinterConnection=$false;$btnCancelConnection.Visible=$true
        $buttons=New-Object Collections.ArrayList;$pending=New-Object Collections.Stack;$pending.Push($form)
        while($pending.Count){$parent=$pending.Pop();foreach($child in $parent.Controls){if($child -is [Windows.Forms.Button] -and $child -ne $btnCancelConnection){[void]$buttons.Add($child)};if($child.HasChildren){$pending.Push($child)}}}
        foreach($control in @($buttons.ToArray())+@($chkNetWin11,$cmbNetEndpointMode,$dgvNetPrinters)){
            if($control){[void]$controls.Add(@{Control=$control;Enabled=$control.Enabled});$control.Enabled=$false}
        }
        $Request|Export-Clixml -LiteralPath $requestPath -Force
        $result=Invoke-BoundedPrinterAttempt -UNCPath '' -Method Operation -LocalPortRequestPath $requestPath -TimeoutSeconds $TimeoutSeconds -NetworkCredential $NetworkCredential -CredentialServer $CredentialServer
        if(($result.Cancelled -or $result.TimedOut) -and $Request.Action -eq 'Maintenance' -and @($Request.Actions|Where-Object {$_ -in @('Purge','Restart')}).Count){
            try{$service=Get-Service Spooler -ErrorAction Stop;if($service.Status -ne 'Running'){Start-Service Spooler -ErrorAction Stop;$service.WaitForStatus('Running',[TimeSpan]::FromSeconds(10))};$result.Message+=' Spooler confirmado em execução após a interrupção.'}catch{$result.Message+=' Não foi possível recuperar o Spooler: '+$_.Exception.Message}
        }
        $result.IdentityMode=if($NetworkCredential){'Conta alternativa informada'}else{'Sessão atual do Windows'}
        $result.NetworkUser=if($NetworkCredential){$NetworkCredential.UserName}else{[Security.Principal.WindowsIdentity]::GetCurrent().Name}
        Save-PrinterSupportRecord -Action $Request.Action -Destination $(if($Request.QueueName){$Request.QueueName}else{$Request.Server}) -Result $result
        return $result
    }finally{
        foreach($state in $controls){if(-not $state.Control.IsDisposed){$state.Control.Enabled=$state.Enabled}}
        $script:supportBusy=$false;$script:cancelPrinterConnection=$previousCancel;$btnCancelConnection.Visible=$previousVisible
        Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
    }
}
function Get-PrinterSupportQueueUNC {
    param([string]$QueueName)
    if($QueueName -match '^\\\\[^\\]+\\[^\\]+$'){return $QueueName}
    try{$printer=Get-Printer -ErrorAction Stop|Where-Object Name -ieq $QueueName|Select-Object -First 1;if($printer.PortName -match '^\\\\[^\\]+\\[^\\]+$'){return [string]$printer.PortName}}catch{}
    return ''
}
function Format-PrinterSupportSummary {
    param($Result)
    $lines=New-Object Collections.ArrayList
    $labels=@{QueueName='Fila';ConnectedUNC='Fila registrada';PortUNC='Compartilhamento';PortName='Porta';DriverName='Driver';Level='Método de conexão';QueueInstalled='Fila confirmada no Windows';DocumentName='Documento do teste';JobId='ID do documento no cliente';JobState='Estado do documento';ServerObservation='Consulta ao servidor';ServerJobObserved='Documento observado no servidor';PhysicalPrintConfirmed='Impressão no papel confirmada';Stage='Etapa';Code='Código'}
    foreach($field in @('QueueName','ConnectedUNC','PortUNC','PortName','DriverName','Level','QueueInstalled','DocumentName','JobId','JobState','ServerObservation','ServerJobObserved','PhysicalPrintConfirmed','Stage','Code')){
        if($Result.Contains($field) -or ($Result -is [hashtable] -and $Result.ContainsKey($field))){[void]$lines.Add($labels[$field]+': '+[string]$Result[$field])}
    }
    if($Result.Message){[void]$lines.Add([string]$Result.Message)}
    foreach($action in @($Result.Actions)){if($action){[void]$lines.Add(($action.QueueName+' '+$action.Action+': '+$action.Message).Trim());foreach($item in @($action.Actions)){[void]$lines.Add($item.QueueName+': '+$item.Message)}}}
    return ($lines -join [Environment]::NewLine)
}
function Show-PrinterSupportDetails {
    param([string]$Title,[string]$Text)
    $dialog=[Windows.Forms.Form]::new();$dialog.Text=$Title;$dialog.Size=[Drawing.Size]::new(760,510);$dialog.StartPosition='CenterParent';$dialog.Font=[Drawing.Font]::new('Segoe UI',9)
    $box=[Windows.Forms.TextBox]::new();$box.Multiline=$true;$box.ReadOnly=$true;$box.ScrollBars='Both';$box.WordWrap=$false;$box.Dock='Fill';$box.Text=$Text;$box.Font=[Drawing.Font]::new('Consolas',9)
    $bar=[Windows.Forms.FlowLayoutPanel]::new();$bar.Dock='Bottom';$bar.Height=44
    $copy=[Windows.Forms.Button]::new();$copy.Text='Copiar resumo';$copy.Size=[Drawing.Size]::new(130,30)
    $copy.Add_Click({[Windows.Forms.Clipboard]::SetText($box.Text)}.GetNewClosure())
    $close=[Windows.Forms.Button]::new();$close.Text='Fechar';$close.DialogResult='OK';$close.Size=[Drawing.Size]::new(100,30);$dialog.AcceptButton=$close
    $bar.Controls.AddRange(@($copy,$close));$dialog.Controls.Add($box);$dialog.Controls.Add($bar)
    try{[void]$dialog.ShowDialog($form)}finally{$dialog.Dispose()}
}
function Invoke-TrackedPrinterTest {
    param([string]$QueueName,[string]$RawPayload='',[switch]$ShowResult)
    if($global:SimulationMode){[Windows.Forms.MessageBox]::Show($form,'Simulação: nenhuma página de teste enviada.','Simulação')|Out-Null;return @{Success=$true;Simulated=$true}}
    $unc=Get-PrinterSupportQueueUNC $QueueName;$server=if($unc){$unc.Substring(2).Split([char]92)[0]}else{''}
    $credential=if($server -and $script:authenticatedPrinterServer -ieq $server){$script:authenticatedPrinterCredential}else{$null}
    $request=@{Action='TestPage';QueueName=$QueueName;UNCPath=$unc}
    if($RawPayload){$request.Action='TestRaw';$request.RawBase64=[Convert]::ToBase64String([Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes($RawPayload))}
    $result=Invoke-PrinterSupportOperation -Request $request -NetworkCredential $credential -CredentialServer $server
    if($ShowResult){Show-PrinterTestObservation -QueueName $QueueName -Result $result}
    return $result
}
function Show-PrinterTestObservation {
    param([string]$QueueName,[Collections.IDictionary]$Result)
    if($Result.JobAccepted -and -not $Result.PhysicalPrintObservation){
        $answer=[Windows.Forms.MessageBox]::Show($form,"A página enviada agora para '$QueueName' saiu no papel?`n`n$($Result.Message)`n`nSim = impressão confirmada. Não = não saiu. Cancelar = não foi possível verificar.",'Confirmar impressão física','YesNoCancel','Question')
        $Result.PhysicalPrintConfirmed=($answer -eq 'Yes');$Result.PhysicalPrintObservation=if($answer -eq 'Yes'){'ConfirmedByUser'}elseif($answer -eq 'No'){'NotPrintedByUser'}else{'Unknown'}
        Save-PrinterSupportRecord -Action 'PrintConfirmation' -Destination $QueueName -Result $Result
    }
    Show-PrinterSupportDetails -Title 'Resultado do teste de impressão' -Text (Format-PrinterSupportSummary $Result)
}
function Initialize-PrinterSupportToolsUI {
    $queueBar=[Windows.Forms.FlowLayoutPanel]::new();$queueBar.Dock='Bottom';$queueBar.Height=44;$queueBar.Padding=[Windows.Forms.Padding]::new(6)
    $script:cmbSupportQueue=[Windows.Forms.ComboBox]::new();$script:cmbSupportQueue.DropDownStyle='DropDownList';$script:cmbSupportQueue.Width=300
    $script:btnSupportCancelJob=[Windows.Forms.Button]::new();$script:btnSupportCancelJob.Text='Cancelar documento selecionado';$script:btnSupportCancelJob.Size=[Drawing.Size]::new(225,30)
    $script:btnSupportClearQueue=[Windows.Forms.Button]::new();$script:btnSupportClearQueue.Text='Limpar somente esta impressora';$script:btnSupportClearQueue.Size=[Drawing.Size]::new(225,30)
    $queueBar.Controls.AddRange(@($script:cmbSupportQueue,$script:btnSupportCancelJob,$script:btnSupportClearQueue));$pnlQueueGroup.Controls.Add($queueBar);$queueBar.SendToBack();$dgvQueue.BringToFront();$pnlQueueGroup.Height=200
    $tab6.AutoScroll=$true;$tab6.AutoScrollMinSize=[Drawing.Size]::new(0,535)
    $dgvQueue.Add_SelectionChanged({if($dgvQueue.SelectedRows.Count){$script:cmbSupportQueue.SelectedItem=[string]$dgvQueue.SelectedRows[0].Cells['Printer'].Value}})
    $script:btnSupportCancelJob.Add_Click({
        if(-not $dgvQueue.SelectedRows.Count){return}
        $row=$dgvQueue.SelectedRows[0];$queue=[string]$row.Cells['Printer'].Value;$id=[int]$row.Cells['JobId'].Value;$document=[string]$row.Cells['Document'].Value
        if([Windows.Forms.MessageBox]::Show($form,"Cancelar somente '$document', ID $id, em '$queue'?",'Cancelar documento','YesNo','Question') -ne 'Yes'){return}
        try{Show-LoadingIndicator 'Cancelando documento...' -Button $script:btnSupportCancelJob;$r=Invoke-PrinterSupportOperation @{Action='RemoveJobs';QueueName=$queue;JobIds=@($id);DocumentName=$document};Show-PrinterSupportDetails 'Cancelamento do documento' (Format-PrinterSupportSummary $r);Update-SpoolTabStatus}finally{Hide-LoadingIndicator -Button $script:btnSupportCancelJob}
    })
    $script:btnSupportClearQueue.Add_Click({
        $queue=[string]$script:cmbSupportQueue.SelectedItem;if(-not $queue){return}
        if([Windows.Forms.MessageBox]::Show($form,"Cancelar os documentos existentes somente na fila '$queue'?`nOutras impressoras serão preservadas.",'Limpar impressora selecionada','YesNo','Question') -ne 'Yes'){return}
        try{Show-LoadingIndicator 'Limpando a fila selecionada...' -Button $script:btnSupportClearQueue;$r=Invoke-PrinterSupportOperation @{Action='RemoveJobs';QueueName=$queue;All=$true};Show-PrinterSupportDetails 'Limpeza da fila selecionada' (Format-PrinterSupportSummary $r);Update-SpoolTabStatus}finally{Hide-LoadingIndicator -Button $script:btnSupportClearQueue}
    })
    $script:btnSupportSnapshot=[Windows.Forms.Button]::new();$script:btnSupportSnapshot.Text='Salvar diagnóstico deste PC';$script:btnSupportSnapshot.Size=[Drawing.Size]::new(195,32)
    $script:btnSupportCompare=[Windows.Forms.Button]::new();$script:btnSupportCompare.Text='Comparar diagnóstico do host';$script:btnSupportCompare.Size=[Drawing.Size]::new(200,32)
    $summary=[Windows.Forms.Button]::new();$summary.Text='Resumo da última operação';$summary.Size=[Drawing.Size]::new(190,32)
    $summary.Add_Click({if($script:lastSupportRecord){Show-PrinterSupportDetails 'Resumo do atendimento' ("$($script:lastSupportRecord.Timestamp)`n$($script:lastSupportRecord.Action)`nDestino: $($script:lastSupportRecord.Destination)`nIdentidade: $($script:lastSupportRecord.IdentityMode) $($script:lastSupportRecord.NetworkUser)`n`n"+(Format-PrinterSupportSummary $script:lastSupportRecord.Result))}else{[Windows.Forms.MessageBox]::Show($form,'Ainda não há operação registrada nesta sessão.','Resumo')|Out-Null}})
    $script:btnSupportSnapshot.Add_Click({
        $picker=[Windows.Forms.SaveFileDialog]::new();$picker.Filter='Diagnóstico (*.json)|*.json';$picker.FileName='Diagnostico_'+$env:COMPUTERNAME+'.json'
        try{if($picker.ShowDialog($form) -ne 'OK'){return};Show-LoadingIndicator 'Coletando diagnóstico deste PC...' -Button $script:btnSupportSnapshot;$r=Invoke-PrinterSupportOperation @{Action='Snapshot'} -TimeoutSeconds 45;if(-not $r.Success){throw $r.Message};[IO.File]::WriteAllText($picker.FileName,($r.Snapshot|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true));[Windows.Forms.MessageBox]::Show($form,'Diagnóstico salvo. No cliente, use Comparar diagnóstico do host e selecione este JSON.','Diagnóstico')|Out-Null}catch{Show-PrinterSupportDetails 'Falha ao salvar diagnóstico' $_.Exception.Message}finally{Hide-LoadingIndicator -Button $script:btnSupportSnapshot;$picker.Dispose()}
    })
    $script:btnSupportCompare.Add_Click({
        $picker=[Windows.Forms.OpenFileDialog]::new();$picker.Filter='Diagnóstico do host (*.json)|*.json'
        try{if($picker.ShowDialog($form) -ne 'OK'){return};Show-LoadingIndicator 'Comparando host e este computador...' -Button $script:btnSupportCompare;$r=Invoke-PrinterSupportOperation @{Action='Compare';ReportPath=$picker.FileName} -TimeoutSeconds 45;Show-PrinterSupportDetails 'Comparativo host e cliente' $r.Message}finally{Hide-LoadingIndicator -Button $script:btnSupportCompare;$picker.Dispose()}
    })
    $existing=@($pnlLogsTop.Controls);$pnlLogsTop.Controls.Clear();$pnlLogsTop.Height=96
    $tools=[Windows.Forms.FlowLayoutPanel]::new();$tools.Dock='Fill';$tools.WrapContents=$true;$tools.AutoScroll=$true;$tools.Padding=[Windows.Forms.Padding]::new(6)
    $btnExportReport.Text='Exportar atendimento (ZIP)';$btnExportReport.Width=185
    foreach($button in @($existing)+@($script:btnSupportSnapshot,$script:btnSupportCompare,$summary)){$button.Margin=[Windows.Forms.Padding]::new(3);$tools.Controls.Add($button)}
    $pnlLogsTop.Controls.Add($tools)
    if(Get-Command Set-PrinterControlsTheme -ErrorAction SilentlyContinue){Set-PrinterControlsTheme $queueBar;Set-PrinterControlsTheme $tools}
    $btnQuickPurge.Text='Limpeza global (todas as filas)';$btnQuickPurge.Width=270
    $script:cmbSupportQueue.AccessibleName='Impressora para limpeza individual'
}
