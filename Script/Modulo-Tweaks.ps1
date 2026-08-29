# =================================================================
#  Modulo-Tweaks
#
#  CONTENIDO   : Show-Tweaks-Offline-GUI, Show-RegQueue-GUI, Show-RegPreview-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - $Script:Scratch_DIR    : ruta al directorio temporal
#    - Mount-Hives            : montar colmenas offline del registro
#    - Unmount-Hives          : desmontar colmenas offline del registro
#    - Translate-OfflinePath  : traduce rutas online (HKLM/HKCU) a colmenas offline
#    - Unlock-OfflineKey      : tomar propiedad de una clave o árbol completo
#    - Restore-KeyOwner       : restaurar permisos y herencia
#    - Import-OfflineReg      : inyección de payloads .reg
#    - $PSScriptRoot          : ruta base para localizar Catalogos\Ajustes.ps1
#  CARGA       : . "$PSScriptRoot\Modulo-Tweaks.ps1"
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

function Show-RegPreview-GUI {
    param([string]$FilePath)

    # 1. Configuracion de la Ventana (Optimizada)
    Add-Type -AssemblyName System.Windows.Forms
    $pForm = New-Object System.Windows.Forms.Form
    $pForm.Text = "Vista Previa Rapida - $([System.IO.Path]::GetFileName($FilePath))"
    $pForm.Size = New-Object System.Drawing.Size(1200, 600)
    $pForm.StartPosition = "CenterParent"
    $pForm.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $pForm.ForeColor = [System.Drawing.Color]::White
    $pForm.FormBorderStyle = "FixedDialog"
    $pForm.MaximizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Analizando cambios... (Modo Turbo .NET)"
    $lbl.Location = New-Object System.Drawing.Point(15, 10)
    $lbl.AutoSize = $true
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $pForm.Controls.Add($lbl)

    $lvP = New-Object System.Windows.Forms.ListView
    $lvP.Location = New-Object System.Drawing.Point(15, 40)
    $lvP.Size = New-Object System.Drawing.Size(1150, 480)
    $lvP.View = "Details"
    $lvP.FullRowSelect = $true
    $lvP.GridLines = $true
    $lvP.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $lvP.ForeColor = [System.Drawing.Color]::White
    # Doble buffer para evitar parpadeo
    $lvP.GetType().GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]"NonPublic,Instance").SetValue($lvP, $true, $null)

    $lvP.Columns.Add("Tipo", 80) | Out-Null
    $lvP.Columns.Add("Nombre / Ruta", 550) | Out-Null
    $lvP.Columns.Add("Valor en Imagen (Actual)", 250) | Out-Null
    $lvP.Columns.Add("Valor en Archivo (Nuevo)", 250) | Out-Null

    $pForm.Controls.Add($lvP)

    $btnConfirm = New-Object System.Windows.Forms.Button
    $btnConfirm.Text = "CONFIRMAR IMPORTACION"
    $btnConfirm.Location = New-Object System.Drawing.Point(965, 530)
    $btnConfirm.Size = New-Object System.Drawing.Size(200, 30)
    $btnConfirm.BackColor = [System.Drawing.Color]::SeaGreen
    $btnConfirm.ForeColor = [System.Drawing.Color]::White
    $btnConfirm.DialogResult = "OK"
    $btnConfirm.FlatStyle = "Flat"
    $btnConfirm.Enabled = $false # Deshabilitado hasta terminar carga

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancelar"
    $btnCancel.Location = New-Object System.Drawing.Point(850, 530)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 30)
    $btnCancel.BackColor = [System.Drawing.Color]::Crimson
    $btnCancel.ForeColor = [System.Drawing.Color]::White
    $btnCancel.DialogResult = "Cancel"
    $btnCancel.FlatStyle = "Flat"

    $pForm.Controls.Add($btnConfirm)
    $pForm.Controls.Add($btnCancel)

    # --- LoGICA DE CARGA DE ALTO RENDIMIENTO ---
    $pForm.Add_Shown({
        $pForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lvP.BeginUpdate()
        
        try {
            # 1. Lectura en bloque (IO rapido)
            $lines = [System.IO.File]::ReadAllLines($FilePath)
            
            # 2. Acceso directo al Registro .NET (Bypasseando la capa lenta de PowerShell)
            $baseKey = [Microsoft.Win32.Registry]::LocalMachine
            $currentSubKeyStr = $null
            $currentSubKeyObj = $null

            # Pre-compilacion de Regex para velocidad
            $regKey = [regex]'^\[(-?)(HKEY_.*|HKLM.*|HKCU.*|HKCR.*|HKU.*)\]$'
            $regVal = [regex]'"(.+?)"=(.*)'
            $regDef = [regex]'^@=(.*)'

            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $line = $line.Trim()

                # CASO A: CLAVE
                if ($line -match $regKey) {
                    $isDelete = $matches[1] -eq "-"
                    $keyRaw = $matches[2]
                    
                    # Cerrar clave anterior para liberar memoria
                    if ($currentSubKeyObj) { $currentSubKeyObj.Close(); $currentSubKeyObj = $null }

                    # Traduccion Secuencial Segura (Insensible a mayúsculas/minúsculas)
                    $keyOffline = $keyRaw -replace "(?i)HKEY_LOCAL_MACHINE\\SOFTWARE", "HKLM:\OfflineSoftware" `
                                          -replace "(?i)HKLM\\SOFTWARE", "HKLM:\OfflineSoftware" `
                                          -replace "(?i)HKEY_LOCAL_MACHINE\\SYSTEM", "HKLM:\OfflineSystem" `
                                          -replace "(?i)HKLM\\SYSTEM", "HKLM:\OfflineSystem" `
                                          -replace "(?i)HKEY_CURRENT_USER\\Software\\Classes", "HKLM:\OfflineUserClasses" `
                                          -replace "(?i)HKCU\\Software\\Classes", "HKLM:\OfflineUserClasses" `
                                          -replace "(?i)HKEY_CURRENT_USER", "HKLM:\OfflineUser" `
                                          -replace "(?i)HKCU", "HKLM:\OfflineUser" `
                                          -replace "(?i)HKEY_CLASSES_ROOT", "HKLM:\OfflineSoftware\Classes" `
                                          -replace "(?i)HKCR", "HKLM:\OfflineSoftware\Classes" `
                                          -replace "(?i)HKEY_USERS\\\.DEFAULT", "HKLM:\OfflineDefaultUser" `
                                          -replace "(?i)HKU\\\.DEFAULT", "HKLM:\OfflineDefaultUser"

                    if ($keyOffline -match "(?i)OfflineSystem\\CurrentControlSet|OfflineSystem\\ControlSet\d{3}") {
                        $cs = Get-OfflineControlSet
                        $keyOffline = $keyOffline -replace "(?i)CurrentControlSet|ControlSet\d{3}", $cs
                    }

                    $relPath = $keyOffline -replace "^HKLM:\\", ""
                    $currentSubKeyStr = $relPath

                    $exists = $false
                    try {
                        $currentSubKeyObj = $baseKey.OpenSubKey($relPath, $false) 
                        if ($currentSubKeyObj) { $exists = $true }
                    } catch {}

                    $item = New-Object System.Windows.Forms.ListViewItem("CLAVE")
                    $item.SubItems.Add($keyRaw) | Out-Null
                    
                    if ($isDelete) {
                        $item.SubItems.Add("EXISTE") | Out-Null
                        $item.SubItems.Add(">>> ELIMINAR <<<") | Out-Null
                        $item.ForeColor = [System.Drawing.Color]::Salmon
                    } else {
                        $item.SubItems.Add( $(if($exists){"EXISTE"}else{"NUEVA"}) ) | Out-Null
                        $item.SubItems.Add("-") | Out-Null
                        $item.ForeColor = [System.Drawing.Color]::Yellow
                    }
                    $lvP.Items.Add($item) | Out-Null
                }
                
                # CASO B: VALOR NOMBRADO ("Nombre"="Valor")
                elseif ($currentSubKeyStr -and $line -match $regVal) {
                    $valName = $matches[1]
                    $newVal = $matches[2]
                    $currVal = "No existe"
                    
                    if ($currentSubKeyObj) {
                        $raw = $currentSubKeyObj.GetValue($valName, $null)
                        if ($null -ne $raw) {
                            $currVal = $raw.ToString()
                        }
                    }

                    $item = New-Object System.Windows.Forms.ListViewItem("   Valor")
                    $item.SubItems.Add($valName) | Out-Null
                    $item.SubItems.Add("$currVal") | Out-Null
                    $item.SubItems.Add("$newVal") | Out-Null

                    $normalNew = $newVal
                    if ($newVal -match '^dword:([0-9a-fA-F]{1,8})$') {
                        $uintParsed = [Convert]::ToUInt32($matches[1], 16)
                        $normalNew  = [BitConverter]::ToInt32([BitConverter]::GetBytes($uintParsed), 0).ToString()
                    } elseif ($newVal -match '^"(.*)"$') {
                        $normalNew = $matches[1]
                    } elseif ($newVal -match '^qword:([0-9a-fA-F]{1,16})$') {
                        $uint64Parsed = [Convert]::ToUInt64($matches[1], 16)
                        $normalNew    = [BitConverter]::ToInt64([BitConverter]::GetBytes($uint64Parsed), 0).ToString()
                    }

                    if ($currVal -eq $normalNew) {
                        $item.ForeColor = [System.Drawing.Color]::Silver   
                    } else {
                        $item.ForeColor = [System.Drawing.Color]::Cyan   
                    }
                    $lvP.Items.Add($item) | Out-Null
                }

                # CASO C: VALOR POR DEFECTO (@="Valor")
                elseif ($currentSubKeyStr -and $line -match $regDef) {
                    $valName = "(Predeterminado)"
                    $newVal = $matches[1]
                    $currVal = "No existe"

                    if ($currentSubKeyObj) {
                        $raw = $currentSubKeyObj.GetValue("", $null) 
                        if ($null -ne $raw) {
                            $currVal = $raw.ToString()
                        }
                    }

                    $item = New-Object System.Windows.Forms.ListViewItem("   Valor")
                    $item.SubItems.Add($valName) | Out-Null
                    $item.SubItems.Add("$currVal") | Out-Null
                    $item.SubItems.Add("$newVal") | Out-Null
                    $item.ForeColor = [System.Drawing.Color]::Cyan
                    $lvP.Items.Add($item) | Out-Null
                }
            }

            if ($currentSubKeyObj) { $currentSubKeyObj.Close() }
            
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error leyendo vista previa: $_", "Error", 'OK', 'Error')
        } finally {
            $lvP.EndUpdate()
            $pForm.Cursor = [System.Windows.Forms.Cursors]::Default
            $lbl.Text = "Analisis completado."
            $btnConfirm.Enabled = $true
        }
    })

    try {
        return ($pForm.ShowDialog() -eq 'OK')
    } finally {
        $pForm.Dispose()
    }
}

#  Modulo GUI: Gestor de Cola de Registro y Perfiles (.REG)
function Show-RegQueue-GUI {
    Add-Type -AssemblyName System.Windows.Forms

    if ($Script:IMAGE_MOUNTED -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return
    }

    Add-Type -AssemblyName System.Drawing

    $frmQ = New-Object System.Windows.Forms.Form
    $frmQ.Text = "Gestor de Importacion en Lote y Perfiles (.REG)"
    $frmQ.Size = New-Object System.Drawing.Size(950, 650)
    $frmQ.StartPosition = "CenterParent"
    $frmQ.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $frmQ.ForeColor = [System.Drawing.Color]::White
    $frmQ.FormBorderStyle = "FixedDialog"
    $frmQ.MaximizeBox = $false

    $lblQ = New-Object System.Windows.Forms.Label
    $lblQ.Text = "Cola de Procesamiento de Registro"
    $lblQ.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblQ.Location = "20, 15"; $lblQ.AutoSize = $true
    $frmQ.Controls.Add($lblQ)

    # ListView para la cola
    $lvQ = New-Object System.Windows.Forms.ListView
    $lvQ.Location = "20, 50"
    $lvQ.Size = "890, 400"
    $lvQ.View = "Details"
    $lvQ.FullRowSelect = $true
    $lvQ.GridLines = $true
    $lvQ.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $lvQ.ForeColor = [System.Drawing.Color]::White
    $lvQ.HideSelection = $false

    $lvQ.Columns.Add("Estado", 140) | Out-Null
    $lvQ.Columns.Add("Archivo", 250) | Out-Null
    $lvQ.Columns.Add("Ruta Completa", 480) | Out-Null
    $frmQ.Controls.Add($lvQ)

    # --- BOTONES DE CONTROL DE COLA ---
    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = "+ Agregar"
    $btnAdd.Location = "20, 460"
    $btnAdd.Size = "100, 35"
    $btnAdd.BackColor = [System.Drawing.Color]::RoyalBlue
    $btnAdd.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnAdd)

    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = "- Quitar"
    $btnRemove.Location = "130, 460"
    $btnRemove.Size = "100, 35"
    $btnRemove.BackColor = [System.Drawing.Color]::Crimson
    $btnRemove.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnRemove)

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = "Limpiar"
    $btnClear.Location = "240, 460"
    $btnClear.Size = "100, 35"
    $btnClear.BackColor = [System.Drawing.Color]::Gray
    $btnClear.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnClear)

    $btnPreview = New-Object System.Windows.Forms.Button
    $btnPreview.Text = "Auditar (Vista Previa)"
    $btnPreview.Location = "350, 460"
    $btnPreview.Size = "160, 35"
    $btnPreview.BackColor = [System.Drawing.Color]::Teal
    $btnPreview.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnPreview)

    # --- NUEVOS BOTONES DE PERFIL ---
    $btnLoadProfile = New-Object System.Windows.Forms.Button
    $btnLoadProfile.Text = "Cargar Perfil"
    $btnLoadProfile.Location = "20, 510"
    $btnLoadProfile.Size = "140, 35"
    $btnLoadProfile.BackColor = [System.Drawing.Color]::DarkOrchid
    $btnLoadProfile.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnLoadProfile)

    $btnSaveProfile = New-Object System.Windows.Forms.Button
    $btnSaveProfile.Text = "Guardar Perfil"
    $btnSaveProfile.Location = "170, 510"
    $btnSaveProfile.Size = "140, 35"
    $btnSaveProfile.BackColor = [System.Drawing.Color]::Indigo
    $btnSaveProfile.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnSaveProfile)

    # --- BOTON DE PROCESO ---
    $btnProcess = New-Object System.Windows.Forms.Button
    $btnProcess.Text = "PROCESAR LOTE MAESTRO"
    $btnProcess.Location = "640, 470"
    $btnProcess.Size = "270, 60"
    $btnProcess.BackColor = [System.Drawing.Color]::SeaGreen
    $btnProcess.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnProcess.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnProcess)

    $progressBarQ = New-Object System.Windows.Forms.ProgressBar
    $progressBarQ.Location = "20, 550"
    $progressBarQ.Size = "890, 15"
    $progressBarQ.Style = "Continuous"
    $progressBarQ.Visible = $false
    $frmQ.Controls.Add($progressBarQ)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Agregue archivos o cargue un perfil para comenzar."
    $lblStatus.Location = "20, 570"
    $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
    $frmQ.Controls.Add($lblStatus)

    # --- EVENTOS BÁSICOS ---
    $btnAdd.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Archivos de Registro (*.reg)|*.reg"
        $ofd.Multiselect = $true
        
        if ($ofd.ShowDialog() -eq 'OK') {
            $lvQ.BeginUpdate()
            foreach ($file in $ofd.FileNames) {
                $exists = $false
                foreach ($item in $lvQ.Items) {
                    if ($item.Tag -eq $file) { $exists = $true; break }
                }
                
                if (-not $exists) {
                    $newItem = New-Object System.Windows.Forms.ListViewItem("EN ESPERA")
                    $newItem.SubItems.Add([System.IO.Path]::GetFileName($file)) | Out-Null
                    $newItem.SubItems.Add($file) | Out-Null
                    $newItem.ForeColor = [System.Drawing.Color]::Yellow
                    $newItem.Tag = $file
                    $lvQ.Items.Add($newItem) | Out-Null
                }
            }
            $lvQ.EndUpdate()
            $lblStatus.Text = "Archivos en cola: $($lvQ.Items.Count)"
        }
    })

    $btnRemove.Add_Click({
        foreach ($item in $lvQ.SelectedItems) { $lvQ.Items.Remove($item) }
        $lblStatus.Text = "Archivos en cola: $($lvQ.Items.Count)"
    })

    $btnClear.Add_Click({
        $lvQ.Items.Clear()
        $lblStatus.Text = "Cola vacia."
    })

    $btnPreview.Add_Click({
        if ($lvQ.SelectedItems.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show("Selecciona exactamente un (1) archivo de la lista para auditarlo.", "Aviso", 'OK', 'Warning')
            return
        }
        $selectedFilePath = $lvQ.SelectedItems[0].Tag
        $null = Show-RegPreview-GUI -FilePath $selectedFilePath
    })

    # --- EVENTOS DE PERFIL ---
    $btnSaveProfile.Add_Click({
        if ($lvQ.Items.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("La cola esta vacia. Agrega archivos primero.", "Aviso", 'OK', 'Warning')
            return
        }
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = "Perfil de Tweaks (*.txt)|*.txt"
        $sfd.FileName = "MiPerfilTweaks.txt"
        
        if ($sfd.ShowDialog() -eq 'OK') {
            $rutas = @()
            foreach ($item in $lvQ.Items) { $rutas += $item.Tag }
            
            try {
                $rutas | Out-File -FilePath $sfd.FileName -Encoding utf8
                $lblStatus.Text = "Perfil guardado correctamente."
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Error al guardar el perfil: $_", "Error", 'OK', 'Error')
            }
        }
    })

    $btnLoadProfile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Perfil de Tweaks (*.txt)|*.txt"
        
        if ($ofd.ShowDialog() -eq 'OK') {
            try {
                $rutas = Get-Content $ofd.FileName
                $lvQ.BeginUpdate()
                
                $cargados = 0
                $omitidos = 0
                
                foreach ($ruta in $rutas) {
                    if ([string]::IsNullOrWhiteSpace($ruta)) { continue }
                    
                    if (-not (Test-Path -LiteralPath $ruta)) {
                        $omitidos++
                        continue
                    }

                    $exists = $false
                    foreach ($item in $lvQ.Items) {
                        if ($item.Tag -eq $ruta) { $exists = $true; break }
                    }
                    
                    if (-not $exists) {
                        $newItem = New-Object System.Windows.Forms.ListViewItem("EN ESPERA")
                        $newItem.SubItems.Add([System.IO.Path]::GetFileName($ruta)) | Out-Null
                        $newItem.SubItems.Add($ruta) | Out-Null
                        $newItem.ForeColor = [System.Drawing.Color]::Yellow
                        $newItem.Tag = $ruta
                        $lvQ.Items.Add($newItem) | Out-Null
                        $cargados++
                    }
                }
                $lvQ.EndUpdate()
                
                $lblStatus.Text = "Perfil cargado. Archivos en cola: $($lvQ.Items.Count)"
                if ($omitidos -gt 0) {
                    [System.Windows.Forms.MessageBox]::Show("Se omitieron $omitidos archivos porque ya no existen en la ruta guardada.", "Aviso de Perfil", 'OK', 'Information')
                }
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Error al leer el perfil: $_", "Error", 'OK', 'Error')
            }
        }
    })

    # --- EVENTO MAESTRO ---
    $btnProcess.Add_Click({
        if ($lvQ.Items.Count -eq 0) { return }

        $res = [System.Windows.Forms.MessageBox]::Show("Se importaran $($lvQ.Items.Count) archivos utilizando el motor de streaming seguro.`nDesea continuar?", "Confirmar Lote", 'YesNo', 'Question')
        if ($res -ne 'Yes') { return }

        $Script:SDDL_Backups.Clear()

        Write-Log -LogLevel ACTION -Message "RegBatch: Iniciando procesamiento en lote delegando a Import-OfflineReg."

        $btnAdd.Enabled = $false; $btnRemove.Enabled = $false; $btnClear.Enabled = $false; $btnPreview.Enabled = $false; $btnLoadProfile.Enabled = $false; $btnSaveProfile.Enabled = $false; $btnProcess.Enabled = $false
        $frmQ.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        $progressBarQ.Maximum = $lvQ.Items.Count
        $progressBarQ.Value = 0
        $progressBarQ.Visible = $true
        
        $errors = 0
        $success = 0
        $count = 0

        try {
            foreach ($item in $lvQ.Items) {
                if ($item.Text -ne "EN ESPERA" -and $item.Text -ne "ERROR LECTURA") { continue }
                
                $count++
                $progressBarQ.Value = [Math]::Min($count, $progressBarQ.Maximum)
                
                $item.Text = "PROCESANDO"
                $item.ForeColor = [System.Drawing.Color]::Cyan
                $item.EnsureVisible()
                $frmQ.Refresh()
                [System.Windows.Forms.Application]::DoEvents()

                try {
                    Import-OfflineReg -FilePath $item.Tag
                    
                    $item.Text = "COMPLETADO"
                    $item.ForeColor = [System.Drawing.Color]::LightGreen
                    $success++
                } catch {
                    $item.Text = "ERROR"
                    $item.ForeColor = [System.Drawing.Color]::Red
                    $errors++
                    Write-Log -LogLevel ERROR -Message "RegBatch: Fallo la inyeccion de $($item.Tag) - $($_.Exception.Message)"
                }
            }

            if ($Script:SDDL_Backups.Count -gt 0) {
                Write-Log -LogLevel INFO -Message "RegBatch: Restaurando permisos SDDL diferidos..."
                Restore-AllOfflineSDDL
            }

            Write-Log -LogLevel INFO -Message "RegBatch: Lote finalizado. Exitos: $success, Errores: $errors."
            $lblStatus.Text = "Procesamiento finalizado."
            [System.Windows.Forms.MessageBox]::Show("Lote procesado.`nExitos: $success`nErrores: $errors", "Informe", 'OK', 'Information')

        } catch {
            Write-Log -LogLevel ERROR -Message "RegBatch: Caída fatal del bucle maestro - $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Error inesperado en el bucle: $_", "Error", 'OK', 'Error')
        } finally {
            $progressBarQ.Visible = $false
            $frmQ.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnAdd.Enabled = $true; $btnRemove.Enabled = $true; $btnClear.Enabled = $true; $btnPreview.Enabled = $true; $btnLoadProfile.Enabled = $true; $btnSaveProfile.Enabled = $true; $btnProcess.Enabled = $true
        }
    })

    $frmQ.Add_FormClosing({
        if (-not $btnProcess.Enabled) {
            [System.Windows.Forms.MessageBox]::Show("Hay un lote en proceso. Espera a que finalice antes de cerrar.", "Advertencia", 'OK', 'Warning')
            $_.Cancel = $true
        }
    })

    $frmQ.ShowDialog() | Out-Null
    $frmQ.Dispose()
    [GC]::Collect()
}

# =================================================================
#  Show-Tweaks-Offline-GUI
# =================================================================
function Show-Tweaks-Offline-GUI {
    Add-Type -AssemblyName System.Windows.Forms

    # 1. Validaciones Previas
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return 
    }

    # 2. Cargar Catalogo
    $tweaksFile = Join-Path $PSScriptRoot "Catalogos\Ajustes.ps1"
    if (-not (Test-Path $tweaksFile)) { $tweaksFile = Join-Path $PSScriptRoot "Ajustes.ps1" }
    if (Test-Path $tweaksFile) { . $tweaksFile } else { Write-Warning "Falta Ajustes.ps1"; return }

    # 3. Montar Hives
    if (-not (Mount-Hives)) { return }

    # --- INICIO DE CONSTRUCCION GUI ---
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Collections 

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Optimizacion de Registro Offline (WIM) - $Script:MOUNT_DIR"
    $form.Size = New-Object System.Drawing.Size(1200, 800) 
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 5000
    $toolTip.InitialDelay = 500
    $toolTip.ReshowDelay = 500
    $toolTip.ShowAlways = $true

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Gestor de Ajustes y Registro"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 10)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    $btnImport = New-Object System.Windows.Forms.Button
    $btnImport.Text = "IMPORTAR ARCHIVO .REG..."
    $btnImport.Location = New-Object System.Drawing.Point(950, 10)
    $btnImport.Size = New-Object System.Drawing.Size(200, 35)
    $btnImport.BackColor = [System.Drawing.Color]::RoyalBlue
    $btnImport.ForeColor = [System.Drawing.Color]::White
    $btnImport.FlatStyle = "Flat"
    $form.Controls.Add($btnImport)
    
    $Script:AnalyzeRegToString = {
        param($filePath)
        $report = "--- RESUMEN DE CAMBIOS ---`n"
        $lines = Get-Content $filePath -Encoding Unicode
        $currentKeyOffline = $null

        foreach ($line in $lines) {
            $line = $line.Trim()
            if ($line -match "^\[(-?)(HKEY_.*|HKLM.*|HKCU.*|HKU.*)\]$") {
                $isDelete = $matches[1] -eq "-"
                $keyRaw = $matches[2]
                
                $keyOffline = $keyRaw.Replace("HKEY_LOCAL_MACHINE\SOFTWARE", "HKLM:\OfflineSoftware")
                $keyOffline = $keyOffline.Replace("HKLM\SOFTWARE", "HKLM:\OfflineSoftware")
                $keyOffline = $keyOffline.Replace("HKEY_LOCAL_MACHINE\SYSTEM", "HKLM:\OfflineSystem")
                $keyOffline = $keyOffline.Replace("HKLM\SYSTEM", "HKLM:\OfflineSystem")
                $keyOffline = $keyOffline.Replace("HKEY_CURRENT_USER", "HKLM:\OfflineUser")
                $keyOffline = $keyOffline.Replace("HKCU", "HKLM:\OfflineUser")
                $keyOffline = $keyOffline.Replace("HKEY_USERS\.DEFAULT", "HKLM:\OfflineDefaultUser")
                $keyOffline = $keyOffline.Replace("HKU\.DEFAULT", "HKLM:\OfflineDefaultUser")

                if (-not $keyOffline.StartsWith("HKLM:\")) { $keyOffline = $keyOffline -replace "^HKLM\\", "HKLM:\" }
                $currentKeyOffline = $keyOffline

                $existStr = if (Test-Path -LiteralPath $currentKeyOffline) { "(EXISTE)" } else { "(NUEVA)" }
                $report += "`n[CLAVE] $keyRaw $existStr`n"
            }
            elseif ($currentKeyOffline -and $line -match '^"(.+?)"=(.*)') {
                $valName = $matches[1]
                $newVal = $matches[2]
                $currVal = "No existe"
                try {
                    if (Test-Path -LiteralPath $currentKeyOffline) {
                        $p = Get-ItemProperty -LiteralPath $currentKeyOffline -Name $valName -ErrorAction SilentlyContinue
                        if ($p) { $currVal = $p.$valName }
                    }
                } catch {}
                $report += "   VALOR: $valName | Actual: $currVal -> Nuevo: $newVal`n"
            }
        }
        return $report
    }

    $btnImport.Add_Click({
        Show-RegQueue-GUI
    })

    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = New-Object System.Drawing.Point(20, 60)
    $tabControl.Size = New-Object System.Drawing.Size(1140, 520)
    $tabControl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($tabControl)

    $pnlActions = New-Object System.Windows.Forms.Panel
    $pnlActions.Location = New-Object System.Drawing.Point(20, 650)
    $pnlActions.Size = New-Object System.Drawing.Size(1140, 100)
    $pnlActions.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $pnlActions.BorderStyle = "FixedSingle"
    $form.Controls.Add($pnlActions)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Selecciona ajustes en varias pestanas y aplica todo al final."
    $lblStatus.Location = New-Object System.Drawing.Point(10, 10)
    $lblStatus.AutoSize = $true
    $lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $pnlActions.Controls.Add($lblStatus)

    $btnSelectAllGlobal = New-Object System.Windows.Forms.Button
    $btnSelectAllGlobal.Text = "Marcar Todo"
    $btnSelectAllGlobal.Location = New-Object System.Drawing.Point(10, 40)
    $btnSelectAllGlobal.Size = New-Object System.Drawing.Size(160, 40)
    $btnSelectAllGlobal.BackColor = [System.Drawing.Color]::Gray
    $btnSelectAllGlobal.FlatStyle = "Flat"
    $toolTip.SetToolTip($btnSelectAllGlobal, "Solo se seleccionaran los elementos visibles en la PESTANA ACTUAL.")
    $pnlActions.Controls.Add($btnSelectAllGlobal)

    $btnSelectInactive = New-Object System.Windows.Forms.Button
    $btnSelectInactive.Text = "Marcar Inactivos"
    $btnSelectInactive.Location = New-Object System.Drawing.Point(180, 40)
    $btnSelectInactive.Size = New-Object System.Drawing.Size(160, 40)
    $btnSelectInactive.BackColor = [System.Drawing.Color]::DimGray
    $btnSelectInactive.ForeColor = [System.Drawing.Color]::White
    $btnSelectInactive.FlatStyle = "Flat"
    $toolTip.SetToolTip($btnSelectInactive, "Solo se seleccionaran los elementos visibles en la PESTANA ACTUAL.")
    $pnlActions.Controls.Add($btnSelectInactive)

    $btnRestoreGlobal = New-Object System.Windows.Forms.Button
    $btnRestoreGlobal.Text = "RESTAURAR VALORES"
    $btnRestoreGlobal.Location = New-Object System.Drawing.Point(450, 40)
    $btnRestoreGlobal.Size = New-Object System.Drawing.Size(320, 40)
    $btnRestoreGlobal.BackColor = [System.Drawing.Color]::FromArgb(200, 100, 0)
    $btnRestoreGlobal.ForeColor = [System.Drawing.Color]::White
    $btnRestoreGlobal.FlatStyle = "Flat"
    $btnRestoreGlobal.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $pnlActions.Controls.Add($btnRestoreGlobal)

    $btnApplyGlobal = New-Object System.Windows.Forms.Button
    $btnApplyGlobal.Text = "APLICAR SELECCION"
    $btnApplyGlobal.Location = New-Object System.Drawing.Point(790, 40)
    $btnApplyGlobal.Size = New-Object System.Drawing.Size(320, 40)
    $btnApplyGlobal.BackColor = [System.Drawing.Color]::SeaGreen
    $btnApplyGlobal.ForeColor = [System.Drawing.Color]::White
    $btnApplyGlobal.FlatStyle = "Flat"
    $btnApplyGlobal.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $pnlActions.Controls.Add($btnApplyGlobal)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(10, 85)
    $progressBar.Size = New-Object System.Drawing.Size(1120, 10)
    $progressBar.Style = "Continuous"
    $progressBar.Visible = $false
    $pnlActions.Controls.Add($progressBar)

    $txtTweakDesc = New-Object System.Windows.Forms.TextBox
    $txtTweakDesc.Location = New-Object System.Drawing.Point(20, 590)
    $txtTweakDesc.Size = New-Object System.Drawing.Size(1140, 50)
    $txtTweakDesc.Multiline = $true
    $txtTweakDesc.ReadOnly = $true
    $txtTweakDesc.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $txtTweakDesc.ForeColor = [System.Drawing.Color]::White
    $txtTweakDesc.BorderStyle = "FixedSingle"
    $txtTweakDesc.Text = "Seleccione un ajuste para ver los detalles..."
    $form.Controls.Add($txtTweakDesc)

    $globalListViews = New-Object System.Collections.Generic.List[System.Windows.Forms.ListView]

    $form.Add_Shown({
        $form.Refresh()
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        $validTweaks = @()
        foreach ($t in $script:SystemTweaks) {
            if ($t.Method -eq "Registry" -or $t.Method -eq "RegistryPayload") {
                $validTweaks += $t
            }
        }
        
        $cats = $validTweaks | Select-Object -ExpandProperty Category -Unique | Sort-Object
        $tabControl.SuspendLayout()

        foreach ($cat in $cats) {
            $tp = New-Object System.Windows.Forms.TabPage
            $tp.Text = "  $cat  "
            $tp.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)

            $lv = New-Object System.Windows.Forms.ListView
            $lv.Dock = "Fill"
            $lv.View = "Details"
            $lv.CheckBoxes = $true
            $lv.FullRowSelect = $true
            $lv.GridLines = $true
            $lv.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
            $lv.ForeColor = [System.Drawing.Color]::White

            $lv.Columns.Add("Ajuste", 450) | Out-Null
            $lv.Columns.Add("Estado Actual", 120) | Out-Null
            $lv.Columns.Add("Tipo", 100) | Out-Null

            $lv.Add_SelectedIndexChanged({
                if ($this.SelectedItems.Count -gt 0) {
                    $txtTweakDesc.Text = $this.SelectedItems[0].Tag.Description
                }
            })

            foreach ($tw in $validTweaks) {
                if ($tw.Category -eq $cat) {
                    $target = if ($tw.Method -eq "RegistryPayload") { $tw.PrimaryPath } else { $tw.RegistryPath }
                    $pathRaw = Translate-OfflinePath -OnlinePath $target
                    
                    if ($pathRaw) {
                        $item = New-Object System.Windows.Forms.ListViewItem($tw.Name)
                        $psPath = $pathRaw -replace "^HKLM\\", "HKLM:\"
                        $state = "INACTIVO"
                        
                        try {
                            if ($tw.Method -eq "RegistryPayload") {
                                if ($null -eq $tw.PrimaryValue -or $tw.PrimaryValue -eq "") {
                                    if (Test-Path -LiteralPath $psPath) { $state = "ACTIVO" }
                                } else {
                                    $val = (Get-ItemProperty -LiteralPath $psPath -Name $tw.PrimaryValue -ErrorAction SilentlyContinue).($tw.PrimaryValue)
                                    if ("$val" -eq "$($tw.ExpectedData)") { $state = "ACTIVO" }
                                }
                            } else {
                                $val = (Get-ItemProperty -LiteralPath $psPath -Name $tw.RegistryKey -ErrorAction SilentlyContinue).($tw.RegistryKey)
                                if ("$val" -eq "$($tw.EnabledValue)") { $state = "ACTIVO" }
                            }
                        } catch {}

                        $item.SubItems.Add($state) | Out-Null
                        $item.SubItems.Add($tw.Method) | Out-Null
                        $item.Tag = $tw 
                        if ($state -eq "ACTIVO") { $item.ForeColor = [System.Drawing.Color]::Cyan }
                        
                        $lv.Items.Add($item) | Out-Null
                    }
                }
            }
            $tp.Controls.Add($lv)
            $tabControl.TabPages.Add($tp)
            $globalListViews.Add($lv)
        }
        $tabControl.ResumeLayout()
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    })

    $btnSelectAllGlobal.Add_Click({
        $currentTab = $tabControl.SelectedTab
        if ($currentTab) {
            $lv = $currentTab.Controls[0] 
            
            $allChecked = ($lv.CheckedItems.Count -eq $lv.Items.Count) -and ($lv.Items.Count -gt 0)
            
            $lv.BeginUpdate()
            foreach ($item in $lv.Items) {
                $item.Checked = -not $allChecked
            }
            $lv.EndUpdate()
        }
    })

    $btnSelectInactive.Add_Click({
        $currentTab = $tabControl.SelectedTab
        if ($currentTab) {
            $lv = $currentTab.Controls[0]
            
            $lv.BeginUpdate()
            foreach ($item in $lv.Items) {
                if ($item.SubItems[1].Text -ne "ACTIVO") {
                    $item.Checked = $true
                }
            }
            $lv.EndUpdate()
        }
    })

    $ProcessChanges = {
        param($Mode) 

        Write-Log -LogLevel INFO -Message "Tweak_Engine: Recopilando elementos marcados para la operacion ($Mode)."
        
        $allCheckedItems = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
        foreach ($lv in $globalListViews) {
            foreach ($item in $lv.CheckedItems) {
                $allCheckedItems.Add($item)
            }
        }

        if ($allCheckedItems.Count -eq 0) {
            Write-Log -LogLevel WARN -Message "Tweak_Engine: El usuario intento iniciar el proceso sin seleccionar ningun ajuste."
            [System.Windows.Forms.MessageBox]::Show("No hay ajustes seleccionados.", "Aviso", 'OK', 'Warning')
            return
        }

        $msgTitle = if ($Mode -eq 'Apply') { "Aplicar Cambios" } else { "Restaurar Cambios" }
        $confirm = [System.Windows.Forms.MessageBox]::Show("Se Aplicaran $($allCheckedItems.Count) ajustes en TOTAL.`nDeseas continuar?", $msgTitle, 'YesNo', 'Question')
        if ($confirm -eq 'No') { 
            Write-Log -LogLevel INFO -Message "Tweak_Engine: Operacion cancelada por el usuario en el cuadro de confirmacion."
            return 
        }

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $btnApplyGlobal.Enabled = $false
        $btnRestoreGlobal.Enabled = $false
        $btnSelectAllGlobal.Enabled = $false
        $btnSelectInactive.Enabled = $false
        
        $progressBar.Maximum = $allCheckedItems.Count
        $progressBar.Value = 0
        $progressBar.Visible = $true

        $lblStatus.Text = "Procesando registro... ($Mode)"
        $form.Refresh()

        $Script:SDDL_Backups.Clear()

        Write-Log -LogLevel ACTION -Message "Tweak_Engine: Iniciando procesamiento de $($allCheckedItems.Count) claves de registro. Modo: [$Mode]"

        $errors = 0
        $success = 0
        $count = 0

        $hiveObj = [Microsoft.Win32.Registry]::LocalMachine

        try {
            foreach ($it in $allCheckedItems) {
                $count++
                $progressBar.Value = [Math]::Min($count, $progressBar.Maximum)
                
                $t = $it.Tag 
                $targetPath = if ($t.Method -eq "RegistryPayload") { $t.PrimaryPath } else { $t.RegistryPath }
                $pathRaw = Translate-OfflinePath -OnlinePath $targetPath
                
                if ($pathRaw) {
                    $psPath = $pathRaw -replace "^HKLM\\", "HKLM:\"
                    $subPathNet = $pathRaw -replace "^HKLM\\", "" 

                    if ($t.Method -eq "RegistryPayload") {
                        try {
                            if ($Mode -eq 'Apply') {
                                $tempReg = Join-Path $Script:Scratch_DIR "payload_apply_$([Guid]::NewGuid().ToString('N')).reg"
                                [System.IO.File]::WriteAllText($tempReg, $t.PayloadApply, [System.Text.Encoding]::Unicode)
                                
                                Import-OfflineReg -FilePath $tempReg
                                Remove-Item $tempReg -Force -ErrorAction SilentlyContinue

                                $it.SubItems[1].Text = "ACTIVO"
                                $it.ForeColor = [System.Drawing.Color]::Cyan
                            } 
                            else {
                                if ($t.PayloadRestore -eq "DeleteKey") {
                                    $lastSlashIdx = $subPathNet.LastIndexOf("\")
                                    if ($lastSlashIdx -gt 0) {
                                        $parentPathNet = $subPathNet.Substring(0, $lastSlashIdx)
                                        $parentPathPS = "HKLM:\$parentPathNet"
                                        
                                        Unlock-OfflineKey -KeyPath $parentPathPS
                                        Unlock-OfflineKey -KeyPath $psPath

                                        $checkKey = $hiveObj.OpenSubKey($subPathNet)
                                        if ($null -ne $checkKey) {
                                            $checkKey.Close() 
                                            $hiveObj.DeleteSubKeyTree($subPathNet)
                                            Write-Log -LogLevel INFO -Message "Tweak_Engine: Arbol de Payload borrado -> $subPathNet"
                                        }
                                        Restore-KeyOwner -KeyPath $parentPathPS
                                    }
                                } 
                                else {
                                    if ([string]::IsNullOrWhiteSpace($t.PayloadRestore)) {
                                        throw "El ajuste $($t.Name) no tiene definido un codigo de restauracion."
                                    }
                                    $tempReg = Join-Path $Script:Scratch_DIR "payload_restore_$([Guid]::NewGuid().ToString('N')).reg"
                                    [System.IO.File]::WriteAllText($tempReg, $t.PayloadRestore, [System.Text.Encoding]::Unicode)
                                    
                                    Import-OfflineReg -FilePath $tempReg
                                    Remove-Item $tempReg -Force -ErrorAction SilentlyContinue
                                    Write-Log -LogLevel INFO -Message "Tweak_Engine: Payload revertido vía inyección .reg -> $subPathNet"
                                }

                                $it.SubItems[1].Text = "RESTAURADO"
                                $it.ForeColor = [System.Drawing.Color]::Silver
                            }
                            $it.Checked = $false 
                            $success++
                            [System.Windows.Forms.Application]::DoEvents()
                        } catch {
                            $errors++
                            $it.SubItems[1].Text = "ERROR"
                            $it.ForeColor = [System.Drawing.Color]::Red
                            Write-Log -LogLevel ERROR -Message "Tweak_Engine: Falla procesando Payload $($t.Name) - $($_.Exception.Message)"
                        }
                        continue 
                    }

                    $valToSet = $null
                    $isDeleteProperty = $false
                    $isDeleteKey = $false

                    if ($Mode -eq 'Apply') {
                        $valToSet = $t.EnabledValue
                    } else {
                        $valToSet = $t.DefaultValue
                        if ($valToSet -eq "DeleteKey") { $isDeleteKey = $true }
                        elseif ($valToSet -eq "DeleteValue") { $isDeleteProperty = $true }
                    }

                    if ($isDeleteKey) {
                        $parentPathPS = $null
                        try {
                            $lastSlashIdx = $subPathNet.LastIndexOf("\")
                            if ($lastSlashIdx -gt 0) {
                                $parentPathNet = $subPathNet.Substring(0, $lastSlashIdx)
                                $parentPathPS  = "HKLM:\$parentPathNet"

                                Unlock-OfflineKey -KeyPath $parentPathPS
                                Unlock-OfflineKey -KeyPath $psPath

                                $checkKey = $hiveObj.OpenSubKey($subPathNet)
                                if ($null -ne $checkKey) {
                                    $checkKey.Close()
                                    $hiveObj.DeleteSubKeyTree($subPathNet)
                                    Write-Log -LogLevel INFO -Message "Tweak_Engine: Arbol borrado nativamente -> $subPathNet"
                                }
                            }
                            $it.SubItems[1].Text = "RESTAURADO"
                            $it.ForeColor = [System.Drawing.Color]::Silver
                            $it.Checked = $false
                            $success++
                            [System.Windows.Forms.Application]::DoEvents()
                        } catch {
                            $errors++
                            $it.SubItems[1].Text = "ERROR"
                            $it.ForeColor = [System.Drawing.Color]::Red
                            Write-Log -LogLevel ERROR -Message "Tweak_Engine: Falla borrando clave $($t.Name) - $($_.Exception.Message)"
                        } finally {
                            if ($null -ne $parentPathPS) { Restore-KeyOwner -KeyPath $parentPathPS }
                        }
                        continue
                    }

                    $keyObj = $null
                    try {
                        Unlock-OfflineKey -KeyPath $psPath

                        $keyObj = $hiveObj.CreateSubKey($subPathNet)

                        if ($null -ne $keyObj) {
                            $targetRegKey = $t.RegistryKey

                            if ($targetRegKey -match "^\(Default\)$|^\(Predeterminado\)$") {
                                $targetRegKey = ""
                            }

                            if ($isDeleteProperty) {
                                $keyObj.DeleteValue($targetRegKey, $false)
                                Write-Log -LogLevel INFO -Message "Tweak_Engine: Valor borrado -> [$targetRegKey] en $subPathNet"
                            } else {
                                $type = switch ($t.RegistryType) {
                                    "String"       { [Microsoft.Win32.RegistryValueKind]::String }
                                    "ExpandString" { [Microsoft.Win32.RegistryValueKind]::ExpandString }
                                    "Binary"       { [Microsoft.Win32.RegistryValueKind]::Binary }
                                    "DWord"        { [Microsoft.Win32.RegistryValueKind]::DWord }
                                    "MultiString"  { [Microsoft.Win32.RegistryValueKind]::MultiString }
                                    "QWord"        { [Microsoft.Win32.RegistryValueKind]::QWord }
                                    Default        { [Microsoft.Win32.RegistryValueKind]::DWord }
                                }

                                $safeVal = $valToSet
                                if ([string]::IsNullOrWhiteSpace($safeVal)) {
                                    $safeVal = if ($type -eq [Microsoft.Win32.RegistryValueKind]::DWord -or
                                                   $type -eq [Microsoft.Win32.RegistryValueKind]::QWord) { 0 } else { "" }
                                }

                                try {
                                    if ($type -eq [Microsoft.Win32.RegistryValueKind]::DWord) {
                                        $uintVal = if ($safeVal -match "^(?i)0x") { [Convert]::ToUInt32($safeVal, 16) } else { [uint32]$safeVal }
                                        $safeVal = [BitConverter]::ToInt32([BitConverter]::GetBytes($uintVal), 0)
                                    } elseif ($type -eq [Microsoft.Win32.RegistryValueKind]::QWord) {
                                        $uint64Val = if ($safeVal -match "^(?i)0x") { [Convert]::ToUInt64($safeVal, 16) } else { [uint64]$safeVal }
                                        $safeVal = [BitConverter]::ToInt64([BitConverter]::GetBytes($uint64Val), 0)
                                    } elseif ($type -eq [Microsoft.Win32.RegistryValueKind]::MultiString) {
                                        $safeVal = [string[]]$safeVal
                                    } elseif ($type -eq [Microsoft.Win32.RegistryValueKind]::Binary) {
                                        $safeVal = [byte[]]$safeVal
                                    } elseif ($type -eq [Microsoft.Win32.RegistryValueKind]::String -or
                                              $type -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) {
                                        $safeVal = [string]$safeVal
                                    }
                                } catch {
                                    Write-Log -LogLevel WARN -Message "Tweak_Engine: Fallo casting para $($t.Name). Valor: '$valToSet'. Error: $($_.Exception.Message)"
                                }

                                $keyObj.SetValue($targetRegKey, $safeVal, $type)
                            }
                        } else {
                            throw "CreateSubKey devolvio nulo para la ruta: $subPathNet"
                        }

                        if ($Mode -eq 'Apply') {
                            $it.SubItems[1].Text = "ACTIVO"
                            $it.ForeColor = [System.Drawing.Color]::Cyan
                        } else {
                            $it.SubItems[1].Text = "RESTAURADO"
                            $it.ForeColor = [System.Drawing.Color]::LightGray
                        }
                        $it.Checked = $false
                        $success++
                        [System.Windows.Forms.Application]::DoEvents()

                    } catch {
                        $errors++
                        $it.SubItems[1].Text = "ERROR"
                        $it.ForeColor = [System.Drawing.Color]::Red
                        Write-Log -LogLevel ERROR -Message "Tweak_Engine: Falla critica procesando $($t.Name) ($Mode) - $($_.Exception.Message)"
                    } finally {
                        if ($null -ne $keyObj) { $keyObj.Close(); $keyObj = $null }
                        Restore-KeyOwner -KeyPath $psPath
                    }

                } else {
                    Write-Log -LogLevel ERROR -Message "Tweak_Engine: No se pudo traducir la ruta Offline para el Tweak: $($t.Name)"
                    $errors++
                }
            }

            Write-Log -LogLevel ACTION -Message "Tweak_Engine: Proceso finalizado. Exitos: $success | Errores: $errors"

            if ($Script:SDDL_Backups.Count -gt 0) {
                Write-Log -LogLevel INFO -Message "Tweak_Engine: Restaurando permisos SDDL diferidos..."
                Restore-AllOfflineSDDL
            }

            $lblStatus.Text = "Proceso finalizado."
            [System.Windows.Forms.MessageBox]::Show("Proceso completado.`nExitos: $success`nErrores: $errors", "Informe", 'OK', 'Information')

        } finally {
            $progressBar.Visible = $false
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnApplyGlobal.Enabled = $true
            $btnRestoreGlobal.Enabled = $true
            $btnSelectAllGlobal.Enabled = $true
            $btnSelectInactive.Enabled = $true
        }
    }

    $btnApplyGlobal.Add_Click({ & $ProcessChanges -Mode 'Apply' })
    $btnRestoreGlobal.Add_Click({ & $ProcessChanges -Mode 'Restore' })

    $form.Add_FormClosing({ 
        if (-not $btnApplyGlobal.Enabled) {
            [System.Windows.Forms.MessageBox]::Show("Hay una operacion en curso. Espera a que finalice antes de cerrar.", "Advertencia", 'OK', 'Warning')
            $_.Cancel = $true
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Estas seguro de que deseas salir?`nSe guardaran y desmontaran los Hives del registro.", 
            "Confirmar Salida", 
            [System.Windows.Forms.MessageBoxButtons]::YesNo, 
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq 'No') {
            $_.Cancel = $true
        } else {
            $lblStatus.Text = "Sincronizando y desmontando Hives... Por favor espere."
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

    $form.Dispose()

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}