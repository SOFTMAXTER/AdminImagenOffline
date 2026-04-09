# =================================================================
#  Modulo-DeployVHD
#
#  CONTENIDO   : Show-Deploy-To-VHD-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log   : registro de eventos
#  CARGA       : . "$PSScriptRoot\Modulo-DeployVHD.ps1"
#
#  NOTA: Esta funcion NO requiere imagen montada ($Script:IMAGE_MOUNTED).
#  Opera directamente sobre archivos WIM/ESD independientes y discos del
#  sistema host. Es autocontenida salvo por Write-Log.
#
#  NO modificar las firmas de funcion; el nucleo las invoca por nombre.
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

function Show-Deploy-To-VHD-GUI {

    # ------------------------------------------------------------------
    # 1. Verificacion de requisitos del modulo Storage
    # ------------------------------------------------------------------
    if (-not (Get-Command "Initialize-Disk" -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Este modulo requiere el modulo Storage de PowerShell.", "Error", 'OK', 'Error')
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:isDeploying = $false

    # ------------------------------------------------------------------
    # 2. Construccion del formulario
    # ------------------------------------------------------------------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "Despliegue de Imagen (WIM/ESD a VHDX o Disco Fisico)"
    $form.Size            = New-Object System.Drawing.Size(720, 680)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    # --- Grupo 1: Imagen de Origen ---
    $grpSource           = New-Object System.Windows.Forms.GroupBox
    $grpSource.Text      = " 1. Imagen de Origen "
    $grpSource.Location  = New-Object System.Drawing.Point(20, 15)
    $grpSource.Size      = New-Object System.Drawing.Size(660, 120)
    $grpSource.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($grpSource)

    $txtWim           = New-Object System.Windows.Forms.TextBox
    $txtWim.Location  = "20, 25"
    $txtWim.Size      = "540, 23"
    $txtWim.ReadOnly  = $true
    $txtWim.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtWim.ForeColor = [System.Drawing.Color]::White
    $grpSource.Controls.Add($txtWim)

    $btnBrowseWim           = New-Object System.Windows.Forms.Button
    $btnBrowseWim.Text      = "..."
    $btnBrowseWim.Location  = "570, 24"
    $btnBrowseWim.Size      = "70, 25"
    $btnBrowseWim.BackColor = [System.Drawing.Color]::Silver
    $btnBrowseWim.FlatStyle = "Flat"
    $grpSource.Controls.Add($btnBrowseWim)

    $lblIdx           = New-Object System.Windows.Forms.Label
    $lblIdx.Text      = "Indice:"
    $lblIdx.Location  = "20, 60"
    $lblIdx.AutoSize  = $true
    $lblIdx.ForeColor = [System.Drawing.Color]::Silver
    $grpSource.Controls.Add($lblIdx)

    $cmbIndex               = New-Object System.Windows.Forms.ComboBox
    $cmbIndex.Location      = "20, 80"
    $cmbIndex.Size          = "620, 25"
    $cmbIndex.DropDownStyle = "DropDownList"
    $cmbIndex.BackColor     = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $cmbIndex.ForeColor     = [System.Drawing.Color]::White
    $grpSource.Controls.Add($cmbIndex)

    # --- Grupo 2: Tipo de Destino ---
    $grpTargetMode           = New-Object System.Windows.Forms.GroupBox
    $grpTargetMode.Text      = " 2. Tipo de Destino "
    $grpTargetMode.Location  = "20, 140"
    $grpTargetMode.Size      = "660, 55"
    $grpTargetMode.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($grpTargetMode)

    $radVhd           = New-Object System.Windows.Forms.RadioButton
    $radVhd.Text      = "Disco Virtual (VHD / VHDX)"
    $radVhd.Location  = "20, 22"
    $radVhd.AutoSize  = $true
    $radVhd.Checked   = $true
    $radVhd.ForeColor = [System.Drawing.Color]::White
    $grpTargetMode.Controls.Add($radVhd)

    $radPhysical           = New-Object System.Windows.Forms.RadioButton
    $radPhysical.Text      = "Disco Fisico (USB / Pendrive / HDD Externo)"
    $radPhysical.Location  = "250, 22"
    $radPhysical.AutoSize  = $true
    $radPhysical.ForeColor = [System.Drawing.Color]::White
    $grpTargetMode.Controls.Add($radPhysical)

    # --- Grupo 3: Configuracion de Disco y Particiones ---
    $grpDest           = New-Object System.Windows.Forms.GroupBox
    $grpDest.Text      = " 3. Configuracion de Disco y Particiones "
    $grpDest.Location  = "20, 205"
    $grpDest.Size      = "660, 220"
    $grpDest.ForeColor = [System.Drawing.Color]::Orange
    $form.Controls.Add($grpDest)

    # Controles VHD
    $lblVhdPath           = New-Object System.Windows.Forms.Label
    $lblVhdPath.Text      = "Ruta VHDX:"
    $lblVhdPath.Location  = "20, 25"
    $lblVhdPath.AutoSize  = $true
    $lblVhdPath.ForeColor = [System.Drawing.Color]::Silver
    $grpDest.Controls.Add($lblVhdPath)

    $txtVhd           = New-Object System.Windows.Forms.TextBox
    $txtVhd.Location  = "20, 45"
    $txtVhd.Size      = "540, 23"
    $txtVhd.ReadOnly  = $true
    $txtVhd.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtVhd.ForeColor = [System.Drawing.Color]::White
    $grpDest.Controls.Add($txtVhd)

    $btnBrowseVhd           = New-Object System.Windows.Forms.Button
    $btnBrowseVhd.Text      = "Guardar"
    $btnBrowseVhd.Location  = "570, 44"
    $btnBrowseVhd.Size      = "70, 25"
    $btnBrowseVhd.BackColor = [System.Drawing.Color]::Silver
    $btnBrowseVhd.FlatStyle = "Flat"
    $grpDest.Controls.Add($btnBrowseVhd)

    $lblSize          = New-Object System.Windows.Forms.Label
    $lblSize.Text     = "Size Total (GB):"
    $lblSize.Location = "20, 85"
    $lblSize.AutoSize = $true
    $grpDest.Controls.Add($lblSize)

    $numSize          = New-Object System.Windows.Forms.NumericUpDown
    $numSize.Location = "140, 83"
    $numSize.Size     = "80, 25"
    $numSize.Minimum  = 10
    $numSize.Maximum  = 10000
    $numSize.Value    = 60
    $grpDest.Controls.Add($numSize)

    $chkDynamic          = New-Object System.Windows.Forms.CheckBox
    $chkDynamic.Text     = "Expansion Dinamica"
    $chkDynamic.Location = "250, 85"
    $chkDynamic.AutoSize = $true
    $chkDynamic.Checked  = $true
    $grpDest.Controls.Add($chkDynamic)

    # Controles Disco Fisico (ocultos por defecto)
    $lblPhysicalDisk           = New-Object System.Windows.Forms.Label
    $lblPhysicalDisk.Text      = "Seleccione el Disco Fisico Destino:"
    $lblPhysicalDisk.Location  = "20, 25"
    $lblPhysicalDisk.AutoSize  = $true
    $lblPhysicalDisk.ForeColor = [System.Drawing.Color]::Silver
    $lblPhysicalDisk.Visible   = $false
    $grpDest.Controls.Add($lblPhysicalDisk)

    $cmbDisks               = New-Object System.Windows.Forms.ComboBox
    $cmbDisks.Location      = "20, 45"
    $cmbDisks.Size          = "450, 25"
    $cmbDisks.DropDownStyle = "DropDownList"
    $cmbDisks.BackColor     = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $cmbDisks.ForeColor     = [System.Drawing.Color]::White
    $cmbDisks.Visible       = $false
    $grpDest.Controls.Add($cmbDisks)

    $btnRefreshDisks           = New-Object System.Windows.Forms.Button
    $btnRefreshDisks.Text      = "Actualizar Lista"
    $btnRefreshDisks.Location  = "480, 44"
    $btnRefreshDisks.Size      = "160, 25"
    $btnRefreshDisks.BackColor = [System.Drawing.Color]::DodgerBlue
    $btnRefreshDisks.FlatStyle = "Flat"
    $btnRefreshDisks.Visible   = $false
    $grpDest.Controls.Add($btnRefreshDisks)

    # Controles comunes — tamaños de particiones
    $chkUEFI           = New-Object System.Windows.Forms.CheckBox
    $chkUEFI.Text      = "Esquema GPT (UEFI)"
    $chkUEFI.Location  = "420, 85"
    $chkUEFI.AutoSize  = $true
    $chkUEFI.Checked   = $true
    $chkUEFI.ForeColor = [System.Drawing.Color]::LightGreen
    $grpDest.Controls.Add($chkUEFI)

    $lblPartInfo           = New-Object System.Windows.Forms.Label
    $lblPartInfo.Text      = "--- Size de Particiones de Sistema ---"
    $lblPartInfo.Location  = "20, 125"
    $lblPartInfo.AutoSize  = $true
    $lblPartInfo.ForeColor = [System.Drawing.Color]::Silver
    $grpDest.Controls.Add($lblPartInfo)

    $lblEfiSize          = New-Object System.Windows.Forms.Label
    $lblEfiSize.Text     = "EFI (MB):"
    $lblEfiSize.Location = "20, 155"
    $lblEfiSize.AutoSize = $true
    $grpDest.Controls.Add($lblEfiSize)

    $numEfiSize          = New-Object System.Windows.Forms.NumericUpDown
    $numEfiSize.Location = "140, 153"
    $numEfiSize.Size     = "80, 25"
    $numEfiSize.Minimum  = 50
    $numEfiSize.Maximum  = 2000
    $numEfiSize.Value    = 100
    $grpDest.Controls.Add($numEfiSize)

    $lblMsrSize          = New-Object System.Windows.Forms.Label
    $lblMsrSize.Text     = "MSR (MB):"
    $lblMsrSize.Location = "250, 155"
    $lblMsrSize.AutoSize = $true
    $grpDest.Controls.Add($lblMsrSize)

    $numMsrSize          = New-Object System.Windows.Forms.NumericUpDown
    $numMsrSize.Location = "330, 153"
    $numMsrSize.Size     = "80, 25"
    $numMsrSize.Minimum  = 0
    $numMsrSize.Maximum  = 500
    $numMsrSize.Value    = 16
    $grpDest.Controls.Add($numMsrSize)

    $lblRecSize           = New-Object System.Windows.Forms.Label
    $lblRecSize.Text      = "Recovery (MB):"
    $lblRecSize.Location  = "430, 155"
    $lblRecSize.AutoSize  = $true
    $lblRecSize.ForeColor = [System.Drawing.Color]::White
    $grpDest.Controls.Add($lblRecSize)

    $numRecSize          = New-Object System.Windows.Forms.NumericUpDown
    $numRecSize.Location = "520, 153"
    $numRecSize.Size     = "80, 25"
    $numRecSize.Minimum  = 0
    $numRecSize.Maximum  = 5000
    $numRecSize.Value    = 1024
    $grpDest.Controls.Add($numRecSize)

    # Etiqueta de estado y boton principal
    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "Esperando configuracion..."
    $lblStatus.Location  = "20, 570"
    $lblStatus.AutoSize  = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    $btnDeploy           = New-Object System.Windows.Forms.Button
    $btnDeploy.Text      = "EJECUTAR DESPLIEGUE"
    $btnDeploy.Location  = "380, 550"
    $btnDeploy.Size      = "300, 50"
    $btnDeploy.BackColor = [System.Drawing.Color]::SeaGreen
    $btnDeploy.ForeColor = [System.Drawing.Color]::White
    $btnDeploy.FlatStyle = "Flat"
    $btnDeploy.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnDeploy)

    # ------------------------------------------------------------------
    # 3. Eventos de interfaz
    # ------------------------------------------------------------------

    # Alternar visibilidad de controles VHD / Disco Fisico
    $radVhd.Add_CheckedChanged({
        $isVhd = $radVhd.Checked
        $lblVhdPath.Visible    = $isVhd
        $txtVhd.Visible        = $isVhd
        $btnBrowseVhd.Visible  = $isVhd
        $lblSize.Visible       = $isVhd
        $numSize.Visible       = $isVhd
        $chkDynamic.Visible    = $isVhd
        $lblPhysicalDisk.Visible = -not $isVhd
        $cmbDisks.Visible        = -not $isVhd
        $btnRefreshDisks.Visible = -not $isVhd
    })

    # Ajustar etiqueta EFI y visibilidad MSR segun esquema
    $chkUEFI.Add_CheckedChanged({
        if ($chkUEFI.Checked) {
            $numEfiSize.Value      = 100
            $lblMsrSize.Visible    = $true
            $numMsrSize.Visible    = $true
            $lblEfiSize.Text       = "EFI (MB):"
        } else {
            $numEfiSize.Value      = 500
            $lblMsrSize.Visible    = $false
            $numMsrSize.Visible    = $false
            $lblEfiSize.Text       = "Sys. Rsvd (MB):"
        }
    })

    # Poblar lista de discos fisicos seguros (excluye sistema y boot)
    $PopulateDisks = {
        $cmbDisks.Items.Clear()
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $sysDriveLetter = (Get-Item $env:SystemRoot).Root.Name.Replace("\", "")
            $sysPart = Get-Partition -DriveLetter $sysDriveLetter[0] -ErrorAction SilentlyContinue
            
            $sysDiskNum = -1
            if ($sysPart -and $sysPart.DiskNumber -ne $null) {
                $sysDiskNum = $sysPart.DiskNumber
            }

            # BLOQUEO EXTREMO: Solo permitimos buses extraíbles (USB, SD, 1394)
            # Esto ignora automáticamente cualquier disco SATA, NVMe, RAID o SAS interno.
            $safeDisks = Get-Disk | Where-Object {
                $_.IsSystem  -eq $false -and
                $_.IsBoot    -eq $false -and
                $_.IsOffline -eq $false -and
                $_.Number    -ne $sysDiskNum -and
                $_.BusType   -match '(?i)^(USB|SD|1394)$'
            }

            foreach ($d in $safeDisks) {
                $sizeGB = [math]::Round($d.Size / 1GB, 2)
                $cmbDisks.Items.Add("Disco $($d.Number) - $($d.FriendlyName) ($sizeGB GB) [$($d.BusType)]")
            }
        } catch {
            Write-Log -LogLevel ERROR -Message "Error enumerando discos fisicos: $_"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }

        if ($cmbDisks.Items.Count -eq 0) {
            $cmbDisks.Items.Add("No se detectaron discos externos (USB).")
        }
        $cmbDisks.SelectedIndex = 0
    }

    $btnRefreshDisks.Add_Click($PopulateDisks)

    # Carga inicial: poblar la lista de discos
    $form.Add_Shown({ & $PopulateDisks })

    # Seleccionar imagen WIM/ESD y poblar ComboBox de indices
    $btnBrowseWim.Add_Click({
        $ofd        = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Imagenes (*.wim, *.esd)|*.wim;*.esd"
        if ($ofd.ShowDialog() -eq 'OK') {
            $txtWim.Text = $ofd.FileName
            $cmbIndex.Items.Clear()
            $lblStatus.Text = "Leyendo..."
            $form.Refresh()
            try {
                $info = Get-WindowsImage -ImagePath $ofd.FileName
                foreach ($img in $info) {
                    $cmbIndex.Items.Add("[$($img.ImageIndex)] $($img.ImageName)")
                }
                if ($cmbIndex.Items.Count -gt 0) { $cmbIndex.SelectedIndex = 0 }
                $lblStatus.Text = "WIM Cargado."
            } catch {
                $lblStatus.Text = "Error leyendo WIM."
            }
        }
    })

    # Guardar ruta del VHDX destino
    $btnBrowseVhd.Add_Click({
        $sfd        = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = "VHDX (*.vhdx)|*.vhdx|VHD (*.vhd)|*.vhd"
        if ($sfd.ShowDialog() -eq 'OK') { $txtVhd.Text = $sfd.FileName }
    })

    # ------------------------------------------------------------------
    # 4. Motor de despliegue
    # ------------------------------------------------------------------
    $btnDeploy.Add_Click({

        # Validaciones previas
        if (-not $txtWim.Text) {
            [System.Windows.Forms.MessageBox]::Show("Falta la imagen origen.", "Error", 'OK', 'Error')
            return
        }

        # validacion estricta del ComboBox ANTES de tocar discos
        if ($cmbIndex.Items.Count -eq 0 -or $cmbIndex.SelectedIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Selecciona un indice de imagen valido.", "Error", 'OK', 'Error')
            return
        }

        $isVhdMode  = $radVhd.Checked
        $vhdPath    = $txtVhd.Text
        $wimPath    = $txtWim.Text
        $idx        = $cmbIndex.SelectedIndex + 1
        $isGPT      = $chkUEFI.Checked
        $sizeBootMB = [int]$numEfiSize.Value
        $sizeMsrMB  = [int]$numMsrSize.Value
        $sizeRecMB  = [int]$numRecSize.Value

        $diskNum             = $null
        $driveLetterSystem   = $null
        $driveLetterBoot     = $null
        $driveLetterRecovery = $null

        if ($isVhdMode) {
            if (-not $vhdPath) {
                [System.Windows.Forms.MessageBox]::Show("Ruta VHDX vacia.", "Error", 'OK', 'Error')
                return
            }
            if (Test-Path $vhdPath) {
                if ([System.Windows.Forms.MessageBox]::Show(
                        "El VHD existe. Se borrara todo su contenido.`nContinuar?",
                        "Confirmar", 'YesNo', 'Warning') -eq 'No') { return }
                try {
                    Remove-Item $vhdPath -Force -ErrorAction Stop
                } catch {
                    [System.Windows.Forms.MessageBox]::Show(
                        "No se pudo borrar el archivo. Esta en uso?", "Error", 'OK', 'Error')
                    return
                }
            }
        } else {
            if ($cmbDisks.Items.Count -eq 0 -or $cmbDisks.Text -match "No se detectaron") {
                [System.Windows.Forms.MessageBox]::Show(
                    "Seleccione un disco fisico valido.", "Error", 'OK', 'Error')
                return
            }
            if ($cmbDisks.Text -match "^Disco (\d+)") {
                $diskNum = [int]$Matches[1]
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "No se pudo determinar el numero de disco de forma segura. Seleccione un disco valido.",
                    "Error Critico", 'OK', 'Error')
                return
            }
            $msg = "¡ADVERTENCIA EXTREMA!`n`nEl Disco Fisico $diskNum sera FORMATEADO Y BORRADO COMPLETAMENTE.`nTodos los datos y particiones actuales se perderan de forma irreversible.`n`n¿Esta ABSOLUTAMENTE SEGURO de continuar?"
            if ([System.Windows.Forms.MessageBox]::Show($msg, "Destruccion de Datos", 'YesNo', 'Warning') -eq 'No') { return }
        }

        $script:isDeploying   = $true
        $btnDeploy.Enabled    = $false
        $form.Cursor          = [System.Windows.Forms.Cursors]::WaitCursor

        try {
            # Bug 1 corregido: acumulador en memoria para evitar colisiones de letras por latencia VDS
            $reservedLetters = @()

            # ── Fase 1: Preparacion del disco ─────────────────────────
            if ($isVhdMode) {
                $lblStatus.Text = "Creando disco virtual..."
                $form.Refresh()

                $totalSize = [long]$numSize.Value * 1GB
                if ($chkDynamic.Checked) {
                    New-VHD -Path $vhdPath -SizeBytes $totalSize -Dynamic -ErrorAction Stop | Out-Null
                } else {
                    New-VHD -Path $vhdPath -SizeBytes $totalSize -Fixed   -ErrorAction Stop | Out-Null
                }

                Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop | Out-Null
                Start-Sleep -Milliseconds 500
                $diskNum = (Get-VHD -Path $vhdPath).DiskNumber

                if ($null -eq $diskNum -or $diskNum -lt 0) {
                    throw "No se pudo determinar el numero de disco del VHD montado de forma segura. Abortando para evitar daño al sistema host."
                }
            } else {
                $lblStatus.Text = "Limpiando disco fisico $diskNum..."
                $form.Refresh()
                Clear-Disk -Number $diskNum -RemoveData -Confirm:$false -ErrorAction Stop
            }

            # ── Fase 2: Inicializacion y particionado ─────────────────
            $partStyle = if ($isGPT) { "GPT" } else { "MBR" }
            Initialize-Disk -Number $diskNum -PartitionStyle $partStyle -ErrorAction Stop

            Write-Log -LogLevel INFO -Message "DEPLOY: Formateando y asignando particiones en Disco $diskNum..."

            if ($isGPT) {
                $lblStatus.Text = "Particionando GPT (UEFI)..."
                $form.Refresh()

                # 1. EFI
                $pEFI = New-Partition -DiskNumber $diskNum -Size ($sizeBootMB * 1MB) `
                    -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -ErrorAction Stop
                Format-Volume -Partition $pEFI -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false | Out-Null
                $freeLetBoot      = Get-UnusedDriveLetter -AlreadyReserved $reservedLetters
                $reservedLetters += $freeLetBoot.ToString()
                Set-Partition -InputObject $pEFI -NewDriveLetter $freeLetBoot -ErrorAction Stop
                $driveLetterBoot  = "$($freeLetBoot):"

                # 2. MSR
                if ($sizeMsrMB -gt 0) {
                    New-Partition -DiskNumber $diskNum -Size ($sizeMsrMB * 1MB) `
                        -GptType "{e3c9e316-0b5c-4db8-817d-f92df00215ae}" -ErrorAction Stop | Out-Null
                }

                # 3. Windows
                $diskObj   = Get-Disk -Number $diskNum
                $freeSpace = $diskObj.LargestFreeExtent

                if ($sizeRecMB -gt 0) {
                    $winSize = $freeSpace - ($sizeRecMB * 1MB) - 10MB
                    $pWin = New-Partition -DiskNumber $diskNum -Size $winSize -ErrorAction Stop
                } else {
                    $pWin = New-Partition -DiskNumber $diskNum -UseMaximumSize -ErrorAction Stop
                }
                Format-Volume -Partition $pWin -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null
                $freeLetSys       = Get-UnusedDriveLetter -AlreadyReserved $reservedLetters
                $reservedLetters += $freeLetSys.ToString()
                Set-Partition -InputObject $pWin -NewDriveLetter $freeLetSys -ErrorAction Stop
                $driveLetterSystem = "$($freeLetSys):"

                # 4. Recovery
                if ($sizeRecMB -gt 0) {
                    $pRec = New-Partition -DiskNumber $diskNum -UseMaximumSize `
                        -GptType "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -ErrorAction Stop
                    Format-Volume -Partition $pRec -FileSystem NTFS -NewFileSystemLabel "Recovery" -Confirm:$false | Out-Null
                    $freeLetRec       = Get-UnusedDriveLetter -AlreadyReserved $reservedLetters
                    $reservedLetters += $freeLetRec.ToString()
                    Set-Partition -InputObject $pRec -NewDriveLetter $freeLetRec -ErrorAction Stop
                    $driveLetterRecovery = "$($freeLetRec):"
                }

            } else {
                $lblStatus.Text = "Particionando MBR (Legacy)..."
                $form.Refresh()

                # 1. System Reserved
                $pBoot = New-Partition -DiskNumber $diskNum -Size ($sizeBootMB * 1MB) -IsActive -ErrorAction Stop
                Format-Volume -Partition $pBoot -FileSystem NTFS -NewFileSystemLabel "System Reserved" -Confirm:$false | Out-Null
                $freeLetBoot      = Get-UnusedDriveLetter -AlreadyReserved $reservedLetters
                $reservedLetters += $freeLetBoot.ToString()
                Set-Partition -InputObject $pBoot -NewDriveLetter $freeLetBoot -ErrorAction Stop
                $driveLetterBoot  = "$($freeLetBoot):"

                # 2. Windows
                $diskObj   = Get-Disk -Number $diskNum
                $freeSpace = $diskObj.LargestFreeExtent

                if ($sizeRecMB -gt 0) {
                    $winSize = $freeSpace - ($sizeRecMB * 1MB) - 10MB
                    $pWin = New-Partition -DiskNumber $diskNum -Size $winSize -ErrorAction Stop
                } else {
                    $pWin = New-Partition -DiskNumber $diskNum -UseMaximumSize -ErrorAction Stop
                }
                Format-Volume -Partition $pWin -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null
                $freeLetSys       = Get-UnusedDriveLetter -AlreadyReserved $reservedLetters
                $reservedLetters += $freeLetSys.ToString()
                Set-Partition -InputObject $pWin -NewDriveLetter $freeLetSys -ErrorAction Stop
                $driveLetterSystem = "$($freeLetSys):"

                # 3. Recovery
                if ($sizeRecMB -gt 0) {
                    $pRec = New-Partition -DiskNumber $diskNum -UseMaximumSize -MbrType 0x27 -ErrorAction Stop
                    Format-Volume -Partition $pRec -FileSystem NTFS -NewFileSystemLabel "Recovery" -Confirm:$false | Out-Null
                    $freeLetRec       = Get-UnusedDriveLetter -AlreadyReserved $reservedLetters
                    $reservedLetters += $freeLetRec.ToString()
                    Set-Partition -InputObject $pRec -NewDriveLetter $freeLetRec -ErrorAction Stop
                    $driveLetterRecovery = "$($freeLetRec):"
                }
            }

            # ── Fase 3: Aplicacion de la imagen ───────────────────────
            $lblStatus.Text = "Desplegando imagen (Esto tardara varios minutos)..."
            $form.Refresh()

            Write-Log -LogLevel ACTION -Message "DEPLOY: Ejecutando DISM nativo hacia $driveLetterSystem\ ..."
            $dismArgs = "/Apply-Image /ImageFile:`"$wimPath`" /Index:$idx /ApplyDir:$driveLetterSystem\"
            $proc     = Start-Process "dism.exe" -ArgumentList $dismArgs -Wait -NoNewWindow -PassThru

            if ($proc.ExitCode -ne 0) {
                throw "Fallo DISM al aplicar la imagen. Codigo: $($proc.ExitCode)"
            }

            # ── Fase 4: Escritura del sector de arranque ───────────────
            $lblStatus.Text = "Escribiendo sectores de arranque..."
            $form.Refresh()

            $fw       = if ($isGPT) { "UEFI" } else { "BIOS" }
            Write-Log -LogLevel ACTION -Message "DEPLOY: Escribiendo BCD ($fw)..."

            $procBcd = Start-Process "bcdboot.exe" `
                -ArgumentList "$driveLetterSystem\Windows /s $driveLetterBoot /f $fw" `
                -Wait -NoNewWindow -PassThru
            if ($procBcd.ExitCode -ne 0) {
                throw "Fallo la creacion de archivos de arranque (BCDBOOT)."
            }

            # ── Fase 5: Ocultar particiones de sistema ─────────────────
            if ($sizeRecMB -gt 0 -and $driveLetterRecovery) {
                $lblStatus.Text = "Ocultando particion WinRE..."
                $form.Refresh()
                Remove-PartitionAccessPath -InputObject $pRec -AccessPath $driveLetterRecovery -ErrorAction SilentlyContinue
                $driveLetterRecovery = $null
            }

            $lblStatus.Text = "Ocultando particiones del sistema..."
            $form.Refresh()
            $bootPart = Get-Partition -DriveLetter $freeLetBoot[0] -ErrorAction SilentlyContinue
            if ($bootPart) {
                Remove-PartitionAccessPath -InputObject $bootPart -AccessPath $driveLetterBoot -ErrorAction SilentlyContinue
                $driveLetterBoot = $null
            }

            # ── Fase 6: Desmontar VHD si aplica ───────────────────────
            if ($isVhdMode) {
                $lblStatus.Text = "Desmontando disco virtual..."
                $form.Refresh()
                Dismount-VHD -Path $vhdPath -ErrorAction Stop
            }

            $lblStatus.Text      = "Completado."
            $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
            Write-Log -LogLevel INFO -Message "DEPLOY: Despliegue finalizado con exito."
            [System.Windows.Forms.MessageBox]::Show(
                "El disco booteable ha sido creado exitosamente.",
                "Despliegue Finalizado", 'OK', 'Information')

        } catch {
            $lblStatus.Text      = "Error Critico."
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
            Write-Log -LogLevel ERROR -Message "DEPLOY: FALLO - $($_.Exception.Message)"

            # Limpiar letras de unidad asignadas antes del fallo
            foreach ($letter in @($driveLetterSystem, $driveLetterBoot, $driveLetterRecovery)) {
                if ($letter -and (Test-Path $letter)) {
                    $part = Get-Partition -DriveLetter $letter[0] -ErrorAction SilentlyContinue
                    if ($part) {
                        Remove-PartitionAccessPath `
                            -DiskNumber $diskNum `
                            -PartitionNumber $part.PartitionNumber `
                            -AccessPath $letter `
                            -ErrorAction SilentlyContinue
                    }
                }
            }

            # Desmontar y eliminar el VHD parcialmente construido
            if ($isVhdMode -and $vhdPath) {
                try {
                    Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 1
                    if (Test-Path $vhdPath) { Remove-Item $vhdPath -Force -ErrorAction SilentlyContinue }
                } catch {}
            }

            [System.Windows.Forms.MessageBox]::Show(
                "Ocurrio un error critico durante el despliegue:`n`n" + $_.Exception.Message,
                "Error de Despliegue", 'OK', 'Error')

        } finally {
            $script:isDeploying = $false
            $btnDeploy.Enabled  = $true
            $form.Cursor        = [System.Windows.Forms.Cursors]::Default
        }
    })

    # Cierre seguro — bloquear si el despliegue esta en curso
    $form.Add_FormClosing({
        if ($script:isDeploying) {
            [System.Windows.Forms.MessageBox]::Show(
                "El despliegue esta en curso. Espera a que termine antes de cerrar para evitar corrupcion de datos.",
                "Operacion en curso", 'OK', 'Warning')
            $_.Cancel = $true
        }
    })

    # ------------------------------------------------------------------
    # 5. Tooltips descriptivos para todos los controles
    # ------------------------------------------------------------------
    $toolTip              = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 8000
    $toolTip.InitialDelay = 500
    $toolTip.ReshowDelay  = 500
    $toolTip.ShowAlways   = $true
    $toolTip.IsBalloon    = $false

    $toolTip.SetToolTip($btnBrowseWim,    "Haz clic para seleccionar el archivo de imagen (.wim o .esd) que contiene el instalador de Windows.")
    $toolTip.SetToolTip($cmbIndex,        "Selecciona la edicion de Windows a instalar.")
    $toolTip.SetToolTip($btnBrowseVhd,    "Define donde se guardara el nuevo archivo de disco virtual (.vhdx o .vhd).")
    $toolTip.SetToolTip($btnRefreshDisks, "Actualiza la lista de discos fisicos extraibles detectados.")
    $toolTip.SetToolTip($numSize,         "Size maximo que podra tener el disco virtual (en Gigabytes).")
    $toolTip.SetToolTip($chkDynamic,      "Marcado: El archivo crece segun guardes datos.`nDesmarcado: Ocupa todo el Size inmediatamente.")
    $toolTip.SetToolTip($chkUEFI,         "Marcado (GPT): Para PCs modernos con UEFI.`nDesmarcado (MBR): Para PCs antiguos con BIOS Legacy.")
    $toolTip.SetToolTip($numEfiSize,      "Size de la particion de arranque (EFI o System Reserved).")
    $toolTip.SetToolTip($numMsrSize,      "Size de la particion MSR. Solo aplica en GPT/UEFI.")
    $toolTip.SetToolTip($numRecSize,      "Size de la particion de Recuperacion (WinRE). Se recomienda 1024 MB.")
    $toolTip.SetToolTip($btnDeploy,       "ADVERTENCIA: Iniciara el proceso de creacion/formateo y aplicacion de imagen.")

    # ------------------------------------------------------------------
    # 6. Mostrar y limpiar
    # ------------------------------------------------------------------
    $form.ShowDialog() | Out-Null
    $form.Dispose()
}