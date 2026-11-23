# =================================================================
#  Modulo-ServiciosOffline
#
#  CONTENIDO   : Show-Services-Offline-GUI
#  DEPENDENCIAS COMPARTIDAS: Set-AIOTabControlStyle (Modulo-UI.ps1)
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - Mount-Hives            : montar colmenas offline del registro
#    - Unmount-Hives          : desmontar colmenas offline del registro
#    - Get-OfflineControlSet  : determina el ControlSet activo de la imagen
#    - Unlock-Single-Key      : tomar propiedad de una clave especifica
#    - Restore-KeyOwner       : restaurar propietario de clave de registro offline
#    - $PSScriptRoot          : ruta base para localizar Catalogos\Servicios.ps1
#  CARGA       : . "$PSScriptRoot\Modulo-ServiciosOffline.ps1"
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

function Show-Services-Offline-GUI {
    param()

    Add-Type -AssemblyName System.Windows.Forms

    # 1. Validaciones
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'drivers.mount_first'), (Get-AIOString 'common.error_title'), 'OK', 'Error')
        return 
    }

    # 2. Cargar Catalogo
    $servicesFile = Join-Path $PSScriptRoot "Catalogos\Servicios.ps1"
    if (-not (Test-Path $servicesFile)) { $servicesFile = Join-Path $PSScriptRoot "Servicios.ps1" }
    
    if (Test-Path $servicesFile) { 
        . $servicesFile 
    } else { 
        [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'servicios.catalog_missing'), (Get-AIOString 'common.error_title'), 'OK', 'Error')
        return 
    }

    # 3. Montar Hives
    if (-not (Mount-Hives)) { return }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Collections

    # 4. Configuracion del Formulario
    $form = New-Object System.Windows.Forms.Form
    $form.Text = Get-AIOString 'servicios.form_title' $Script:MOUNT_DIR
    $form.Size = New-Object System.Drawing.Size(1100, 750)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    # ToolTip
    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 5000
    $toolTip.InitialDelay = 500
    $toolTip.ReshowDelay = 500
    $toolTip.ShowAlways = $true

    # Titulo
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = Get-AIOString 'servicios.title'
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 10)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # --- CONTROL DE PESTANAS ---
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = New-Object System.Drawing.Point(20, 40)
    $tabControl.Size = New-Object System.Drawing.Size(1045, 480)
    $tabControl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    Set-AIOTabControlStyle -TabControl $tabControl
    $form.Controls.Add($tabControl)

    # --- CAMPO DE VISUALIZACIÓN DE DESCRIPCIÓN ---
    $txtServiceDesc = New-Object System.Windows.Forms.TextBox
    $txtServiceDesc.Location = New-Object System.Drawing.Point(20, 530)
    $txtServiceDesc.Size = New-Object System.Drawing.Size(1045, 60)
    $txtServiceDesc.Multiline = $true
    $txtServiceDesc.ReadOnly = $true
    $txtServiceDesc.ScrollBars = "Vertical"
    $txtServiceDesc.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $txtServiceDesc.ForeColor = [System.Drawing.Color]::White
    $txtServiceDesc.BorderStyle = "FixedSingle"
    $txtServiceDesc.Text = Get-AIOString 'servicios.desc_placeholder'
    $form.Controls.Add($txtServiceDesc)

    # --- PANEL DE ACCIONES ---
    $pnlActions = New-Object System.Windows.Forms.Panel
    $pnlActions.Location = New-Object System.Drawing.Point(20, 600)
    $pnlActions.Size = New-Object System.Drawing.Size(1045, 100)
    $pnlActions.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $pnlActions.BorderStyle = "FixedSingle"
    $form.Controls.Add($pnlActions)

    # Barra de Estado
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = Get-AIOString 'servicios.status_loading_hives'
    $lblStatus.Location = New-Object System.Drawing.Point(10, 10)
    $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $pnlActions.Controls.Add($lblStatus)

    # Boton Marcar Todo
    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = Get-AIOString 'servicios.btn_select_all'
    $btnSelectAll.Location = New-Object System.Drawing.Point(10, 40)
    $btnSelectAll.Size = New-Object System.Drawing.Size(140, 40)
    $btnSelectAll.BackColor = [System.Drawing.Color]::Gray
    $btnSelectAll.FlatStyle = "Flat"
    $toolTip.SetToolTip($btnSelectAll, "Marca todos los servicios visibles en la pestana actual.")
    $pnlActions.Controls.Add($btnSelectAll)

    # Boton Restaurar (NUEVO)
    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = Get-AIOString 'servicios.btn_restore'
    $btnRestore.Location = New-Object System.Drawing.Point(400, 40)
    $btnRestore.Size = New-Object System.Drawing.Size(280, 40)
    $btnRestore.BackColor = [System.Drawing.Color]::FromArgb(200, 100, 0)
    $btnRestore.ForeColor = [System.Drawing.Color]::White
    $btnRestore.FlatStyle = "Flat"
    $btnRestore.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $toolTip.SetToolTip($btnRestore, "Devuelve los servicios seleccionados a su estado por defecto (Manual/Automatico).")
    $pnlActions.Controls.Add($btnRestore)

    # Boton Deshabilitar
    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = Get-AIOString 'servicios.btn_disable'
    $btnApply.Location = New-Object System.Drawing.Point(700, 40)
    $btnApply.Size = New-Object System.Drawing.Size(320, 40)
    $btnApply.BackColor = [System.Drawing.Color]::Crimson
    $btnApply.ForeColor = [System.Drawing.Color]::White
    $btnApply.FlatStyle = "Flat"
    $btnApply.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $toolTip.SetToolTip($btnApply, "Deshabilita los servicios seleccionados.")
    $pnlActions.Controls.Add($btnApply)

    # Barra de Progreso
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(10, 85)
    $progressBar.Size = New-Object System.Drawing.Size(1025, 10)
    $progressBar.Style = "Continuous"
    $progressBar.Visible = $false
    $pnlActions.Controls.Add($progressBar)

    # Lista global
    $globalListViews = New-Object System.Collections.Generic.List[System.Windows.Forms.ListView]

    # 4. Logica de Carga Dinamica
    $form.Add_Shown({
        $form.Refresh()
        
        # Obtener categorias unicas
        $categories = $script:ServiceCatalog | Select-Object -ExpandProperty Category -Unique | Sort-Object
        $tabControl.SuspendLayout()

        foreach ($cat in $categories) {
            $tabPage = New-Object System.Windows.Forms.TabPage
            $tabPage.Text = "  $cat  "
            $tabPage.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)

            $lv = New-Object System.Windows.Forms.ListView
            $lv.Dock = [System.Windows.Forms.DockStyle]::Fill
            $lv.View = [System.Windows.Forms.View]::Details
            $lv.CheckBoxes = $true
            $lv.FullRowSelect = $true
            $lv.GridLines = $true
            $lv.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
            $lv.ForeColor = [System.Drawing.Color]::White
            $lv.BorderStyle = "None"

            $lv.Columns.Add((Get-AIOString 'servicios.col_service'), 200) | Out-Null
            $lv.Columns.Add((Get-AIOString 'servicios.col_current_state'), 120) | Out-Null
            $lv.Columns.Add((Get-AIOString 'servicios.col_orig_config'), 120) | Out-Null
            $lv.Columns.Add((Get-AIOString 'servicios.col_description'), 450) | Out-Null

            $lv.Add_SelectedIndexChanged({
                if ($this.SelectedItems.Count -gt 0) {
                    $svcObj = $this.SelectedItems[0].Tag
                    $txtServiceDesc.Text = $svcObj.Description
                    $txtServiceDesc.ForeColor = [System.Drawing.Color]::White
                } else {
                    $txtServiceDesc.Text = Get-AIOString 'servicios.desc_placeholder'
                    $txtServiceDesc.ForeColor = [System.Drawing.Color]::DarkGray
                }
            })
            
            $tabPage.Tag = $cat
            $tabPage.Controls.Add($lv)
            $tabControl.TabPages.Add($tabPage)
            $globalListViews.Add($lv)
        }

        # Llenar Datos
        $totalServices = 0

        foreach ($svc in $script:ServiceCatalog) {
            # Buscar el ListView correcto
            $targetLV = $null
            foreach ($tab in $tabControl.TabPages) {
                if ($tab.Tag -eq $svc.Category) {
                    $targetLV = $tab.Controls[0] 
                    break
                }
            }

            if ($targetLV) {
                $ctrlSet = Get-OfflineControlSet 
                $regPath = "Registry::HKLM\OfflineSystem\$ctrlSet\Services\$($svc.Name)"
                $currentStart = "No Encontrado"
                $isDisabled = $false
                
                if (Test-Path -LiteralPath $regPath) {
                    $val = (Get-ItemProperty -Path $regPath -Name "Start" -ErrorAction SilentlyContinue).Start
                    
                    if ($val -eq 4) { 
                        $currentStart = "Deshabilitado"
                        $isDisabled = $true
                    }
                    elseif ($val -eq 2) { $currentStart = "Automatico" }
                    elseif ($val -eq 3) { $currentStart = "Manual" }
                    else { $currentStart = "Desconocido ($val)" }
                }

                $item = New-Object System.Windows.Forms.ListViewItem($svc.Name)
                $item.SubItems.Add($currentStart) | Out-Null
                
                # Traducir DefaultStartupType del ingles al espanol para mostrar
                $defDisplay = $svc.DefaultStartupType
                if ($defDisplay -eq "Automatic") { $defDisplay = "Automatico" }
                
                $item.SubItems.Add($defDisplay) | Out-Null
                $item.SubItems.Add($svc.Description) | Out-Null
                
                $item.Tag = $svc 

                # Colores
                if ($isDisabled) {
                    $item.ForeColor = [System.Drawing.Color]::LightGreen
                    $item.Checked = $false 
                } elseif ($currentStart -eq "No Encontrado") {
                    $item.ForeColor = [System.Drawing.Color]::Gray
                    $item.Checked = $false 
                } else {
                    $item.ForeColor = [System.Drawing.Color]::White
                    $item.Checked = $false 
                }

                $targetLV.Items.Add($item) | Out-Null
                $totalServices++
            }
        }

        $tabControl.ResumeLayout()
        $lblStatus.Text = Get-AIOString 'servicios.status_loaded' $totalServices
        $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
    })

    # 5. Logica de Procesamiento (Helper Interno)
    $ProcessServices = {
        param($Mode) # 'Disable' o 'Restore'

        Write-Log -LogLevel INFO -Message "ServiceManager: Recopilando servicios seleccionados para operacion ($Mode)."

        $allChecked = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
        foreach ($lv in $globalListViews) {
            foreach ($i in $lv.CheckedItems) { $allChecked.Add($i) }
        }

        if ($allChecked.Count -eq 0) { 
            Write-Log -LogLevel WARN -Message "ServiceManager: Intento de ejecucion sin servicios seleccionados."
            [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'servicios.msg_none_selected'), (Get-AIOString 'servicios.notice_title'), 'OK', 'Warning')
            return 
        }

        $actionTxt = if ($Mode -eq 'Disable') { Get-AIOString 'servicios.action_disable' } else { Get-AIOString 'servicios.action_restore' }
        $confirm = [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'servicios.confirm_action' $actionTxt $allChecked.Count), (Get-AIOString 'drivers.confirm_title'), 'YesNo', 'Warning')
        if ($confirm -eq 'No') { 
            Write-Log -LogLevel INFO -Message "ServiceManager: Operacion cancelada por el usuario."
            return 
        }

        Write-Log -LogLevel ACTION -Message "ServiceManager: Iniciando proceso de servicios. Modo: [$Mode] | Cantidad a procesar: $($allChecked.Count)"

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $btnSelectAll.Enabled = $false
        $btnRestore.Enabled = $false
        $btnApply.Enabled = $false

        $progressBar.Value = 0
        $progressBar.Maximum = $allChecked.Count
        $progressBar.Visible = $true

        $successCount = 0
        $errCount = 0
        $count = 0

        try {
            foreach ($item in $allChecked) {
                [System.Windows.Forms.Application]::DoEvents()

                $svcObj = $item.Tag 
                $svcName = $svcObj.Name
                $ctrlSetProc = Get-OfflineControlSet
                $regPath = "Registry::HKLM\OfflineSystem\$ctrlSetProc\Services\$svcName"
                
                $lblStatus.Text = Get-AIOString 'servicios.status_processing' $actionTxt $svcName
                $form.Refresh()

                # Determinar Valor
                $targetVal = 3 
                
                if ($Mode -eq 'Disable') {
                    $targetVal = 4
                } else {
                    switch ($svcObj.DefaultStartupType) {
                        "Automatic" { $targetVal = 2 }
                        "Manual"    { $targetVal = 3 }
                        "Disabled"  { $targetVal = 4 }
                        default     { $targetVal = 3 }
                    }
                }

                Write-Log -LogLevel INFO -Message "ServiceManager: Procesando [$svcName] -> Target Start Value: $targetVal"

                Unlock-Single-Key -SubKeyPath ($regPath -replace "^Registry::HKLM\\", "")

                try {
                    if (-not (Test-Path -LiteralPath $regPath)) { throw (Get-AIOString 'errors.e306') }
                    
                    Set-ItemProperty -Path $regPath -Name "Start" -Value $targetVal -Type DWord -Force -ErrorAction Stop
                    
                    if ($Mode -eq 'Disable') {
                        $item.SubItems[1].Text = Get-AIOString 'servicios.state_disabled'
                        $item.ForeColor = [System.Drawing.Color]::LightGreen
                    } else {
                        $restoredText = if ($targetVal -eq 2) { "Automatico" } else { "Manual" }
                        $item.SubItems[1].Text = Get-AIOString 'servicios.state_restored_fmt' $restoredText
                        $item.ForeColor = [System.Drawing.Color]::Cyan
                    }
                    
                    $item.Checked = $false
                    $successCount++
                    Write-Log -LogLevel INFO -Message "ServiceManager: [$svcName] modificado exitosamente via PowerShell nativo."

                } catch {
                    Write-Log -LogLevel WARN -Message "ServiceManager: Fallo API nativa para [$svcName] - $($_.Exception.Message). Usando fallback reg.exe..."
                    
                    $cmdRegPath = $regPath -replace "^Registry::", ""
                    $proc = Start-Process reg.exe -ArgumentList "add `"$cmdRegPath`" /v Start /t REG_DWORD /d $targetVal /f" -PassThru -WindowStyle Hidden -Wait
                    
                    if ($proc.ExitCode -eq 0) {
                        if ($Mode -eq 'Disable') {
                            $item.SubItems[1].Text = Get-AIOString 'servicios.state_disabled'
                            $item.ForeColor = [System.Drawing.Color]::LightGreen
                        } else {
                            $item.SubItems[1].Text = Get-AIOString 'servicios.state_restored'
                            $item.ForeColor = [System.Drawing.Color]::Cyan
                        }
                        $item.Checked = $false
                        $successCount++
                        Write-Log -LogLevel INFO -Message "ServiceManager: [$svcName] modificado exitosamente usando Fallback (reg.exe)."
                    } else {
                        $errCount++
                        $item.ForeColor = [System.Drawing.Color]::Red
                        $item.SubItems[1].Text = Get-AIOString 'servicios.state_access_error'
                        Write-Log -LogLevel ERROR -Message "ServiceManager: Falla critica para [$svcName]. Fallback reg.exe devolvio codigo: $($proc.ExitCode)"
                    }
                } finally {
                    Restore-KeyOwner -KeyPath $regPath
                    # Contar el objeto solo despues de terminar su procesamiento.
                    $count++
                    $progressBar.Value = [Math]::Min($count, $progressBar.Maximum)
                    $form.Refresh()
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }

            Write-Log -LogLevel ACTION -Message "ServiceManager: Proceso finalizado. Exitos: $successCount | Errores: $errCount"
            $lblStatus.Text = Get-AIOString 'servicios.status_done'
            [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'servicios.msg_report' $successCount $errCount), (Get-AIOString 'servicios.report_title'), 'OK', 'Information')

        } catch {
            Write-Log -LogLevel ERROR -Message "ServiceManager: Error inesperado durante el proceso - $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'servicios.msg_unexpected_err' $_.Exception.Message), (Get-AIOString 'common.error_title'), 'OK', 'Error')
        } finally {
            $progressBar.Visible = $false
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnSelectAll.Enabled = $true
            $btnRestore.Enabled = $true
            $btnApply.Enabled = $true
        }
    }

    # 6. Eventos de Botones
    $btnSelectAll.Add_Click({
        $currentTab = $tabControl.SelectedTab
        if ($currentTab) {
            $lv = $currentTab.Controls[0]
            foreach ($item in $lv.Items) {
                if ($item.SubItems[1].Text -notmatch "Deshabilitado|No Encontrado") {
                    $item.Checked = $true
                }
            }
        }
    })

    $btnApply.Add_Click({ & $ProcessServices -Mode 'Disable' })
    $btnRestore.Add_Click({ & $ProcessServices -Mode 'Restore' })

    # Cierre Seguro
    $form.Add_FormClosing({ 
        if (-not $btnApply.Enabled) {
            [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'servicios.warn_wait_finish'), (Get-AIOString 'drivers.warn_title'), 'OK', 'Warning')
            $_.Cancel = $true
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            (Get-AIOString 'metadata.confirm_exit_body'),
            (Get-AIOString 'metadata.confirm_exit_title'), 
            [System.Windows.Forms.MessageBoxButtons]::YesNo, 
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq 'No') {
            $_.Cancel = $true
        } else {
            $lblStatus.Text = Get-AIOString 'servicios.status_unloading_hives'
            $form.Refresh()
            Start-Sleep -Milliseconds 500
            Unmount-Hives
        }
    })

    $form.ShowDialog() | Out-Null

    if ($null -ne $globalListViews) {
        foreach ($lv in $globalListViews) {
            if ($null -ne $lv.SmallImageList) { 
                $lv.SmallImageList.Dispose() 
            }
            $lv.Dispose()
        }
        $globalListViews.Clear()
        $globalListViews = $null
    }

    if ($null -ne $toolTip) { $toolTip.Dispose() }

    $form.Dispose()

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}