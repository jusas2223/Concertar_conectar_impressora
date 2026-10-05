# Native WinForms presentation; no browser runtime or image assets.
function Set-PrinterControlsTheme {
    param([System.Windows.Forms.Control]$Root)
    $ink=[Drawing.ColorTranslator]::FromHtml('#223047')
    $line=[Drawing.ColorTranslator]::FromHtml('#DCE3EC')
    $paper=[Drawing.Color]::White
    $soft=[Drawing.ColorTranslator]::FromHtml('#F5F7FB')
    foreach($control in $Root.Controls) {
        if($control -is [Windows.Forms.Button]) {
            $control.FlatStyle='Flat'
            $control.FlatAppearance.BorderSize=1
            $control.FlatAppearance.BorderColor=$line
            $control.Cursor=[Windows.Forms.Cursors]::Hand
            $control.AccessibleName=$control.Text
            if($control.ForeColor -ne [Drawing.Color]::White) {
                $control.BackColor=$paper
                $control.ForeColor=$ink
                $control.FlatAppearance.MouseOverBackColor=[Drawing.ColorTranslator]::FromHtml('#EDF3FB')
            }
        } elseif($control -is [Windows.Forms.DataGridView]) {
            $control.BackgroundColor=$paper
            $control.BorderStyle='None'
            $control.GridColor=$line
            $control.CellBorderStyle='SingleHorizontal'
            $control.RowHeadersVisible=$false
            $control.EnableHeadersVisualStyles=$false
            $control.ColumnHeadersBorderStyle='None'
            $control.ColumnHeadersHeightSizeMode='DisableResizing'
            $control.ColumnHeadersHeight=38
            $control.ColumnHeadersDefaultCellStyle.BackColor=$soft
            $control.ColumnHeadersDefaultCellStyle.ForeColor=$ink
            $control.ColumnHeadersDefaultCellStyle.Font=New-Object Drawing.Font('Segoe UI',9,[Drawing.FontStyle]::Bold)
            $control.DefaultCellStyle.ForeColor=$ink
            $control.DefaultCellStyle.SelectionBackColor=[Drawing.ColorTranslator]::FromHtml('#DFEBFC')
            $control.DefaultCellStyle.SelectionForeColor=[Drawing.ColorTranslator]::FromHtml('#123F78')
            $control.DefaultCellStyle.Padding=New-Object Windows.Forms.Padding(6,3,6,3)
            $control.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.ColorTranslator]::FromHtml('#FAFBFD')
            $control.RowTemplate.Height=32
            foreach($row in $control.Rows){$row.Height=32}
        } elseif($control -is [Windows.Forms.TabPage]) {
            $control.BackColor=$paper
        } elseif($control -is [Windows.Forms.GroupBox]) {
            $control.ForeColor=$ink
        }
        if($control.HasChildren){Set-PrinterControlsTheme -Root $control}
    }
}

function Set-PrinterAppLayout {
    $form.SuspendLayout()
    $working=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Size=New-Object Drawing.Size([Math]::Min(1280,$working.Width),[Math]::Min(780,$working.Height))
    $form.MinimumSize=New-Object Drawing.Size(1180,620)
    $pnlHeader.Height=80
    $pnlHeader.BackColor=[Drawing.ColorTranslator]::FromHtml('#14243B')
    $lblTitle.Text='Assistente de Impressoras'
    $lblTitle.Font=New-Object Drawing.Font('Segoe UI',17,[Drawing.FontStyle]::Bold)
    $lblTitle.Location=New-Object Drawing.Point(22,12)
    $lblSubTitle.Location=New-Object Drawing.Point(24,47)
    $lblSubTitle.ForeColor=[Drawing.ColorTranslator]::FromHtml('#B7C8DD')
    $chkSimulation.Text='Modo diagnóstico (sem alterações)'
    $chkSimulation.ForeColor=[Drawing.ColorTranslator]::FromHtml('#CEE2FC')
    $chkSimulation.Top=28
    $chkSimulation.Left=$form.ClientSize.Width-$chkSimulation.Width-24
    $statusStrip.BackColor=[Drawing.ColorTranslator]::FromHtml('#F3F6FB')
    Set-PrinterControlsTheme -Root $form

    $body=New-Object Windows.Forms.Panel
    $body.Dock='Fill'
    $body.BackColor=[Drawing.ColorTranslator]::FromHtml('#F3F6FB')
    $form.Controls.Remove($tabControl)
    $form.Controls.Add($body)
    $body.BringToFront()
    $nav=New-Object Windows.Forms.Panel
    $nav.Dock='Left';$nav.Width=194;$nav.BackColor=[Drawing.Color]::White
    $workspace=New-Object Windows.Forms.Panel
    $workspace.Dock='Fill';$workspace.Padding=New-Object Windows.Forms.Padding(14,10,14,12)
    $body.Controls.Add($workspace);$body.Controls.Add($nav)
    $workspace.BringToFront()
    $navTitle=New-Object Windows.Forms.Label
    $navTitle.Text='FERRAMENTAS';$navTitle.Location=New-Object Drawing.Point(18,20)
    $navTitle.AutoSize=$true;$navTitle.ForeColor=[Drawing.ColorTranslator]::FromHtml('#8390A4')
    $navTitle.Font=New-Object Drawing.Font('Segoe UI',8,[Drawing.FontStyle]::Bold)
    $nav.Controls.Add($navTitle)
    $pageHeader=New-Object Windows.Forms.Panel
    $pageHeader.Dock='Top';$pageHeader.Height=62
    $pageTitle=New-Object Windows.Forms.Label
    $pageTitle.Location=New-Object Drawing.Point(0,2);$pageTitle.AutoSize=$true
    $pageTitle.Font=New-Object Drawing.Font('Segoe UI',15,[Drawing.FontStyle]::Bold)
    $pageTitle.ForeColor=[Drawing.ColorTranslator]::FromHtml('#223047')
    $pageHint=New-Object Windows.Forms.Label
    $pageHint.Location=New-Object Drawing.Point(1,32);$pageHint.AutoSize=$true
    $pageHint.ForeColor=[Drawing.ColorTranslator]::FromHtml('#63738B')
    $pageHeader.Controls.Add($pageTitle);$pageHeader.Controls.Add($pageHint)
    $canvas=New-Object Windows.Forms.Panel
    $canvas.Dock='Fill';$canvas.BackColor=[Drawing.Color]::White
    $workspace.Controls.Add($canvas);$workspace.Controls.Add($pageHeader);$canvas.BringToFront()
    $tabControl.Dock='None';$tabControl.TabStop=$false
    $canvas.Controls.Add($tabControl)
    # Clip the legacy tab strip; navigation still selects the same TabPages and events.
    $tc=$tabControl;$hostPanel=$canvas
    $fit={ $tc.SetBounds(-4,-25,$hostPanel.ClientSize.Width+8,$hostPanel.ClientSize.Height+29) }.GetNewClosure()
    $canvas.Add_Resize($fit);& $fit
    $items=New-Object Collections.ArrayList
    $position=52
    foreach($page in $tabControl.TabPages) {
        $title=$page.Text -replace '^\d+\.\s*',''
        $hint='Escolha uma ação abaixo para começar.'
        if($page -eq $tab1){$title='Diagnóstico';$hint='Confira o computador, a rede e os serviços de impressão.'}
        if($page -eq $tab2){$title='Impressoras locais';$hint='Gerencie as filas instaladas e prepare o driver para outros computadores.'}
        if($page -eq $tab3){$title='Impressoras na rede';$hint='Encontre o servidor, autentique a conta e conecte a impressora.'}
        if($page -eq $tab4){$title='Instalar por caminho';$hint='Conecte pelo compartilhamento no formato \\SERVIDOR\Impressora.'}
        if($page -eq $tab5){$title='Instalar por IP';$hint='Use o endereço de uma impressora com conexão própria à rede.'}
        if($page -eq $tab6){$title='Fila e serviços';$hint='Confira trabalhos pendentes e o serviço Spooler.'}
        if($page -eq $tab7){$title='Acesso remoto';$hint='Verifique a sessão remota e o redirecionamento de impressoras.'}
        if($page -eq $tab8){$title='Relatórios e logs';$hint='Consulte o histórico desta sessão e exporte o relatório.'}
        $button=New-Object Windows.Forms.Button
        $button.Text=$title;$button.TextAlign='MiddleLeft';$button.Padding=New-Object Windows.Forms.Padding(12,0,0,0)
        $button.Size=New-Object Drawing.Size(174,42);$button.Location=New-Object Drawing.Point(10,$position)
        $button.FlatStyle='Flat';$button.FlatAppearance.BorderSize=0
        $button.Cursor=[Windows.Forms.Cursors]::Hand;$button.BackColor=[Drawing.Color]::White
        $button.ForeColor=[Drawing.ColorTranslator]::FromHtml('#506077')
        $button.Font=New-Object Drawing.Font('Segoe UI',9)
        $button.AccessibleName=$title
        $target=$page
        $button.Add_Click({$tc.SelectedTab=$target}.GetNewClosure())
        $nav.Controls.Add($button)
        [void]$items.Add(@{Page=$page;Button=$button;Title=$title;Hint=$hint})
        $position+=46
    }
    $refreshNav={
        foreach($item in $items) {
            $active=$tc.SelectedTab -eq $item.Page
            $item.Button.BackColor=if($active){[Drawing.ColorTranslator]::FromHtml('#EAF2FE')}else{[Drawing.Color]::White}
            $item.Button.ForeColor=if($active){[Drawing.ColorTranslator]::FromHtml('#165EB5')}else{[Drawing.ColorTranslator]::FromHtml('#506077')}
            if($active){$pageTitle.Text=$item.Title;$pageHint.Text=$item.Hint}
        }
    }.GetNewClosure()
    $tabControl.Add_SelectedIndexChanged($refreshNav);& $refreshNav

    $btnAutoScan.Text='Buscar na rede'
    $btnToggleManual.Text='Buscar servidor...'
    $manualPanel=$pnlNetSearch;$manualButton=$btnToggleManual
    $btnToggleManual.Add_Click({$manualButton.Text=if($manualPanel.Visible){'Ocultar servidor'}else{'Buscar servidor...' }}.GetNewClosure())
    $btnDiagnoseShare.Text='Diagnóstico detalhado'
    $btnConnectSelected.Text='Conectar impressora'
    $btnLocalPortSelected.Text='Instalar por porta local'
    $pnlNetTop.Height=100
    $pnlNetTop.BackColor=[Drawing.Color]::White
    $networkTools=@($btnAutoScan,$btnToggleManual,$btnDiagnoseShare,$btnFixNetwork24H2,$btnFix70911b)
    $widths=@(175,160,155,185,175);$x=12
    for($i=0;$i -lt $networkTools.Count;$i++) {
        $networkTools[$i].SetBounds($x,10,$widths[$i],34)
        $networkTools[$i].Font=New-Object Drawing.Font('Segoe UI',9)
        $x+=$widths[$i]+8
    }
    $tools=$networkTools;$toolWidths=$widths;$netPanel=$pnlNetTop
    $layoutTools={
        $x=12
        for($i=0;$i -lt $tools.Count;$i++){$tools[$i].SetBounds($x,10,$toolWidths[$i],34);$x+=$toolWidths[$i]+8}
    }.GetNewClosure()
    $pnlNetTop.Add_Resize($layoutTools)
    $lblScanStatus.SetBounds(12,54,650,36)
    $lblScanStatus.Font=New-Object Drawing.Font('Segoe UI',9)
    # Filter controls were previously placed between the large scan buttons.
    foreach($control in $pnlNetTop.Controls) {
        if($control -is [Windows.Forms.Label] -and $control.Text -match '^Filtro') {
            $control.Location=New-Object Drawing.Point(700,62)
        } elseif($control -is [Windows.Forms.TextBox]) {
            $control.SetBounds(745,57,155,25)
        }
    }
    $pnlNetBottom.Height=108
    $pnlNetBottom.BackColor=[Drawing.Color]::White
    $bottom=$pnlNetBottom;$connect=$btnConnectSelected;$local=$btnLocalPortSelected;$destination=$lblNetConnectionPath
    $layoutActions={
        $connect.SetBounds($bottom.ClientSize.Width-242,48,230,42)
        $local.SetBounds($bottom.ClientSize.Width-466,48,214,42)
        $destination.Width=[Math]::Max(100,$bottom.ClientSize.Width-350)
    }.GetNewClosure()
    $pnlNetBottom.Add_Resize($layoutActions);& $layoutActions
    $btnConnectSelected.BackColor=[Drawing.ColorTranslator]::FromHtml('#18794E')
    $btnConnectSelected.FlatAppearance.BorderSize=0
    $btnLocalPortSelected.BackColor=[Drawing.ColorTranslator]::FromHtml('#235FA3')
    $btnLocalPortSelected.FlatAppearance.BorderSize=0
    $dgvNetPrinters.Columns['UNC'].MinimumWidth=180
    $form.ResumeLayout($true)
    $headerControl=$pnlHeader;$modeControl=$chkSimulation
    $positionMode={ $modeControl.Left=$headerControl.ClientSize.Width-$modeControl.Width-24 }.GetNewClosure()
    $pnlHeader.Add_Resize($positionMode);& $positionMode
    foreach($column in $dgvNetPrinters.Columns){$column.FillWeight=100;$column.AutoSizeMode='Fill'}
    $dgvNetPrinters.Columns['UNC'].FillWeight=150
    $dgvNetPrinters.AutoResizeColumns()
}
