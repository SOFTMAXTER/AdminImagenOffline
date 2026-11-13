#requires -Version 5.1
# Logica compartida por Metadata e IntegrarIndices. AdminImagenOffline, GPLv3.
# La carga solo declara funciones; no abre ventanas ni modifica imagenes.

function Get-AIOWimImageProfile {
    param([object]$Image)
    # Usar identidad original cuando se edita un plan: cambiar EDITIONID no
    # convierte Windows ni debe cambiar las advertencias de compatibilidad.
    $edition = if ($Image.PSObject.Properties['OriginalEdition']) { [string]$Image.OriginalEdition } else { [string]$Image.Edition }
    $name = if ($Image.PSObject.Properties['OriginalName']) { [string]$Image.OriginalName } else { [string]$Image.Name }
    $build = 0
    $hasBuild = [int]::TryParse([string]$Image.Build, [ref]$build) -and $build -gt 0
    $family = 'Unknown'
    if ($Image.InstallationType -match '^(WindowsPE|WinPE)' -or
        $edition -match '^(WindowsPE|WinPE)' -or $Image.Flags -match '^(WindowsPE|WinPE)') {
        $family = 'WinPE'
    } elseif ($Image.ProductType -match '^(ServerNT|LanmanNT)$' -or
        $Image.InstallationType -match '^Server' -or
        $edition -match '^Server(?!Rdsh$)' -or $Image.Flags -match '^Server(?!Rdsh$)') {
        $family = 'Server'
    } elseif ($hasBuild -and $build -lt 10240) {
        $family = 'Legacy'
    } else {
        $client = $Image.InstallationType -eq 'Client' -or $Image.ProductType -eq 'WinNT' -or
            $edition -match '^(Core|Professional|Enterprise|Education|IoTEnterprise|Cloud|PPIPro|WNC|ServerRdsh)'
        if ($hasBuild -and ($client -or $name -match '\bWindows\s*(10|11)\b')) {
            $family = if ($build -ge 22000) { 'Windows11' } else { 'Windows10' }
        } elseif (-not $hasBuild -and $name -match '\bWindows\s*(10|11)\b') {
            $family = 'Windows' + $Matches[1]
        }
    }
    [pscustomobject]@{
        Family = $family
        IsWindows11 = ($family -eq 'Windows11')
        IsLTSC = ($edition -match '^(EnterpriseS|EnterpriseSN|IoTEnterpriseS|IoTEnterpriseSK)(Eval)?$')
    }
}

function Get-AIOWimEditionChoices {
    param([object]$Image)
    $profile = Get-AIOWimImageProfile $Image
    if ($profile.Family -eq 'Server') {
        return @('ServerStandard', 'ServerStandardCore', 'ServerDatacenter', 'ServerDatacenterCore', 'ServerAzureCor')
    }
    if ($profile.Family -notin @('Windows10', 'Windows11')) { return }
    if ($profile.IsLTSC) {
        @('EnterpriseS', 'EnterpriseSN', 'IoTEnterpriseS')
        if ($profile.IsWindows11) { 'IoTEnterpriseSK' }
        return
    }
    @('Core', 'CoreN', 'CoreK', 'CoreSingleLanguage', 'CoreCountrySpecific',
      'Professional', 'ProfessionalN', 'ProfessionalEducation', 'ProfessionalEducationN',
      'ProfessionalWorkstation', 'ProfessionalWorkstationN', 'ProfessionalCountrySpecific', 'ProfessionalSingleLanguage',
      'Education', 'EducationN', 'Enterprise', 'EnterpriseN', 'EnterpriseG', 'EnterpriseGN', 'ServerRdsh', 'IoTEnterprise')
    if ($profile.IsWindows11) { @('IoTEnterpriseK', 'CloudEdition', 'CloudEditionN') }
    else { @('Cloud', 'CloudN') }
}

function Get-AIOWimMetadataTemplate {
    param([object]$Image, [string]$EditionId)
    if (@(Get-AIOWimEditionChoices $Image) -inotcontains $EditionId) {
        throw 'La plantilla no corresponde a la familia de Windows de esta imagen.'
    }
    $catalogPath = $null
    foreach ($relativePath in @('Catalogos\Ediciones.ps1', 'Modulo-Ediciones.ps1', 'Ediciones.ps1')) {
        $candidate = Join-Path $PSScriptRoot $relativePath
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $catalogPath = $candidate; break }
    }
    if (-not $catalogPath) { throw 'Falta el catalogo de ediciones. Puedes introducir los metadatos manualmente.' }
    . $catalogPath
    $meta = Get-WindowsEditionMetadata -QueryString $EditionId
    $profile = Get-AIOWimImageProfile $Image
    $name = [string]$meta.Name
    if ($profile.Family -ne 'Server') {
        $prefix = if ($profile.IsWindows11) { 'Windows 11 ' } else { 'Windows 10 ' }
        # Cloud y CloudEdition ya incluyen 10/11: evitar "Windows 11 11 SE".
        $name = $name -replace '^Windows(?:\s+(?:10|11))?\s+', $prefix
    }
    [pscustomobject]@{
        Name = $name; Description = [string]$meta.Description
        DisplayName = $name; DisplayDescription = [string]$meta.Description
        Edition = $EditionId
    }
}

function Assert-AIOWimMetadata {
    param([object]$Metadata)
    if ([string]::IsNullOrWhiteSpace([string]$Metadata.Name) -or $Metadata.Name -match '[\x00-\x1F]') {
        throw 'El nombre es obligatorio y no puede contener saltos de linea ni caracteres de control.'
    }
    foreach ($field in @('Name', 'Description', 'DisplayName', 'DisplayDescription', 'Edition')) {
        try { [void][Xml.XmlConvert]::VerifyXmlChars([string]$Metadata.$field) }
        catch { throw "El campo $field contiene caracteres no validos para XML." }
    }
}

function Show-AIOWimMetadataDraftEditor {
    param([object]$Image, [object]$Owner)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    # Solo devuelve un borrador al aceptar. Cancelar nunca modifica $Image.
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Metadatos del indice de salida'
    $dialog.Size = New-Object Drawing.Size(800, 530)
    $dialog.MinimumSize = New-Object Drawing.Size(660, 480)
    $dialog.StartPosition = 'CenterParent'
    $dialog.Font = New-Object Drawing.Font('Segoe UI', 9)
    $dialog.AutoScaleMode = 'Dpi'
    $dialog.BackColor = [Drawing.Color]::FromArgb(30, 30, 30)
    $dialog.ForeColor = [Drawing.Color]::White
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'; $layout.Padding = New-Object Windows.Forms.Padding(14)
    $layout.ColumnCount = 1; $layout.RowCount = 4
    foreach ($height in @(66, 38, -1, 46)) {
        if ($height -eq -1) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100))) }
        else { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $height))) }
    }
    $dialog.Controls.Add($layout)
    $help = New-Object Windows.Forms.Label
    $help.Dock = 'Fill'
    $help.Text = "Los cambios se aplicaran al crear el WIM de salida.`r`nArquitectura: $($Image.Architecture) | Build: $($Image.Build)`r`nCambiar el ID de edicion solo edita metadatos; no convierte ni activa Windows."
    $layout.Controls.Add($help, 0, 0)
    $templates = New-Object Windows.Forms.ComboBox
    $templates.Dock = 'Fill'; $templates.DropDownStyle = 'DropDownList'
    $templates.BackColor = [Drawing.Color]::FromArgb(50, 50, 50); $templates.ForeColor = [Drawing.Color]::Yellow
    [void]$templates.Items.Add('-- Plantilla de edicion (opcional) --')
    $choices = @(Get-AIOWimEditionChoices $Image)
    foreach ($choice in $choices) { [void]$templates.Items.Add($choice) }
    $templates.SelectedIndex = 0; $templates.Enabled = $choices.Count -gt 0
    $layout.Controls.Add($templates, 0, 1)
    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.RowHeadersVisible = $false
    $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
    $grid.AutoSizeColumnsMode = 'Fill'; $grid.AutoSizeRowsMode = 'AllCells'
    $grid.DefaultCellStyle.WrapMode = 'True'
    $grid.BackgroundColor = [Drawing.Color]::FromArgb(40, 40, 40)
    $grid.DefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(40, 40, 40)
    $grid.DefaultCellStyle.ForeColor = [Drawing.Color]::White
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(50, 50, 50)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::Silver
    [void]$grid.Columns.Add('Property', 'Propiedad'); [void]$grid.Columns.Add('Value', 'Valor')
    $grid.Columns[0].ReadOnly = $true; $grid.Columns[0].FillWeight = 35
    foreach ($column in $grid.Columns) { $column.SortMode = 'NotSortable' }
    $fields = @('Name', 'Description', 'DisplayName', 'DisplayDescription', 'Edition')
    $labels = @('Nombre', 'Descripcion', 'Nombre mostrado', 'Descripcion mostrada', 'ID de edicion')
    for ($i = 0; $i -lt $fields.Count; $i++) { [void]$grid.Rows.Add($labels[$i], [string]$Image.($fields[$i])) }
    $layout.Controls.Add($grid, 0, 2)
    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Fill'; $buttons.FlowDirection = 'RightToLeft'
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancelar'; $cancel.Size = New-Object Drawing.Size(115, 32)
    $cancel.DialogResult = 'Cancel'
    $apply = New-Object Windows.Forms.Button
    $apply.Text = 'Aplicar al plan'; $apply.Size = New-Object Drawing.Size(140, 32)
    foreach ($button in @($cancel, $apply)) {
        $button.FlatStyle = 'Flat'; $button.UseVisualStyleBackColor = $false
        $button.BackColor = [Drawing.Color]::FromArgb(60, 60, 60)
        $button.ForeColor = [Drawing.Color]::White
        $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(85, 85, 85)
    }
    $apply.BackColor = [Drawing.Color]::SeaGreen
    $buttons.Controls.AddRange(@($cancel, $apply))
    $layout.Controls.Add($buttons, 0, 3)
    $dialog.CancelButton = $cancel
    $templates.Add_SelectedIndexChanged({
        if ($templates.SelectedIndex -le 0) { return }
        try {
            [void]$grid.EndEdit()
            $meta = Get-AIOWimMetadataTemplate $Image ([string]$templates.SelectedItem)
            for ($i = 0; $i -lt $fields.Count; $i++) { $grid.Rows[$i].Cells[1].Value = $meta.($fields[$i]) }
        } catch { [void][Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, 'Metadatos', 'OK', 'Warning') }
    })
    $apply.Add_Click({
        try {
            [void]$grid.EndEdit()
            $values = [ordered]@{}
            for ($i = 0; $i -lt $fields.Count; $i++) { $values[$fields[$i]] = [string]$grid.Rows[$i].Cells[1].Value }
            $draft = [pscustomobject]$values
            Assert-AIOWimMetadata $draft
            $dialog.Tag = $draft
            $dialog.DialogResult = 'OK'
        } catch { [void][Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, 'Metadatos', 'OK', 'Warning') }
    })
    try {
        if ($dialog.ShowDialog($Owner) -eq 'OK') { return $dialog.Tag }
    } finally { $dialog.Dispose() }
}
