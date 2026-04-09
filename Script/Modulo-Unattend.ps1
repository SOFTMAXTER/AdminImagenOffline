# =================================================================
#  Modulo-Unattend
#
#  CONTENIDO   : Show-Unattend-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#  CARGA       : . "$PSScriptRoot\Modulo-Unattend.ps1"
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

function Show-Unattend-GUI {
    param()

    # ------------------------------------------------------------------
    # 1. Validacion de imagen montada
    # ------------------------------------------------------------------
    if ($Script:IMAGE_MOUNTED -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Primero debes montar una imagen.", "Error Montaje", 'OK', 'Error')
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # ------------------------------------------------------------------
    # 2. Deteccion de arquitectura del WIM montado
    # ------------------------------------------------------------------
    $detectedArch = "amd64"
    try {
        $imgInfo = Get-WindowsImage -Path $Script:MOUNT_DIR -ErrorAction Stop
        switch ($imgInfo.Architecture) {
            0  { $detectedArch = "x86"   }
            9  { $detectedArch = "amd64" }
            12 { $detectedArch = "arm64" }
        }
    } catch {
        Write-Log -LogLevel WARN -Message "Unattend-GUI: No se pudo detectar arquitectura. Usando amd64 por defecto."
    }

    # ------------------------------------------------------------------
    # 3. Construccion del formulario
    # ------------------------------------------------------------------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "Gestor OOBE Inteligente ($detectedArch) - Integrado"
    $form.Size            = New-Object System.Drawing.Size(980, 620)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    $tabControl          = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = "10, 10"
    $tabControl.Size     = "940, 560"
    $form.Controls.Add($tabControl)

    # ==================================================================
    # PESTANA 1: GENERADOR AVANZADO
    # ==================================================================
    $tabBasic           = New-Object System.Windows.Forms.TabPage
    $tabBasic.Text      = " Generador Avanzado "
    $tabBasic.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $tabControl.TabPages.Add($tabBasic)

    # ── Grupo: Usuario Admin Local y Nombre de Equipo ─────────────────
    $grpUser           = New-Object System.Windows.Forms.GroupBox
    $grpUser.Text      = " Usuario Admin Local y Nombre de Equipo "
    $grpUser.Location  = "20, 15"
    $grpUser.Size      = "440, 145"
    $grpUser.ForeColor = [System.Drawing.Color]::White
    $tabBasic.Controls.Add($grpUser)

    $chkInteractiveUser           = New-Object System.Windows.Forms.CheckBox
    $chkInteractiveUser.Text      = "Forzar creacion manual de usuario (Mostrar pantalla OOBE)"
    $chkInteractiveUser.Location  = "20, 25"
    $chkInteractiveUser.AutoSize  = $true
    $chkInteractiveUser.Checked   = $true
    $chkInteractiveUser.ForeColor = [System.Drawing.Color]::Yellow
    $grpUser.Controls.Add($chkInteractiveUser)

    $lblUser          = New-Object System.Windows.Forms.Label
    $lblUser.Text     = "Usuario:"
    $lblUser.Location = "20, 65"
    $lblUser.AutoSize = $true
    $grpUser.Controls.Add($lblUser)

    $txtUser          = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = "75, 63"
    $txtUser.Text     = "Admin"
    $txtUser.Enabled  = $false
    $grpUser.Controls.Add($txtUser)

    $lblPass          = New-Object System.Windows.Forms.Label
    $lblPass.Text     = "Clave:"
    $lblPass.Location = "220, 65"
    $lblPass.AutoSize = $true
    $grpUser.Controls.Add($lblPass)

    $txtPass              = New-Object System.Windows.Forms.TextBox
    $txtPass.Location     = "265, 63"
    $txtPass.Text         = ""
    $txtPass.PasswordChar = "*"
    $txtPass.Enabled      = $false
    $grpUser.Controls.Add($txtPass)

    $lblPCName           = New-Object System.Windows.Forms.Label
    $lblPCName.Text      = "Nombre PC:"
    $lblPCName.Location  = "20, 105"
    $lblPCName.AutoSize  = $true
    $lblPCName.ForeColor = [System.Drawing.Color]::LightGreen
    $grpUser.Controls.Add($lblPCName)

    $txtPCName           = New-Object System.Windows.Forms.TextBox
    $txtPCName.Location  = "95, 102"
    $txtPCName.Size      = "160, 23"
    $txtPCName.Text      = ""
    $txtPCName.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtPCName.ForeColor = [System.Drawing.Color]::White
    $grpUser.Controls.Add($txtPCName)

    $lblPCNameHint           = New-Object System.Windows.Forms.Label
    $lblPCNameHint.Text      = "(Vacio = auto)"
    $lblPCNameHint.Location  = "265, 105"
    $lblPCNameHint.AutoSize  = $true
    $lblPCNameHint.ForeColor = [System.Drawing.Color]::DarkGray
    $grpUser.Controls.Add($lblPCNameHint)

    $chkInteractiveUser.Add_CheckedChanged({
        $txtUser.Enabled = -not $chkInteractiveUser.Checked
        $txtPass.Enabled = -not $chkInteractiveUser.Checked
    })

    # ── Grupo: Preferencias de idioma y teclado ───────────────────────
    $grpLang           = New-Object System.Windows.Forms.GroupBox
    $grpLang.Text      = " Preferencias de idioma y teclado "
    $grpLang.Location  = "20, 170"
    $grpLang.Size      = "440, 275"
    $grpLang.ForeColor = [System.Drawing.Color]::PaleGoldenrod
    $tabBasic.Controls.Add($grpLang)

    $chkInteractiveLang           = New-Object System.Windows.Forms.CheckBox
    $chkInteractiveLang.Text      = "Seleccionar idioma interactivamente en la instalacion"
    $chkInteractiveLang.Location  = "20, 25"
    $chkInteractiveLang.AutoSize  = $true
    $chkInteractiveLang.Checked   = $true
    $chkInteractiveLang.ForeColor = [System.Drawing.Color]::Yellow
    $grpLang.Controls.Add($chkInteractiveLang)

    $lblLangH1          = New-Object System.Windows.Forms.Label
    $lblLangH1.Text     = "Instale Windows usando este idioma:"
    $lblLangH1.Location = "20, 60"
    $lblLangH1.AutoSize = $true
    $lblLangH1.Font     = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $grpLang.Controls.Add($lblLangH1)

    $lblSetupLang          = New-Object System.Windows.Forms.Label
    $lblSetupLang.Text     = "Idioma de visualizacion de Windows:"
    $lblSetupLang.Location = "20, 85"
    $lblSetupLang.AutoSize = $true
    $grpLang.Controls.Add($lblSetupLang)

    $cmbSetupLang               = New-Object System.Windows.Forms.ComboBox
    $cmbSetupLang.Location      = "20, 105"
    $cmbSetupLang.Size          = "400, 23"
    $cmbSetupLang.DropDownStyle = "DropDownList"
    $cmbSetupLang.Items.AddRange(@(
        "en-US (English - United States)",
        "es-ES (Spanish - Spain)",
        "es-MX (Spanish - Mexico)"
    ))
    $cmbSetupLang.SelectedIndex = 0
    $cmbSetupLang.Enabled       = $false
    $grpLang.Controls.Add($cmbSetupLang)

    $lblLangH2          = New-Object System.Windows.Forms.Label
    $lblLangH2.Text     = "Primer idioma y distribucion del teclado:"
    $lblLangH2.Location = "20, 140"
    $lblLangH2.AutoSize = $true
    $lblLangH2.Font     = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $grpLang.Controls.Add($lblLangH2)

    $lblSysLang          = New-Object System.Windows.Forms.Label
    $lblSysLang.Text     = "Idioma del Sistema:"
    $lblSysLang.Location = "20, 165"
    $lblSysLang.AutoSize = $true
    $grpLang.Controls.Add($lblSysLang)

    $cmbSysLang               = New-Object System.Windows.Forms.ComboBox
    $cmbSysLang.Location      = "20, 185"
    $cmbSysLang.Size          = "400, 23"
    $cmbSysLang.DropDownStyle = "DropDownList"
    $cmbSysLang.Items.AddRange(@(
        "en-US (English - United States)",
        "es-ES (Spanish - Spain)",
        "es-MX (Spanish - Mexico)"
    ))
    $cmbSysLang.SelectedIndex = 0
    $cmbSysLang.Enabled       = $false
    $grpLang.Controls.Add($cmbSysLang)

    $lblKeyboard          = New-Object System.Windows.Forms.Label
    $lblKeyboard.Text     = "Distribucion del teclado (Entrada):"
    $lblKeyboard.Location = "20, 220"
    $lblKeyboard.AutoSize = $true
    $grpLang.Controls.Add($lblKeyboard)

    $cmbKeyboard               = New-Object System.Windows.Forms.ComboBox
    $cmbKeyboard.Location      = "20, 240"
    $cmbKeyboard.Size          = "400, 23"
    $cmbKeyboard.DropDownStyle = "DropDownList"
    $cmbKeyboard.Items.AddRange(@(
        "0409:00000409 (US)",
        "0409:00020409 (United States-International)",
        "040A:0000040A (Spanish)",
        "080A:0000080A (Latin America)"
    ))
    $cmbKeyboard.SelectedIndex = 1
    $cmbKeyboard.Enabled       = $false
    $grpLang.Controls.Add($cmbKeyboard)

    $chkInteractiveLang.Add_CheckedChanged({
        $enabled = -not $chkInteractiveLang.Checked
        $cmbSetupLang.Enabled = $enabled
        $cmbSysLang.Enabled   = $enabled
        $cmbKeyboard.Enabled  = $enabled
    })

    # ── Grupo: Hacks y Bypass ─────────────────────────────────────────
    $grpHacks           = New-Object System.Windows.Forms.GroupBox
    $grpHacks.Text      = " Hacks y Bypass (Win10/Win11) "
    $grpHacks.Location  = "480, 15"
    $grpHacks.Size      = "440, 145"
    $grpHacks.ForeColor = [System.Drawing.Color]::Cyan
    $tabBasic.Controls.Add($grpHacks)

    $chkBypass          = New-Object System.Windows.Forms.CheckBox
    $chkBypass.Text     = "Bypass Requisitos (TPM, SecureBoot, RAM) - Solo Win11"
    $chkBypass.Location = "20, 25"
    $chkBypass.AutoSize = $true
    $chkBypass.Checked  = $true
    $grpHacks.Controls.Add($chkBypass)

    $chkNet          = New-Object System.Windows.Forms.CheckBox
    $chkNet.Text     = "Saltar Cuenta Microsoft (Forzar Local) + Saltar EULA"
    $chkNet.Location = "20, 55"
    $chkNet.AutoSize = $true
    $chkNet.Checked  = $true
    $grpHacks.Controls.Add($chkNet)

    $chkNRO           = New-Object System.Windows.Forms.CheckBox
    $chkNRO.Text      = "Permitir instalacion sin Internet (BypassNRO)"
    $chkNRO.Location  = "20, 85"
    $chkNRO.AutoSize  = $true
    $chkNRO.Checked   = $true
    $chkNRO.ForeColor = [System.Drawing.Color]::LightGreen
    $grpHacks.Controls.Add($chkNRO)

    $chkHideWifi           = New-Object System.Windows.Forms.CheckBox
    $chkHideWifi.Text      = "Omitir configuracion de red Wi-Fi"
    $chkHideWifi.Location  = "20, 115"
    $chkHideWifi.AutoSize  = $true
    $chkHideWifi.Checked   = $true
    $chkHideWifi.ForeColor = [System.Drawing.Color]::LightGreen
    $grpHacks.Controls.Add($chkHideWifi)

    # ── Grupo: Optimizacion, Visual y Privacidad ──────────────────────
    $grpTweaks           = New-Object System.Windows.Forms.GroupBox
    $grpTweaks.Text      = " Optimizacion, Visual y Privacidad "
    $grpTweaks.Location  = "480, 170"
    $grpTweaks.Size      = "440, 300"
    $grpTweaks.ForeColor = [System.Drawing.Color]::Orange
    $tabBasic.Controls.Add($grpTweaks)

    $chkVisuals          = New-Object System.Windows.Forms.CheckBox
    $chkVisuals.Text     = "Estilo Win10: Barra Izquierda + Menu Clasico"
    $chkVisuals.Location = "20, 30"
    $chkVisuals.AutoSize = $true
    $chkVisuals.Checked  = $true
    $grpTweaks.Controls.Add($chkVisuals)

    $chkExt          = New-Object System.Windows.Forms.CheckBox
    $chkExt.Text     = "Explorador: Mostrar Extensiones y Rutas Largas"
    $chkExt.Location = "20, 60"
    $chkExt.AutoSize = $true
    $chkExt.Checked  = $true
    $grpTweaks.Controls.Add($chkExt)

    $chkBloat          = New-Object System.Windows.Forms.CheckBox
    $chkBloat.Text     = "Debloat: Desactivar Copilot, Widgets y Sugerencias"
    $chkBloat.Location = "20, 90"
    $chkBloat.AutoSize = $true
    $chkBloat.Checked  = $true
    $grpTweaks.Controls.Add($chkBloat)

    $chkHidePS          = New-Object System.Windows.Forms.CheckBox
    $chkHidePS.Text     = "Ocultar CMD/PowerShell durante la instalacion"
    $chkHidePS.Location = "20, 120"
    $chkHidePS.AutoSize = $true
    $chkHidePS.Checked  = $true
    $grpTweaks.Controls.Add($chkHidePS)

    $chkBitlocker           = New-Object System.Windows.Forms.CheckBox
    $chkBitlocker.Text      = "Desactivar BitLocker en todas las unidades"
    $chkBitlocker.Location  = "20, 150"
    $chkBitlocker.AutoSize  = $true
    $chkBitlocker.Checked   = $true
    $chkBitlocker.ForeColor = [System.Drawing.Color]::LightCoral
    $grpTweaks.Controls.Add($chkBitlocker)

    $chkTelemetry           = New-Object System.Windows.Forms.CheckBox
    $chkTelemetry.Text      = "Privacidad: Desactivar Telemetria (DiagTrack)"
    $chkTelemetry.Location  = "20, 180"
    $chkTelemetry.AutoSize  = $true
    $chkTelemetry.Checked   = $true
    $chkTelemetry.ForeColor = [System.Drawing.Color]::LightCoral
    $grpTweaks.Controls.Add($chkTelemetry)

    $chkCortana           = New-Object System.Windows.Forms.CheckBox
    $chkCortana.Text      = "Desactivar Cortana y Personalizacion de Entrada"
    $chkCortana.Location  = "20, 210"
    $chkCortana.AutoSize  = $true
    $chkCortana.Checked   = $true
    $chkCortana.ForeColor = [System.Drawing.Color]::LightCoral
    $grpTweaks.Controls.Add($chkCortana)

    $chkPowerPlan           = New-Object System.Windows.Forms.CheckBox
    $chkPowerPlan.Text      = "Plan de Energia: Alto Rendimiento"
    $chkPowerPlan.Location  = "20, 240"
    $chkPowerPlan.AutoSize  = $true
    $chkPowerPlan.Checked   = $true
    $chkPowerPlan.ForeColor = [System.Drawing.Color]::LightGreen
    $grpTweaks.Controls.Add($chkPowerPlan)

    $chkFastBoot          = New-Object System.Windows.Forms.CheckBox
    $chkFastBoot.Text     = "Deshabilitar Inicio Rapido (FastBoot)"
    $chkFastBoot.Location = "20, 270"
    $chkFastBoot.AutoSize = $true
    $chkFastBoot.Checked  = $false
    $grpTweaks.Controls.Add($chkFastBoot)

    # Boton Generar
    $btnGen           = New-Object System.Windows.Forms.Button
    $btnGen.Text      = "GENERAR E INYECTAR XML"
    $btnGen.Location  = "320, 480"
    $btnGen.Size      = "300, 20"
    $btnGen.BackColor = [System.Drawing.Color]::SeaGreen
    $btnGen.ForeColor = [System.Drawing.Color]::White
    $btnGen.FlatStyle = "Flat"
    $btnGen.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $tabBasic.Controls.Add($btnGen)

    # ==================================================================
    # PESTANA 2: IMPORTAR
    # ==================================================================
    $tabImport           = New-Object System.Windows.Forms.TabPage
    $tabImport.Text      = " Importar Externo "
    $tabImport.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $tabControl.TabPages.Add($tabImport)

    $grpImport           = New-Object System.Windows.Forms.GroupBox
    $grpImport.Text      = " Inyeccion Directa de Autounattend.xml "
    $grpImport.Size      = "700, 300"
    $grpImport.Location  = "115, 80"
    $grpImport.ForeColor = [System.Drawing.Color]::Cyan
    $tabImport.Controls.Add($grpImport)

    $lblImp           = New-Object System.Windows.Forms.Label
    $lblImp.Text      = "Selecciona un archivo XML existente en tu equipo:"
    $lblImp.Location  = "40, 50"
    $lblImp.AutoSize  = $true
    $lblImp.ForeColor = [System.Drawing.Color]::White
    $grpImport.Controls.Add($lblImp)

    $txtImpPath          = New-Object System.Windows.Forms.TextBox
    $txtImpPath.Location = "40, 80"
    $txtImpPath.Size     = "560, 23"
    $grpImport.Controls.Add($txtImpPath)

    $btnBrowse           = New-Object System.Windows.Forms.Button
    $btnBrowse.Text      = "..."
    $btnBrowse.Location  = "610, 78"
    $btnBrowse.Size      = "45, 25"
    $btnBrowse.BackColor = [System.Drawing.Color]::Gray
    $btnBrowse.ForeColor = [System.Drawing.Color]::White
    $btnBrowse.FlatStyle = "Flat"
    $grpImport.Controls.Add($btnBrowse)

    $lnkWeb           = New-Object System.Windows.Forms.LinkLabel
    $lnkWeb.Text      = "Generador Online Recomendado (schneegans.de)"
    $lnkWeb.Location  = "40, 115"
    $lnkWeb.AutoSize  = $true
    $lnkWeb.LinkColor = [System.Drawing.Color]::Yellow
    $grpImport.Controls.Add($lnkWeb)

    $lblValid           = New-Object System.Windows.Forms.Label
    $lblValid.Text      = "Estado: Esperando archivo..."
    $lblValid.Location  = "40, 160"
    $lblValid.AutoSize  = $true
    $lblValid.ForeColor = [System.Drawing.Color]::Silver
    $grpImport.Controls.Add($lblValid)

    $btnInjectImp           = New-Object System.Windows.Forms.Button
    $btnInjectImp.Text      = "VALIDAR E INYECTAR XML"
    $btnInjectImp.Location  = "200, 210"
    $btnInjectImp.Size      = "300, 45"
    $btnInjectImp.BackColor = [System.Drawing.Color]::Orange
    $btnInjectImp.ForeColor = [System.Drawing.Color]::Black
    $btnInjectImp.FlatStyle = "Flat"
    $btnInjectImp.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnInjectImp.Enabled   = $false
    $grpImport.Controls.Add($btnInjectImp)

    # ==================================================================
    # LOGICA COMPARTIDA: Inyectar XML en Windows\Panther\unattend.xml
    # ==================================================================
    $InjectXmlLogic = {
        param($Content, $Desc)

        $pantherDir = Join-Path $Script:MOUNT_DIR "Windows\Panther"
        if (-not (Test-Path $pantherDir)) {
            New-Item -Path $pantherDir -ItemType Directory -Force | Out-Null
        }
        $destFile = Join-Path $pantherDir "unattend.xml"

        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($destFile, $Content, $utf8NoBom)

            $msg  = "El archivo se inyecto en el WIM (Windows\Panther\unattend.xml) para la fase OOBE.`n`n"
            $msg += "Para que funcionen la Seleccion de Idioma inicial y los Bypasses de TPM, "
            $msg += "DEBES colocar una copia en la RAIZ de tu USB/ISO con el nombre 'autounattend.xml'.`n`n"
            $msg += "Deseas guardar una copia en tu PC ahora mismo?"

            $res = [System.Windows.Forms.MessageBox]::Show($msg, "Inyeccion Exitosa", 'YesNo', 'Information')

            if ($res -eq 'Yes') {
                $sfd          = New-Object System.Windows.Forms.SaveFileDialog
                $sfd.Filter   = "Archivo Autounattend (*.xml)|*.xml"
                $sfd.FileName = "autounattend.xml"
                $sfd.Title    = "Guardar copia para la raiz del USB/ISO"

                if ($sfd.ShowDialog() -eq 'OK') {
                    [System.IO.File]::WriteAllText($sfd.FileName, $Content, $utf8NoBom)
                    [System.Windows.Forms.MessageBox]::Show(
                        "Copia guardada en:`n$($sfd.FileName)",
                        "Exito", 'OK', 'Information')
                }
            }
            $form.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error: $_", "Error", 'OK', 'Error')
        }
    }

    # ==================================================================
    # LOGICA DE GENERACION — boton "GENERAR E INYECTAR XML"
    # ==================================================================
    $btnGen.Add_Click({

        # --- FIX DE SEGURIDAD: Escapar caracteres especiales para XML ---
        $safeUser   = [System.Security.SecurityElement]::Escape($txtUser.Text.Trim())
        $safePass   = [System.Security.SecurityElement]::Escape($txtPass.Text)
        $safePCName = [System.Security.SecurityElement]::Escape($txtPCName.Text.Trim())

        # Nombre de equip
        if ([string]::IsNullOrWhiteSpace($safePCName)) { $safePCName = "*" }
        $computerNameBlock = "<ComputerName>$safePCName</ComputerName>"
		
		# ── Fase windowsPE: Bypass de requisitos e idioma ─────────────
        $wpeRunSync = New-Object System.Collections.Generic.List[string]
        $wpeOrder   = 1

        if ($chkBypass.Checked) {
            $wpeRunSync.Add("<RunSynchronousCommand wcm:action=""add""><Order>$wpeOrder</Order><Path>reg.exe add ""HKLM\SYSTEM\Setup\LabConfig"" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>")
            $wpeOrder++
            $wpeRunSync.Add("<RunSynchronousCommand wcm:action=""add""><Order>$wpeOrder</Order><Path>reg.exe add ""HKLM\SYSTEM\Setup\LabConfig"" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>")
            $wpeOrder++
            $wpeRunSync.Add("<RunSynchronousCommand wcm:action=""add""><Order>$wpeOrder</Order><Path>reg.exe add ""HKLM\SYSTEM\Setup\LabConfig"" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>")
            $wpeOrder++
        }

        $wpeSetupBlock = ""
        if ($wpeRunSync.Count -gt 0) {
            $wpeSetupBlock = @"
        <component name="Microsoft-Windows-Setup" processorArchitecture="$detectedArch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                $($wpeRunSync -join "`n                ")
            </RunSynchronous>
            <UserData>
                <ProductKey><Key>00000-00000-00000-00000-00000</Key><WillShowUI>OnError</WillShowUI></ProductKey>
                <AcceptEula>true</AcceptEula>
            </UserData>
        </component>
"@
        }

        $wpeIntlBlock = ""
        if (-not $chkInteractiveLang.Checked) {
            $sLang = ($cmbSetupLang.Text -split ' ')[0]
            $sysL  = ($cmbSysLang.Text   -split ' ')[0]
            $kL    = ($cmbKeyboard.Text   -split ' ')[0]

            $wpeIntlBlock = @"
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="$detectedArch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <SetupUILanguage>
                <UILanguage>$sLang</UILanguage>
            </SetupUILanguage>
            <InputLocale>$kL</InputLocale>
            <SystemLocale>$sysL</SystemLocale>
            <UILanguage>$sysL</UILanguage>
            <UserLocale>$sysL</UserLocale>
        </component>
"@
        }

        $wpeBlock = ""
        if ($wpeSetupBlock -ne "" -or $wpeIntlBlock -ne "") {
            $wpeBlock = @"
    <settings pass="windowsPE">
$wpeIntlBlock
$wpeSetupBlock
    </settings>
"@
        }

        # ── Fase specialize: BypassNRO ────────────────────────────────
        $specializeBlock = ""
        if ($chkNRO.Checked) {
            $specializeBlock = @"
    <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="$detectedArch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
"@
        }

        # ── Fase oobeSystem: FirstLogonCommands ───────────────────────
        $cmds     = New-Object System.Collections.Generic.List[string]
        $order    = 1
        $psPrefix = if ($chkHidePS.Checked) {
            "powershell.exe -WindowStyle Hidden -NoProfile -Command"
        } else {
            "powershell.exe -NoProfile -Command"
        }

        # Telemetria
        if ($chkTelemetry.Checked) {
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection"" /v AllowTelemetry /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack"" /v Start /t REG_DWORD /d 4 /f</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SYSTEM\CurrentControlSet\Services\dmwappushservice"" /v Start /t REG_DWORD /d 4 /f</CommandLine></SynchronousCommand>")
            $order++
        }

        # BitLocker
        if ($chkBitlocker.Checked) {
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>$psPrefix `"Get-BitLockerVolume | Where-Object { `$_.ProtectionStatus -eq 'On' } | ForEach-Object { Disable-BitLocker -MountPoint `$_.MountPoint }`"</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SYSTEM\CurrentControlSet\Services\BDESVC"" /v Start /t REG_DWORD /d 4 /f</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Policies\Microsoft\FVE"" /v EnableBDEWithNoTPM /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Default"" /v Value /t REG_SZ /d Deny /f</CommandLine></SynchronousCommand>")
            $order++
        }

        # Cortana y Personalizacion de Entrada
        if ($chkCortana.Checked) {
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search"" /v AllowCortana /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization"" /v AllowInputPersonalization /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization"" /v RestrictImplicitInkCollection /t REG_DWORD /d 1 /f</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization"" /v RestrictImplicitTextCollection /t REG_DWORD /d 1 /f</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKCU\Software\Microsoft\Windows\CurrentVersion\Search"" /v CortanaEnabled /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKCU\Software\Microsoft\Windows\CurrentVersion\Search"" /v CanCortanaBeEnabled /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>")
            $order++
            # Bing Search en el menu inicio (W11 24H2)
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKCU\Software\Microsoft\Windows\CurrentVersion\Search"" /v BingSearchEnabled /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>")
            $order++
        }

        # Plan de energia: Alto Rendimiento
        if ($chkPowerPlan.Checked) {
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c</CommandLine></SynchronousCommand>")
            $order++
        }

        # Deshabilitar Fast Startup
        if ($chkFastBoot.Checked) {
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power"" /v HiberbootEnabled /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>")
            $order++
        }

        # Visuals: barra izquierda + menu clasico
        if ($chkVisuals.Checked) {
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"" /v TaskbarAl /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"" /ve /f</CommandLine></SynchronousCommand>")
            $order++
        }

        # Extensiones y rutas largas
        if ($chkExt.Checked) {
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"" /v HideFileExt /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SYSTEM\CurrentControlSet\Control\FileSystem"" /v LongPathsEnabled /t REG_DWORD /d 1 /f</CommandLine></SynchronousCommand>")
            $order++
        }

        # Bloatware: Copilot, Widgets, Sugerencias
        if ($chkBloat.Checked) {
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot"" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Policies\Microsoft\Dsh"" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>")
            $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent"" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f</CommandLine></SynchronousCommand>")
            $order++
        }

        # Rehabilitar WinRE al finalizar (siempre)
        $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>cmd.exe /c reagentc /enable</CommandLine></SynchronousCommand>")
        $order++

        $logonCommandsBlock = ""
        if ($cmds.Count -gt 0) {
            $logonCommandsBlock = "<FirstLogonCommands>`n" + ($cmds -join "`n") + "`n            </FirstLogonCommands>"
        }

        # Cuentas de usuario
        $userAccountsBlock = ""
        $isInteractive     = $chkInteractiveUser.Checked -or [string]::IsNullOrWhiteSpace($txtUser.Text)
        $hideWifiXmlVal    = if ($chkHideWifi.Checked) { "true" } else { "false" }

        if ($isInteractive) {
            $hideLocal = "false"
        } else {
            $hideLocal = "true"

            $userAccountsBlock = @"
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Password>
                            <Value>$safePass</Value>
                            <PlainText>true</PlainText>
                        </Password>
                        <Description>Admin Local</Description>
                        <DisplayName>$safeUser</DisplayName>
                        <Group>Administrators</Group>
                        <Name>$safeUser</Name>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                <Password>
                    <Value>$safePass</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>$safeUser</Username>
            </AutoLogon>
"@
        }

        # Bloque Internacional OOBE
        $oobeIntlBlock = ""
        if (-not $chkInteractiveLang.Checked) {
            $oobeIntlBlock = @"
        <component name="Microsoft-Windows-International-Core" processorArchitecture="$detectedArch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <InputLocale>$kL</InputLocale>
            <SystemLocale>$sysL</SystemLocale>
            <UILanguage>$sysL</UILanguage>
            <UserLocale>$sysL</UserLocale>
        </component>
"@
        }

        # ── Ensamblado XML final ──────────────────────────────────────
        $xmlContent = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    $wpeBlock
    $specializeBlock
    <settings pass="oobeSystem">
        $oobeIntlBlock
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$detectedArch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            $computerNameBlock
            $userAccountsBlock
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>$hideLocal</HideLocalAccountScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>$hideWifiXmlVal</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
            $logonCommandsBlock
        </component>
    </settings>
</unattend>
"@
        & $InjectXmlLogic -Content $xmlContent -Desc "XML Generado Localmente"
    })

    # ==================================================================
    # EVENTOS DE LA PESTANA IMPORTAR
    # ==================================================================
    $lnkWeb.Add_Click({
        Start-Process "https://schneegans.de/windows/unattend-generator/"
    })

    $btnBrowse.Add_Click({
        $ofd        = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "XML (*.xml)|*.xml"
        if ($ofd.ShowDialog() -eq 'OK') {
            $txtImpPath.Text = $ofd.FileName
            try {
                $check = [xml](Get-Content $ofd.FileName)
                if ($check.unattend) {
                    $lblValid.Text        = "XML Valido detectado."
                    $lblValid.ForeColor   = [System.Drawing.Color]::LightGreen
                    $btnInjectImp.Enabled = $true
                } else { throw "Nodo <unattend> no encontrado" }
            } catch {
                $lblValid.Text        = "Archivo invalido."
                $lblValid.ForeColor   = [System.Drawing.Color]::Salmon
                $btnInjectImp.Enabled = $false
            }
        }
    })

    $btnInjectImp.Add_Click({
        if (Test-Path $txtImpPath.Text) {
            & $InjectXmlLogic -Content (Get-Content $txtImpPath.Text -Raw) -Desc "XML Importado"
        }
    })

    # ------------------------------------------------------------------
    # Mostrar y limpiar
    # ------------------------------------------------------------------
    $form.ShowDialog() | Out-Null
    $form.Dispose()
}