# =================================================================
#  Modulo-Drivers
#
#  CONTENIDO   : Show-Drivers-GUI
#                Show-Uninstall-Drivers-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - $Script:Scratch_DIR    : ruta para logs temporales
#  CARGA       : . "$PSScriptRoot\Modulo-Drivers.ps1"
#
# ==============================================================================
# Copyright (C) 2026 SOFTMAXTER
#
# DUAL LICENSING NOTICE:
# This software is dual-licensed. By default, AdminImagenOffline is 
# distributed under the GNU General Public License v3.0 (GPLv3).
# 
# 1. OPEN SOURCE (GPLv3):
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details: <https://www.gnu.org/licenses/>.
#
# 2. COMMERCIAL LICENSE:
# If you wish to integrate this software into a proprietary/commercial product, 
# distribute it without revealing your source code, or require commercial 
# support, you must obtain a commercial license from the original author.
#
# Please contact softmaxter@hotmail.com for commercial licensing inquiries.
# ==============================================================================

# =================================================================
#  Show-Drivers-GUI — Inyector de drivers offline
# =================================================================
function Show-Drivers-GUI {
    param()

    if ($Script:IMAGE_MOUNTED -eq 0) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $script:cancelDrivers = $false

    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "Inyector de Drivers - (Offline)"
    $form.Size            = New-Object System.Drawing.Size(1000, 680)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    $lblTitle          = New-Object System.Windows.Forms.Label
    $lblTitle.Text     = "Gestion de Drivers"
    $lblTitle.Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 15)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    $btnLoadFolder           = New-Object System.Windows.Forms.Button
    $btnLoadFolder.Text      = "[CARPETA] Cargar..."
    $btnLoadFolder.Location  = New-Object System.Drawing.Point(600, 12)
    $btnLoadFolder.Size      = New-Object System.Drawing.Size(160, 30)
    $btnLoadFolder.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
    $btnLoadFolder.FlatStyle = "Flat"
    $form.Controls.Add($btnLoadFolder)

    $btnAddFile           = New-Object System.Windows.Forms.Button
    $btnAddFile.Text      = "+ Agregar Archivo .INF"
    $btnAddFile.Location  = New-Object System.Drawing.Point(770, 12)
    $btnAddFile.Size      = New-Object System.Drawing.Size(180, 30)
    $btnAddFile.BackColor = [System.Drawing.Color]::RoyalBlue
    $btnAddFile.FlatStyle = "Flat"
    $form.Controls.Add($btnAddFile)

    $lblLegend           = New-Object System.Windows.Forms.Label
    $lblLegend.Text      = "Amarillo = Ya instalado | Blanco = Nuevo"
    $lblLegend.Location  = New-Object System.Drawing.Point(20, 45)
    $lblLegend.AutoSize  = $true
    $lblLegend.ForeColor = [System.Drawing.Color]::Gold
    $form.Controls.Add($lblLegend)

    $listView                  = New-Object System.Windows.Forms.ListView
    $listView.Location         = New-Object System.Drawing.Point(20, 70)
    $listView.Size             = New-Object System.Drawing.Size(940, 450)
    $listView.View             = [System.Windows.Forms.View]::Details
    $listView.CheckBoxes       = $true
    $listView.FullRowSelect    = $true
    $listView.GridLines        = $true
    $listView.BackColor        = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $listView.ForeColor        = [System.Drawing.Color]::White
    $listView.Columns.Add("Estado",        100) | Out-Null
    $listView.Columns.Add("Archivo INF",   180) | Out-Null
    $listView.Columns.Add("Clase",         100) | Out-Null
    $listView.Columns.Add("Version",       120) | Out-Null
    $listView.Columns.Add("Ruta Completa", 400) | Out-Null
    $form.Controls.Add($listView)

    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "Listo."
    $lblStatus.Location  = New-Object System.Drawing.Point(20, 530)
    $lblStatus.AutoSize  = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($lblStatus)

    $btnSelectNew           = New-Object System.Windows.Forms.Button
    $btnSelectNew.Text      = "Seleccionar Solo Nuevos"
    $btnSelectNew.Location  = New-Object System.Drawing.Point(20, 560)
    $btnSelectNew.Size      = New-Object System.Drawing.Size(170, 35)
    $btnSelectNew.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSelectNew.FlatStyle = "Flat"
    $form.Controls.Add($btnSelectNew)

    $chkForceUnsigned           = New-Object System.Windows.Forms.CheckBox
    $chkForceUnsigned.Text      = "Forzar sin firma (/ForceUnsigned)"
    $chkForceUnsigned.Location  = New-Object System.Drawing.Point(210, 567)
    $chkForceUnsigned.AutoSize  = $true
    $chkForceUnsigned.Checked   = $true
    $chkForceUnsigned.ForeColor = [System.Drawing.Color]::Orange
    $form.Controls.Add($chkForceUnsigned)

    $btnCancelAfterCurrent           = New-Object System.Windows.Forms.Button
    $btnCancelAfterCurrent.Text      = "Cancelar despues del actual"
    $btnCancelAfterCurrent.Location  = New-Object System.Drawing.Point(540, 560)
    $btnCancelAfterCurrent.Size      = New-Object System.Drawing.Size(200, 35)
    $btnCancelAfterCurrent.BackColor = [System.Drawing.Color]::DarkOrange
    $btnCancelAfterCurrent.FlatStyle = "Flat"
    $btnCancelAfterCurrent.Enabled   = $false
    $form.Controls.Add($btnCancelAfterCurrent)

    $btnInstall           = New-Object System.Windows.Forms.Button
    $btnInstall.Text      = "INYECTAR SELECCIONADOS"
    $btnInstall.Location  = New-Object System.Drawing.Point(760, 560)
    $btnInstall.Size      = New-Object System.Drawing.Size(200, 35)
    $btnInstall.BackColor = [System.Drawing.Color]::SeaGreen
    $btnInstall.FlatStyle = "Flat"
    $form.Controls.Add($btnInstall)

    $progressBar          = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(20, 605)
    $progressBar.Size     = New-Object System.Drawing.Size(940, 15)
    $progressBar.Style    = "Continuous"
    $progressBar.Visible  = $false
    $form.Controls.Add($progressBar)

    $script:cachedInstalledDrivers = @()

    $Script:ProcessInfFile = {
        param($fileObj)
        $classType   = "Desconocido"
        $localVersion = "---"
        $statusText  = "Nuevo"
        $isInstalled = $false

        try {
            $stream    = [System.IO.StreamReader]::new($fileObj.FullName)
            $linesRead = 0
            while ($null -ne ($line = $stream.ReadLine()) -and $linesRead -lt 300) {
                if ($line -match "^Class\s*=\s*(.*)") { $classType = $matches[1].Trim() }
                if ($line -match "DriverVer\s*=\s*.*?,([0-9\.\s]+)") { $localVersion = $matches[1].Trim() }
                if ($classType -ne "Desconocido" -and $localVersion -ne "---") { break }
                $linesRead++
            }
        } catch {} finally { if ($null -ne $stream) { $stream.Close(); $stream.Dispose() } }

        $foundByName = $script:cachedInstalledDrivers | Where-Object { [System.IO.Path]::GetFileName($_.OriginalFileName) -eq $fileObj.Name }
        if ($foundByName) {
            $isInstalled = $true; $statusText = "INSTALADO"
        } elseif ($localVersion -ne "---") {
            $foundByVer = $script:cachedInstalledDrivers | Where-Object {
                $match = $false
                if ($_.ClassName -eq $classType) {
                    try { $match = ([version]$_.Version -eq [version]$localVersion) }
                    catch { $match = ($_.Version -eq $localVersion) }
                }
                $match
            }
            if ($foundByVer) { $isInstalled = $true; $statusText = "INSTALADO" }
        }

        $item = New-Object System.Windows.Forms.ListViewItem($statusText)
        $item.SubItems.Add($fileObj.Name)      | Out-Null
        $item.SubItems.Add($classType)         | Out-Null
        $item.SubItems.Add($localVersion)      | Out-Null
        $item.SubItems.Add($fileObj.FullName)  | Out-Null
        $item.Tag = $fileObj.FullName

        if ($isInstalled) {
            $item.BackColor = [System.Drawing.Color]::FromArgb(60, 50, 0)
            $item.ForeColor = [System.Drawing.Color]::Gold
            $item.Checked   = $false
        } else {
            $item.Checked = $true
        }
        return $item
    }

    $form.Add_Shown({
        $form.Refresh()
        $listView.BeginUpdate()
        $lblStatus.Text = "Analizando drivers instalados en WIM..."
        $form.Refresh()
        try {
            $dismDrivers = Get-WindowsDriver -Path $Script:MOUNT_DIR -ErrorAction SilentlyContinue
            if ($dismDrivers) { $script:cachedInstalledDrivers = $dismDrivers }
        } catch {}
        $listView.EndUpdate()
        $lblStatus.Text      = "Listo. Usa los botones superiores."
        $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
    })

    $btnLoadFolder.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($fbd.ShowDialog() -eq 'OK') {
            $lblStatus.Text = "Escaneando..."; $form.Refresh()
            $listView.BeginUpdate()
            $files = Get-ChildItem -Path $fbd.SelectedPath -Filter "*.inf" -Recurse
            foreach ($f in $files) { $listView.Items.Add((& $Script:ProcessInfFile -fileObj $f)) | Out-Null }
            $listView.EndUpdate()
            $lblStatus.Text = "Drivers cargados: $($listView.Items.Count)"
        }
    })

    $btnAddFile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Archivos INF (*.inf)|*.inf"; $ofd.Multiselect = $true
        if ($ofd.ShowDialog() -eq 'OK') {
            $listView.BeginUpdate()
            foreach ($fn in $ofd.FileNames) { try { $listView.Items.Add((& $Script:ProcessInfFile -fileObj (Get-Item $fn))) | Out-Null } catch {} }
            $listView.EndUpdate()
        }
    })

    $btnSelectNew.Add_Click({ foreach ($item in $listView.Items) { $item.Checked = ($item.Text -match "Nuevo") } })

    $btnCancelAfterCurrent.Add_Click({
        $script:cancelDrivers = $true
        $btnCancelAfterCurrent.Enabled = $false
        $lblStatus.Text = "Cancelacion solicitada. Se detendra despues del controlador actual."
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    })

    $btnInstall.Add_Click({
        $checkedItems = $listView.CheckedItems
        if ($checkedItems.Count -eq 0) { return }

        if ([System.Windows.Forms.MessageBox]::Show("Inyectar $($checkedItems.Count) drivers?", "Confirmar", 'YesNo') -ne 'Yes') { return }

        $btnInstall.Enabled = $false
        $btnCancelAfterCurrent.Enabled = $true
        $chkForceUnsigned.Enabled = $false
        $script:cancelDrivers = $false
        $progressBar.Maximum = $checkedItems.Count
        $progressBar.Value = 0
        $progressBar.Visible = $true

        $count = 0; $errs = 0; $success = 0; $total = $checkedItems.Count

        try {
            $scratchBase = $Script:Scratch_DIR
            if ([string]::IsNullOrWhiteSpace($scratchBase)) { $scratchBase = [System.IO.Path]::GetTempPath() }
            if (-not (Test-Path -LiteralPath $scratchBase)) { New-Item -Path $scratchBase -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }

            foreach ($item in $checkedItems) {
                if ($script:cancelDrivers) { break }
                $count++
                $progressBar.Value = [Math]::Min($count, $progressBar.Maximum)
                $driverName = $item.SubItems[1].Text
                $driverPath = $item.Tag

                $lblStatus.Text = "Instalando ($count/$total): $driverName..."
                $form.Refresh()

                try {
                    $dismLogPath = Join-Path $scratchBase "dism_drv_$([Guid]::NewGuid().ToString('N').Substring(0,8)).log"
                    $args = "/Image:`"$Script:MOUNT_DIR`" /Add-Driver /Driver:`"$driverPath`" /LogPath:`"$dismLogPath`" /LogLevel:3"
                    if ($chkForceUnsigned.Checked) { $args += " /ForceUnsigned" }
                    
                    $proc = Start-Process "dism.exe" -ArgumentList $args -WindowStyle Hidden -PassThru
                    while (-not $proc.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }

                    if ($proc.ExitCode -eq 0) {
                        $item.BackColor = [System.Drawing.Color]::DarkGreen
                        $item.Text      = "INSTALADO"
                        $item.Checked   = $false
                        $success++
                    } else {
                        $errs++
                        $item.BackColor = [System.Drawing.Color]::DarkRed
                        $item.Text      = "ERROR"
                        $dismTail = Get-Content $dismLogPath -Tail 10 -ErrorAction SilentlyContinue | Where-Object { $_ -match "Error|Warning" }
                        Write-Log -LogLevel ERROR -Message "Driver_Injector: Fallo [$driverName] Code: $($proc.ExitCode) | Log: $($dismTail -join ' ')"
                    }
                } catch {
                    $errs++
                    $item.BackColor = [System.Drawing.Color]::DarkRed
                    Write-Log -LogLevel ERROR -Message "Driver_Injector: Excepcion [$driverName] - $($_.Exception.Message)"
                } finally {
                    if (Test-Path -LiteralPath $dismLogPath -ErrorAction SilentlyContinue) { Remove-Item $dismLogPath -Force -ErrorAction SilentlyContinue }
                }
            }

            $lblStatus.Text = "Actualizando base de datos de drivers... Por favor espera."
            $form.Refresh()
            try {
                $dismDrivers = Get-WindowsDriver -Path $Script:MOUNT_DIR -ErrorAction SilentlyContinue
                if ($dismDrivers) { $script:cachedInstalledDrivers = $dismDrivers }
            } catch {}

            $msgCancel = if ($script:cancelDrivers) { "`nCancelado por el usuario." } else { "" }
            [System.Windows.Forms.MessageBox]::Show("Proceso terminado.$msgCancel`nErrores: $errs", "Info", 'OK', 'Information')

        } finally {
            $btnInstall.Enabled = $true
            $btnCancelAfterCurrent.Enabled = $false
            $chkForceUnsigned.Enabled = $true
            $progressBar.Visible = $false
            $lblStatus.Text = "Proceso terminado. Errores: $errs"
        }
    })

    $form.Add_FormClosing({
        if (-not $btnInstall.Enabled) {
            [System.Windows.Forms.MessageBox]::Show("Operacion en curso. Use Cancelar.", "Advertencia", 'OK', 'Warning')
            $_.Cancel = $true
            return
        }
        if ([System.Windows.Forms.MessageBox]::Show("Seguro que quieres cerrar esta ventana?", "Confirmar", 'YesNo', 'Question') -eq 'No') { $_.Cancel = $true }
    })

    $form.ShowDialog() | Out-Null
    if ($null -ne $listView) { $listView.Dispose() }
    $form.Dispose()
    [GC]::Collect()
    $script:cachedInstalledDrivers = $null
    [GC]::WaitForPendingFinalizers()
}


# =================================================================
#  Show-Uninstall-Drivers-GUI — Eliminador de drivers offline
# =================================================================
function Show-Uninstall-Drivers-GUI {
    param()

    if ($Script:IMAGE_MOUNTED -eq 0) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $script:cancelDrivers = $false

    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "Eliminar Drivers de la Imagen - $Script:MOUNT_DIR"
    $form.Size            = New-Object System.Drawing.Size(850, 630)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    $lblTitle          = New-Object System.Windows.Forms.Label
    $lblTitle.Text     = "Drivers de Terceros Instalados (OEM)"
    $lblTitle.Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 15)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    $lblWarn           = New-Object System.Windows.Forms.Label
    $lblWarn.Text      = "CUIDADO: Interceptor activo. El sistema alertara sobre drivers vitales."
    $lblWarn.Location  = New-Object System.Drawing.Point(350, 20)
    $lblWarn.AutoSize  = $true
    $lblWarn.ForeColor = [System.Drawing.Color]::Salmon
    $form.Controls.Add($lblWarn)

    $listView               = New-Object System.Windows.Forms.ListView
    $listView.Location      = New-Object System.Drawing.Point(20, 50)
    $listView.Size          = New-Object System.Drawing.Size(790, 430)
    $listView.View          = [System.Windows.Forms.View]::Details
    $listView.CheckBoxes    = $true
    $listView.FullRowSelect = $true
    $listView.GridLines     = $true
    $listView.BackColor     = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $listView.ForeColor     = [System.Drawing.Color]::White
    $listView.Columns.Add("Nombre Publicado (ID)", 150) | Out-Null
    $listView.Columns.Add("Archivo Original",       200) | Out-Null
    $listView.Columns.Add("Clase",                  120) | Out-Null
    $listView.Columns.Add("Proveedor",              150) | Out-Null
    $listView.Columns.Add("Version",                100) | Out-Null
    $form.Controls.Add($listView)

    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "Leyendo almacen de drivers..."
    $lblStatus.Location  = New-Object System.Drawing.Point(20, 490)
    $lblStatus.AutoSize  = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($lblStatus)

    $btnSelectAll           = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text      = "Marcar Todo"
    $btnSelectAll.Location  = New-Object System.Drawing.Point(20, 520)
    $btnSelectAll.Size      = New-Object System.Drawing.Size(100, 35)
    $btnSelectAll.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSelectAll.FlatStyle = "Flat"
    $form.Controls.Add($btnSelectAll)

    $btnCancelAfterCurrent           = New-Object System.Windows.Forms.Button
    $btnCancelAfterCurrent.Text      = "Cancelar despues del actual"
    $btnCancelAfterCurrent.Location  = New-Object System.Drawing.Point(340, 520)
    $btnCancelAfterCurrent.Size      = New-Object System.Drawing.Size(200, 35)
    $btnCancelAfterCurrent.BackColor = [System.Drawing.Color]::DarkOrange
    $btnCancelAfterCurrent.FlatStyle = "Flat"
    $btnCancelAfterCurrent.Enabled   = $false
    $form.Controls.Add($btnCancelAfterCurrent)

    $btnDelete           = New-Object System.Windows.Forms.Button
    $btnDelete.Text      = "ELIMINAR SELECCIONADOS"
    $btnDelete.Location  = New-Object System.Drawing.Point(560, 520)
    $btnDelete.Size      = New-Object System.Drawing.Size(250, 35)
    $btnDelete.BackColor = [System.Drawing.Color]::Crimson
    $btnDelete.FlatStyle = "Flat"
    $form.Controls.Add($btnDelete)

    $progressBar          = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(20, 565)
    $progressBar.Size     = New-Object System.Drawing.Size(790, 15)
    $progressBar.Style    = "Continuous"
    $progressBar.Visible  = $false
    $form.Controls.Add($progressBar)

    $form.Add_Shown({
        $form.Refresh()
        $listView.BeginUpdate()
        try {
            $drivers = Get-WindowsDriver -Path $Script:MOUNT_DIR -ErrorAction Stop
            foreach ($drv in $drivers) {
                $item = New-Object System.Windows.Forms.ListViewItem($drv.Driver)
                $item.SubItems.Add($drv.OriginalFileName) | Out-Null
                $item.SubItems.Add($drv.ClassName)        | Out-Null
                $item.SubItems.Add($drv.ProviderName)     | Out-Null
                $item.SubItems.Add($drv.Version)          | Out-Null
                $item.Tag = $drv.Driver
                $listView.Items.Add($item) | Out-Null
            }
            $lblStatus.Text = "Drivers encontrados: $($listView.Items.Count)"
            $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
        } catch {
            $lblStatus.Text = "Error al leer drivers: $_"
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
        }
        $listView.EndUpdate()
    })

    $btnSelectAll.Add_Click({ foreach ($item in $listView.Items) { $item.Checked = $true } })

    $btnCancelAfterCurrent.Add_Click({
        $script:cancelDrivers = $true
        $btnCancelAfterCurrent.Enabled = $false
        $lblStatus.Text = "Cancelacion solicitada. Se detendra tras la eliminacion actual..."
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    })

    $btnDelete.Add_Click({
        $checkedItems = $listView.CheckedItems
        if ($checkedItems.Count -eq 0) { return }

        $criticalClasses = @("SCSIAdapter", "HDC", "System", "USB", "Firmware", "Display")
        $hasCritical = $checkedItems | Where-Object { $_.SubItems[2].Text -in $criticalClasses }

        if ($hasCritical) {
            $warnMsg = "ADVERTENCIA: La seleccion incluye clases criticas de hardware ($($hasCritical[0].SubItems[2].Text)).`n`n" +
                       "Eliminar controladores de disco, USB o Sistema dejara la imagen inservible (Pantalla Azul de la Muerte).`n`n" +
                       "Seguro que deseas eliminarlos permanentemente?"
            if ([System.Windows.Forms.MessageBox]::Show($warnMsg, "ALERTA DE SEGURIDAD", 'YesNo', 'Warning') -ne 'Yes') { return }
        } else {
            if ([System.Windows.Forms.MessageBox]::Show("Se eliminaran $($checkedItems.Count) drivers. Continuar?", "Confirmar", 'YesNo') -ne 'Yes') { return }
        }

        $btnDelete.Enabled = $false
        $btnCancelAfterCurrent.Enabled = $true
        $script:cancelDrivers = $false
        $progressBar.Maximum = $checkedItems.Count
        $progressBar.Value = 0
        $progressBar.Visible = $true

        $count = 0; $errors = 0; $total = $checkedItems.Count

        try {
            $scratchBase = $Script:Scratch_DIR
            if ([string]::IsNullOrWhiteSpace($scratchBase)) { $scratchBase = [System.IO.Path]::GetTempPath() }
            if (-not (Test-Path -LiteralPath $scratchBase)) { New-Item -Path $scratchBase -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }

            foreach ($item in $checkedItems) {
                if ($script:cancelDrivers) { break }
                $count++
                $progressBar.Value = [Math]::Min($count, $progressBar.Maximum)
                $oemInf  = $item.Tag
                $origName = $item.SubItems[1].Text

                $lblStatus.Text = "Eliminando ($count/$total): $origName ($oemInf)..."
                $form.Refresh()

                try {
                    $dismLogPath = Join-Path $scratchBase "dism_rmdrv_$([Guid]::NewGuid().ToString('N').Substring(0,8)).log"
                    $args = "/Image:`"$Script:MOUNT_DIR`" /Remove-Driver /Driver:`"$oemInf`" /LogPath:`"$dismLogPath`" /LogLevel:3"
                    
                    $proc = Start-Process "dism.exe" -ArgumentList $args -WindowStyle Hidden -PassThru
                    while (-not $proc.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }

                    if ($proc.ExitCode -eq 0) {
                        $item.BackColor = [System.Drawing.Color]::Gray
                        $item.ForeColor = [System.Drawing.Color]::Black
                        $item.Text      += " [BORRADO]"
                        $item.Checked   = $false
                    } else {
                        $errors++
                        $item.BackColor = [System.Drawing.Color]::DarkRed
                        $dismTail = Get-Content $dismLogPath -Tail 10 -ErrorAction SilentlyContinue | Where-Object { $_ -match "Error|Warning" }
                        Write-Log -LogLevel ERROR -Message "Driver_Remove: Fallo [$oemInf] Code: $($proc.ExitCode) | Log: $($dismTail -join ' ')"
                    }
                } catch {
                    $errors++
                    $item.BackColor = [System.Drawing.Color]::DarkRed
                    Write-Log -LogLevel ERROR -Message "Driver_Remove: Excepcion al eliminar [$oemInf] - $($_.Exception.Message)"
                } finally {
                    if (Test-Path -LiteralPath $dismLogPath -ErrorAction SilentlyContinue) { Remove-Item $dismLogPath -Force -ErrorAction SilentlyContinue }
                }
            }

            $msgCancel = if ($script:cancelDrivers) { "`nCancelado por el usuario." } else { "" }
            [System.Windows.Forms.MessageBox]::Show("Proceso completado.$msgCancel`nErrores: $errors", "Resultado", 'OK', 'Information')

        } finally {
            $btnDelete.Enabled = $true
            $btnCancelAfterCurrent.Enabled = $false
            $progressBar.Visible = $false
            $lblStatus.Text = "Proceso finalizado. Errores: $errors"
        }
    })

    $form.Add_FormClosing({
        if (-not $btnDelete.Enabled) {
            [System.Windows.Forms.MessageBox]::Show("Operacion en curso. Use Cancelar.", "Advertencia", 'OK', 'Warning')
            $_.Cancel = $true
            return
        }
        if ([System.Windows.Forms.MessageBox]::Show("Seguro que quieres cerrar esta ventana?", "Confirmar", 'YesNo', 'Question') -eq 'No') { $_.Cancel = $true }
    })

    $form.ShowDialog() | Out-Null
    if ($null -ne $listView) { $listView.Dispose() }
    $form.Dispose()
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}