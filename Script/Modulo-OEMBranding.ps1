# =================================================================
#  Modulo-OEMBranding
#
#  CONTENIDO   : Show-OEMBranding-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - Mount-Hives            : montar colmenas offline del registro
#    - Unmount-Hives          : desmontar colmenas offline del registro
#    - Enable-Privileges      : elevar privilegios de token para reg offline
#    - Unlock-OfflineKey      : tomar propiedad de clave de registro offline
#    - Restore-KeyOwner       : restaurar propietario de clave de registro offline
#  CARGA       : . "$PSScriptRoot\Modulo-OEMBranding.ps1"
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

function Show-OEMBranding-GUI {

    # ------------------------------------------------------------------
    # 1. Validacion de imagen montada y montaje de hives
    # ------------------------------------------------------------------
    if ($Script:IMAGE_MOUNTED -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return
    }

    Write-Log -LogLevel INFO -Message "OEM_Branding: Solicitando montaje de colmenas de registro..."
    if (-not (Mount-Hives)) { return }

    $script:isOemApplying = $false

    # ------------------------------------------------------------------
    # Helper del Modulo: Escritura atomica en clave de registro offline
    # ------------------------------------------------------------------
    function Set-OfflineKey {
        param(
            [string]$SubPath,
            [hashtable]$Values
        )
        $psPath = "HKLM:\$SubPath"
        try {
            Unlock-OfflineKey -KeyPath $psPath
            if (-not (Test-Path $psPath)) {
                New-Item -Path $psPath -Force -ErrorAction Stop | Out-Null
            }
            foreach ($kv in $Values.GetEnumerator()) {
                Set-ItemProperty `
                    -Path  $psPath `
                    -Name  $kv.Key `
                    -Value $kv.Value.Value `
                    -Type  $kv.Value.Type `
                    -Force `
                    -ErrorAction Stop
            }
        } finally {
            Restore-KeyOwner -KeyPath $psPath
        }
    }

    # ------------------------------------------------------------------
    # Funcion de clasificacion de ediciones
    # ------------------------------------------------------------------
    function Get-EditionCategory {
        param([string]$EditionId)
        
        $baseEdition = $EditionId -replace 'N$|KN$|SingleLanguage$|China$|GNE$'
        
        switch -Regex ($baseEdition) {
            '^Core$|^Home$|^Starter$|^CoreCountrySpecific$' { return "Home" }
            '^Professional$|^Pro$|^ProfessionalWorkstation$|^ProfessionalEducation$|^ProEducation$' { return "Pro" }
            '^Enterprise$|^EnterpriseG$|^EnterpriseS$|^EnterpriseLTSC$' { return "Enterprise" }
            '^Education$|^EnterpriseEval$' { return "Education" }
            '^LTSC$|^IoTEnterprise$|^IoTEnterpriseS$' { return "LTSC" }
            '^Server' { return "Server" }
            default { return "Pro" }
        }
    }

    # ------------------------------------------------------------------
    # 2. Construccion del formulario
    # ------------------------------------------------------------------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "OEM Branding - Arquitectura Zero-GPO y Active Setup"
    $form.Size            = New-Object System.Drawing.Size(980, 560)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    $lblTitle          = New-Object System.Windows.Forms.Label
    $lblTitle.Text     = "Inyeccion NATIVA de Branding y Propiedades del Sistema"
    $lblTitle.Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = "20, 15"
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    $lblOsInfo           = New-Object System.Windows.Forms.Label
    $lblOsInfo.Text      = "Analizando imagen..."
    $lblOsInfo.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblOsInfo.ForeColor = [System.Drawing.Color]::LightGreen
    $lblOsInfo.Location  = "20, 42"
    $lblOsInfo.AutoSize  = $true
    $form.Controls.Add($lblOsInfo)

    # ==================================================================
    # COLUMNA IZQUIERDA: Grupo 1 - Imagenes y Tema
    # ==================================================================
    $grpImages           = New-Object System.Windows.Forms.GroupBox
    $grpImages.Text      = " Politicas de Imagen y Tema "
    $grpImages.Location  = "20, 70"
    $grpImages.Size      = "520, 380"
    $grpImages.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($grpImages)

    # --- FONDO DE ESCRITORIO ---
    $lblWall           = New-Object System.Windows.Forms.Label
    $lblWall.Text      = "Fondo de Escritorio:"
    $lblWall.Location  = "15, 30"
    $lblWall.AutoSize  = $true
    $lblWall.ForeColor = [System.Drawing.Color]::White
    $grpImages.Controls.Add($lblWall)

    $lblWallHint           = New-Object System.Windows.Forms.Label
    $lblWallHint.Text      = "[ Recom: 1920x1080 o 4K (16:9) ]"
    $lblWallHint.Location  = "165, 30"
    $lblWallHint.AutoSize  = $true
    $lblWallHint.ForeColor = [System.Drawing.Color]::Silver
    $grpImages.Controls.Add($lblWallHint)

    $txtWall           = New-Object System.Windows.Forms.TextBox
    $txtWall.Location  = "15, 50"
    $txtWall.Size      = "235, 23"
    $txtWall.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtWall.ForeColor = [System.Drawing.Color]::White
    $txtWall.ReadOnly  = $true
    $grpImages.Controls.Add($txtWall)

    $btnWall           = New-Object System.Windows.Forms.Button
    $btnWall.Text      = "Examinar..."
    $btnWall.Location  = "260, 48"
    $btnWall.Size      = "80, 26"
    $btnWall.BackColor = [System.Drawing.Color]::Gray
    $btnWall.FlatStyle = "Flat"
    $grpImages.Controls.Add($btnWall)

    $picWall                = New-Object System.Windows.Forms.PictureBox
    $picWall.Location       = "355, 25"
    $picWall.Size           = "144, 81"
    $picWall.SizeMode       = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $picWall.BackColor      = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $picWall.BorderStyle    = [System.Windows.Forms.BorderStyle]::FixedSingle
    $grpImages.Controls.Add($picWall)

    # --- PANTALLA DE BLOQUEO ---
    $lblLock           = New-Object System.Windows.Forms.Label
    $lblLock.Text      = "Pantalla de Bloqueo:"
    $lblLock.Location  = "15, 120"
    $lblLock.AutoSize  = $true
    $lblLock.ForeColor = [System.Drawing.Color]::White
    $grpImages.Controls.Add($lblLock)

    $lblLockHint           = New-Object System.Windows.Forms.Label
    $lblLockHint.Text      = "[ Recom: 1920x1080 o 4K (16:9) ]"
    $lblLockHint.Location  = "165, 120"
    $lblLockHint.AutoSize  = $true
    $lblLockHint.ForeColor = [System.Drawing.Color]::Silver
    $grpImages.Controls.Add($lblLockHint)

    $txtLock           = New-Object System.Windows.Forms.TextBox
    $txtLock.Location  = "15, 140"
    $txtLock.Size      = "235, 23"
    $txtLock.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtLock.ForeColor = [System.Drawing.Color]::White
    $txtLock.ReadOnly  = $true
    $grpImages.Controls.Add($txtLock)

    $btnLock           = New-Object System.Windows.Forms.Button
    $btnLock.Text      = "Examinar..."
    $btnLock.Location  = "260, 138"
    $btnLock.Size      = "80, 26"
    $btnLock.BackColor = [System.Drawing.Color]::Gray
    $btnLock.FlatStyle = "Flat"
    $grpImages.Controls.Add($btnLock)

    $picLock                = New-Object System.Windows.Forms.PictureBox
    $picLock.Location       = "355, 115"
    $picLock.Size           = "144, 81"
    $picLock.SizeMode       = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $picLock.BackColor      = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $picLock.BorderStyle    = [System.Windows.Forms.BorderStyle]::FixedSingle
    $grpImages.Controls.Add($picLock)

    # --- FOTO DE PERFIL ---
    $lblAvatar           = New-Object System.Windows.Forms.Label
    $lblAvatar.Text      = "Foto de Perfil:"
    $lblAvatar.Location  = "15, 210"
    $lblAvatar.AutoSize  = $true
    $lblAvatar.ForeColor = [System.Drawing.Color]::White
    $grpImages.Controls.Add($lblAvatar)

    $lblAvatarHint           = New-Object System.Windows.Forms.Label
    $lblAvatarHint.Text      = "[ Recom: Cuadrado 448x448 px ]"
    $lblAvatarHint.Location  = "165, 210"
    $lblAvatarHint.AutoSize  = $true
    $lblAvatarHint.ForeColor = [System.Drawing.Color]::Silver
    $grpImages.Controls.Add($lblAvatarHint)

    $txtAvatar           = New-Object System.Windows.Forms.TextBox
    $txtAvatar.Location  = "15, 230"
    $txtAvatar.Size      = "235, 23"
    $txtAvatar.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtAvatar.ForeColor = [System.Drawing.Color]::White
    $txtAvatar.ReadOnly  = $true
    $grpImages.Controls.Add($txtAvatar)

    $btnAvatar           = New-Object System.Windows.Forms.Button
    $btnAvatar.Text      = "Examinar..."
    $btnAvatar.Location  = "260, 228"
    $btnAvatar.Size      = "80, 26"
    $btnAvatar.BackColor = [System.Drawing.Color]::Gray
    $btnAvatar.FlatStyle = "Flat"
    $grpImages.Controls.Add($btnAvatar)

    $picAvatar                = New-Object System.Windows.Forms.PictureBox
    $picAvatar.Location       = "382, 205"
    $picAvatar.Size           = "90, 90"
    $picAvatar.SizeMode       = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $picAvatar.BackColor      = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $picAvatar.BorderStyle    = [System.Windows.Forms.BorderStyle]::FixedSingle
    $grpImages.Controls.Add($picAvatar)

    # --- TEMA ---
    $lblTheme          = New-Object System.Windows.Forms.Label
    $lblTheme.Text     = "Tema Principal:"
    $lblTheme.Location = "15, 310"
    $lblTheme.AutoSize = $true
    $lblTheme.ForeColor = [System.Drawing.Color]::White
    $grpImages.Controls.Add($lblTheme)

    $radThemeNone          = New-Object System.Windows.Forms.RadioButton
    $radThemeNone.Text     = "No alterar"
    $radThemeNone.Location = "120, 308"
    $radThemeNone.AutoSize = $true
    $radThemeNone.Checked  = $true
    $grpImages.Controls.Add($radThemeNone)

    $radThemeDark          = New-Object System.Windows.Forms.RadioButton
    $radThemeDark.Text     = "Oscuro"
    $radThemeDark.Location = "220, 308"
    $radThemeDark.AutoSize = $true
    $grpImages.Controls.Add($radThemeDark)

    $radThemeLight          = New-Object System.Windows.Forms.RadioButton
    $radThemeLight.Text     = "Claro"
    $radThemeLight.Location = "310, 308"
    $radThemeLight.AutoSize = $true
    $grpImages.Controls.Add($radThemeLight)
	
	# --- CHECKBOX DE BLOQUEO PERMANENTE CORPORATIVO ---
    $chkForcePolicy          = New-Object System.Windows.Forms.CheckBox
    $chkForcePolicy.Text     = "Bloquear permanentemente (Modo Corporativo / GPO)"
    $chkForcePolicy.Location = "15, 345"
    $chkForcePolicy.Size     = "450, 23"
    $chkForcePolicy.Font     = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $chkForcePolicy.ForeColor = [System.Drawing.Color]::OrangeRed
    $chkForcePolicy.FlatStyle = "Flat"
    $grpImages.Controls.Add($chkForcePolicy)

    # ==================================================================
    # COLUMNA DERECHA: Grupo 2 - Informacion OEM
    # ==================================================================
    $grpOem           = New-Object System.Windows.Forms.GroupBox
    $grpOem.Text      = " Informacion del Ensamblador (OEM) "
    $grpOem.Location  = "560, 70"
    $grpOem.Size      = "380, 380"
    $grpOem.ForeColor = [System.Drawing.Color]::Orange
    $form.Controls.Add($grpOem)

    $lblFab           = New-Object System.Windows.Forms.Label
    $lblFab.Text      = "Fabricante:"
    $lblFab.Location  = "20, 35"
    $lblFab.AutoSize  = $true
    $lblFab.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblFab)

    $txtFab           = New-Object System.Windows.Forms.TextBox
    $txtFab.Location  = "20, 55"
    $txtFab.Size      = "340, 23"
    $txtFab.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtFab.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($txtFab)

    $lblMod           = New-Object System.Windows.Forms.Label
    $lblMod.Text      = "Modelo del Equipo:"
    $lblMod.Location  = "20, 100"
    $lblMod.AutoSize  = $true
    $lblMod.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblMod)

    $txtMod           = New-Object System.Windows.Forms.TextBox
    $txtMod.Location  = "20, 120"
    $txtMod.Size      = "340, 23"
    $txtMod.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtMod.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($txtMod)

    $lblUrl           = New-Object System.Windows.Forms.Label
    $lblUrl.Text      = "Sitio Web de Soporte (URL):"
    $lblUrl.Location  = "20, 165"
    $lblUrl.AutoSize  = $true
    $lblUrl.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblUrl)

    $txtUrl           = New-Object System.Windows.Forms.TextBox
    $txtUrl.Location  = "20, 185"
    $txtUrl.Size      = "340, 23"
    $txtUrl.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtUrl.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($txtUrl)

    $lblPhone           = New-Object System.Windows.Forms.Label
    $lblPhone.Text      = "Telefono de Soporte:"
    $lblPhone.Location  = "20, 230"
    $lblPhone.AutoSize  = $true
    $lblPhone.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblPhone)

    $txtPhone           = New-Object System.Windows.Forms.TextBox
    $txtPhone.Location  = "20, 250"
    $txtPhone.Size      = "340, 23"
    $txtPhone.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtPhone.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($txtPhone)

    $lblHours           = New-Object System.Windows.Forms.Label
    $lblHours.Text      = "Horario de Atencion:"
    $lblHours.Location  = "20, 295"
    $lblHours.AutoSize  = $true
    $lblHours.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblHours)

    $txtHours           = New-Object System.Windows.Forms.TextBox
    $txtHours.Location  = "20, 315"
    $txtHours.Size      = "340, 23"
    $txtHours.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtHours.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($txtHours)

    # ==================================================================
    # BARRA DE ESTADO Y BOTON APLICAR
    # ==================================================================
    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "Listo."
    $lblStatus.Location  = "20, 480"
    $lblStatus.Size      = "450, 18"
    $lblStatus.ForeColor = [System.Drawing.Color]::Silver
    $form.Controls.Add($lblStatus)

    $btnApply           = New-Object System.Windows.Forms.Button
    $btnApply.Text      = "APLICAR BRANDING A LA IMAGEN"
    $btnApply.Location  = "560, 465"
    $btnApply.Size      = "380, 40"
    $btnApply.BackColor = [System.Drawing.Color]::SeaGreen
    $btnApply.FlatStyle = "Flat"
    $btnApply.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnApply)

    # ------------------------------------------------------------------
    # 3. Eventos
    # ------------------------------------------------------------------

    # Precarga de datos existentes y deteccion de OS en el registro offline
    $form.Add_Shown({
        $form.Refresh()
        Write-Log -LogLevel INFO -Message "OEM_Branding: Precargando datos y analizando imagen (Motor Nativo)..."

        $regCurrentVer = "HKLM:\OfflineSoftware\Microsoft\Windows NT\CurrentVersion"
        $verData       = Get-ItemProperty -Path $regCurrentVer -ErrorAction SilentlyContinue

        if ($verData) {
            $build   = if ($null -ne $verData.CurrentBuildNumber) { [int]$verData.CurrentBuildNumber } else { 0 }
            $edition = if ($null -ne $verData.EditionID)          { $verData.EditionID }               else { "Desconocida" }
            $dispVer = if ($null -ne $verData.DisplayVersion)     { $verData.DisplayVersion }          else { "" }

            $osName = if     ($build -ge 26100) { "Windows 11 24H2+" }
                      elseif ($build -ge 22621) { "Windows 11 22H2/23H2" }
                      elseif ($build -ge 22000) { "Windows 11 21H2" }
                      elseif ($build -ge 19041) { "Windows 10 ($dispVer)" }
                      else                      { "Build $build" }

            $editionCategory = Get-EditionCategory -EditionId $edition

            $lblOsInfo.Text = "Detectado: $osName | Edicion: $edition ($editionCategory) | Build: $build"
        }

        # Precargar OEMInformation
        $oemPath = "HKLM:\OfflineSoftware\Microsoft\Windows\CurrentVersion\OEMInformation"
        if (Test-Path $oemPath) {
            try {
                $oemData = Get-ItemProperty -Path $oemPath -ErrorAction SilentlyContinue
                if ($oemData) {
                    if ($null -ne $oemData.Manufacturer) { $txtFab.Text   = $oemData.Manufacturer }
                    if ($null -ne $oemData.Model)        { $txtMod.Text   = $oemData.Model }
                    if ($null -ne $oemData.SupportURL)   { $txtUrl.Text   = $oemData.SupportURL }
                    if ($null -ne $oemData.SupportPhone) { $txtPhone.Text = $oemData.SupportPhone }
                    if ($null -ne $oemData.SupportHours) { $txtHours.Text = $oemData.SupportHours }
                }
            } catch {}
        }

        # Precargar tema actual del perfil Default
        $themePath = "HKLM:\OfflineUser\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        if (Test-Path $themePath) {
            try {
                $themeData = Get-ItemProperty -Path $themePath -ErrorAction SilentlyContinue
                if ($null -ne $themeData.AppsUseLightTheme) {
                    if     ($themeData.AppsUseLightTheme -eq 0) { $radThemeDark.Checked  = $true }
                    elseif ($themeData.AppsUseLightTheme -eq 1) { $radThemeLight.Checked = $true }
                }
            } catch {}
        }
    })

    $btnWall.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Imagenes (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png"
        if ($ofd.ShowDialog() -eq 'OK') {
            $txtWall.Text = $ofd.FileName
            try {
                if ($null -ne $picWall.Image) { $picWall.Image.Dispose() }
                $bytes = [System.IO.File]::ReadAllBytes($ofd.FileName)
                $ms = [System.IO.MemoryStream]::new($bytes)
                try {
                    $tmpImg = [System.Drawing.Image]::FromStream($ms)
                    $picWall.Image = New-Object System.Drawing.Bitmap($tmpImg)
                    $tmpImg.Dispose()
                } finally {
                    $ms.Dispose()
                }
            } catch {}
        }
    })

    $btnLock.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Imagenes (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png"
        if ($ofd.ShowDialog() -eq 'OK') {
            $txtLock.Text = $ofd.FileName
            try {
                if ($null -ne $picLock.Image) { $picLock.Image.Dispose() }
                $bytes = [System.IO.File]::ReadAllBytes($ofd.FileName)
                $ms = [System.IO.MemoryStream]::new($bytes)
                try {
                    $tmpImg = [System.Drawing.Image]::FromStream($ms)
                    $picLock.Image = New-Object System.Drawing.Bitmap($tmpImg)
                    $tmpImg.Dispose()
                } finally {
                    $ms.Dispose()
                }
            } catch {}
        }
    })

    $btnAvatar.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Imagenes (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png"
        if ($ofd.ShowDialog() -eq 'OK') {
            $txtAvatar.Text = $ofd.FileName
            try {
                if ($null -ne $picAvatar.Image) { $picAvatar.Image.Dispose() }
                $bytes = [System.IO.File]::ReadAllBytes($ofd.FileName)
                $ms = [System.IO.MemoryStream]::new($bytes)
                try {
                    $tmpImg = [System.Drawing.Image]::FromStream($ms)
                    $picAvatar.Image = New-Object System.Drawing.Bitmap($tmpImg)
                    $tmpImg.Dispose()
                } finally {
                    $ms.Dispose()
                }
            } catch {}
        }
    })

    # ==================================================================
    # MOTOR DE APLICACION PRINCIPAL (Zero-GPO & Active Setup)
    # ==================================================================
    $btnApply.Add_Click({

        if (-not $txtWall.Text  -and -not $txtLock.Text  -and $radThemeNone.Checked -and
            -not $txtFab.Text   -and -not $txtMod.Text   -and -not $txtUrl.Text -and
            -not $txtPhone.Text -and -not $txtHours.Text -and -not $txtAvatar.Text) {
            [System.Windows.Forms.MessageBox]::Show("Selecciona al menos un parametro.", "Aviso", 'OK', 'Warning')
            return
        }

        $script:isOemApplying    = $true
        $form.Cursor             = [System.Windows.Forms.Cursors]::WaitCursor
        $btnApply.Enabled        = $false
        $lblStatus.Text          = "Analizando imagen e iniciando motor arquitectonico..."
        $lblStatus.ForeColor     = [System.Drawing.Color]::Yellow
        $form.Refresh()

        Write-Log -LogLevel ACTION -Message "OEM_Branding: Iniciando motor de inyeccion nativo Zero-GPO."

        try {
            $editionId     = "Desconocida"
            $buildNumber   = 0
            $dispVerEngine = ""

            $verData = Get-ItemProperty -Path "HKLM:\OfflineSoftware\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue

            if ($verData) {
                if ($null -ne $verData.EditionID)          { $editionId      = $verData.EditionID }
                if ($null -ne $verData.CurrentBuildNumber) { $buildNumber    = [int]$verData.CurrentBuildNumber }
                if ($null -ne $verData.DisplayVersion)     { $dispVerEngine  = $verData.DisplayVersion }
            }

            $isW11        = $buildNumber -ge 22000
            $isW11_22H2p  = $buildNumber -ge 22621
            $isW11_24H2p  = $buildNumber -ge 26100
            
            $editionCategory = Get-EditionCategory -EditionId $editionId

            $osLabel = if     ($isW11_24H2p) { "W11 24H2+" }
                       elseif ($isW11_22H2p) { "W11 22H2/23H2" }
                       elseif ($isW11)       { "W11 21H2" }
                       elseif ($buildNumber -ge 19041) {
                           if ($dispVerEngine) { "W10 ($dispVerEngine)" } else { "W10 (Build $buildNumber)" }
                       }
                       else { "W10 (Build $buildNumber)" }

            $lblStatus.Text = "Aplicando para $osLabel ($editionId)..."
            $form.Refresh()

            Enable-Privileges

            # ── CREACION DE DIRECTORIOS AISLADOS (WRP Bypass) ───────────────
            $corpDir = Join-Path $Script:MOUNT_DIR "Windows\Web\Wallpaper\Corporate"
            if (-not (Test-Path $corpDir)) { New-Item -Path $corpDir -ItemType Directory -Force | Out-Null }

            $setupScriptsDir = Join-Path $Script:MOUNT_DIR "Windows\Setup\Scripts"
            if (-not (Test-Path $setupScriptsDir)) { New-Item -Path $setupScriptsDir -ItemType Directory -Force | Out-Null }

            $wallInternal   = $null
            $lockInternal   = $null
            $avatarInternal = $null

            # ── Bloque 1: Fondo de escritorio (Inyeccion Zero-GPO via OEM.Theme) ──────
            if ($txtWall.Text -and -not (Test-Path $txtWall.Text)) {
                Write-Log -LogLevel WARN -Message "OEM_Branding: Wallpaper seleccionado ya no existe en disco ($($txtWall.Text)). Se omite."
            }
            if ($txtWall.Text -and (Test-Path $txtWall.Text)) {
                $lblStatus.Text = "Configurando perfil predeterminado (oem.theme)..."
                $form.Refresh()

                $wallExt      = [System.IO.Path]::GetExtension($txtWall.Text)
                $wallName     = "background$wallExt"
                $wallInternal = "C:\Windows\Web\Wallpaper\Corporate\$wallName"

                Copy-Item -Path $txtWall.Text -Destination (Join-Path $corpDir $wallName) -Force -ErrorAction Stop

                # Perfil Default: claves directas de escritorio (garantia independiente de oem.theme)
                # oem.theme necesita que CurrentTheme apunte a el para auto-aplicarse;
                # estas claves cubren el caso en que el shell no lo cargue automaticamente.
                Set-OfflineKey `
                    -SubPath "OfflineUser\Control Panel\Desktop" `
                    -Values @{
                        "Wallpaper"      = @{ Value = $wallInternal; Type = "String" }
                        "WallpaperStyle" = @{ Value = "10";          Type = "String" }
                        "TileWallpaper"  = @{ Value = "0";           Type = "String" }
                    }
                Write-Log -LogLevel INFO -Message "OEM_Branding: Wallpaper -> Control Panel\Desktop (perfil Default) OK"

                # ── Crear oem.theme en el perfil Default ──────────────────────
                $themeDir = Join-Path $Script:MOUNT_DIR "Users\Default\AppData\Local\Microsoft\Windows\Themes"
                if (-not (Test-Path $themeDir)) {
                    New-Item -Path $themeDir -ItemType Directory -Force | Out-Null
                }

                # Determinar modo claro/oscuro desde los radio buttons del UI.
                # Bloque 3 (Themes) los usa mas tarde para los DWORDs del registro, pero
                # oem.theme necesita SystemMode= y AppMode= en esta misma etapa.
                # Si el usuario no selecciono ninguno se asume Light (comportamiento nativo).
                $oemThemeMode = if ($radThemeDark.Checked) { "Dark" } else { "Light" }

                $oemThemeContent = @"
[Theme]
DisplayName=OEM Theme
SetLogonBackground=0

; Computer - SHIDI_SERVER
[CLSID\{20D04FE0-3AEA-1069-A2D8-08002B30309D}\DefaultIcon]
DefaultValue=%SystemRoot%\System32\imageres.dll,-109

; UsersFiles - SHIDI_USERFILES
[CLSID\{59031A47-3F72-44A7-89C5-5595FE6B30EE}\DefaultIcon]
DefaultValue=%SystemRoot%\System32\imageres.dll,-123

; Recycle Bin - SHIDI_RECYCLERFULL SHIDI_RECYCLER
[CLSID\{645FF040-5081-101B-9F08-00AA002F954E}\DefaultIcon]
Full=%SystemRoot%\System32\imageres.dll,-54
Empty=%SystemRoot%\System32\imageres.dll,-55

[Control Panel\Cursors]
AppStarting=%SystemRoot%\cursors\aero_working.ani
Arrow=%SystemRoot%\cursors\aero_arrow.cur
Crosshair=
Hand=%SystemRoot%\cursors\aero_link.cur
Help=%SystemRoot%\cursors\aero_helpsel.cur
IBeam=
No=%SystemRoot%\cursors\aero_unavail.cur
NWPen=%SystemRoot%\cursors\aero_pen.cur
SizeAll=%SystemRoot%\cursors\aero_move.cur
SizeNESW=%SystemRoot%\cursors\aero_nesw.cur
SizeNS=%SystemRoot%\cursors\aero_ns.cur
SizeNWSE=%SystemRoot%\cursors\aero_nwse.cur
SizeWE=%SystemRoot%\cursors\aero_ew.cur
UpArrow=%SystemRoot%\cursors\aero_up.cur
Wait=%SystemRoot%\cursors\aero_busy.ani
DefaultValue=Windows Default
DefaultValue.MUI=@main.cpl,-1020

[Control Panel\Desktop]
Wallpaper=$wallInternal
TileWallpaper=0
WallpaperStyle=10
Pattern=

[VisualStyles]
Path=%ResourceDir%\Themes\Aero\Aero.msstyles
ColorStyle=NormalColor
Size=NormalSize
AutoColorization=1
ColorizationColor=0XC40078D4
SystemMode=$oemThemeMode
AppMode=$oemThemeMode

[boot]
SCRNSAVE.EXE=

[MasterThemeSelector]
MTSM=RJSPBS

[Sounds]
SchemeName=@%SystemRoot%\System32\mmres.dll,-800
"@
                [System.IO.File]::WriteAllText(
                    (Join-Path $themeDir "oem.theme"),
                    $oemThemeContent,
                    [System.Text.Encoding]::ASCII
                )
                Write-Log -LogLevel INFO -Message "OEM_Branding: oem.theme completo ($oemThemeMode) creado en perfil Default -> $themeDir"
                Set-OfflineKey `
                    -SubPath "OfflineSoftware\Microsoft\Windows\CurrentVersion\Themes" `
                    -Values @{
                        "InstallTheme"      = @{ Value = ""; Type = "String" }
                        "InstallThemeLight" = @{ Value = ""; Type = "String" }
                    }
                Set-OfflineKey `
                    -SubPath "OfflineSoftware\WOW6432Node\Microsoft\Windows\CurrentVersion\Themes" `
                    -Values @{
                        "InstallTheme" = @{ Value = ""; Type = "String" }
                    }
                Write-Log -LogLevel INFO -Message "OEM_Branding: InstallTheme/InstallThemeLight suprimidos en SOFTWARE y WOW6432Node"
            }

            # ── Bloque 2: Pantalla de bloqueo (Motor C# Nativo via Active Setup o Preparación CSP) ──────
            if ($txtLock.Text -and -not (Test-Path $txtLock.Text)) {
                Write-Log -LogLevel WARN -Message "OEM_Branding: Lock Screen seleccionada ya no existe en disco ($($txtLock.Text)). Se omite."
            }
            if ($txtLock.Text -and (Test-Path $txtLock.Text)) {
                
                $lockExt      = [System.IO.Path]::GetExtension($txtLock.Text)
                $lockName     = "lockscreen$lockExt"

                $screenDir = Join-Path $Script:MOUNT_DIR "Windows\Web\Screen\Corporate"
                if (-not (Test-Path $screenDir)) { New-Item -Path $screenDir -ItemType Directory -Force | Out-Null }

                $lockInternal = "C:\Windows\Web\Screen\Corporate\$lockName"

                # Copia aislada del recurso visual en su directorio correcto (Bypass WRP)
                Copy-Item -Path $txtLock.Text -Destination (Join-Path $screenDir $lockName) -Force -ErrorAction Stop

                # Desactivar Windows Spotlight preventivamente
                Set-OfflineKey `
                    -SubPath "OfflineUser\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" `
                    -Values @{
                        "RotatingLockScreenEnabled"        = @{ Value = 0; Type = "DWord" }
                        "RotatingLockScreenOverlayEnabled" = @{ Value = 0; Type = "DWord" }
                        "SubscribedContent-338388Enabled"  = @{ Value = 0; Type = "DWord" }
                    }

                # CONDICIÓN AÑADIDA: Saltar el motor Active Setup si se usa Bloqueo Corporativo (CSP/GPO)
                if ($chkForcePolicy.Checked) {
                    $lblStatus.Text = "Preparando imagen de bloqueo para inyeccion CSP/GPO..."
                    $form.Refresh()
                    Write-Log -LogLevel INFO -Message "OEM_Branding: Bloque 2 (Active Setup) saltado por directiva GPO/CSP. Imagen copiada a $lockInternal."
                } 
                else {
                    # VALIDACION DE SEGURIDAD PARA ACTIVE SETUP
                    $parentDir = Split-Path -Path $PSScriptRoot -Parent
                    $toolsDir  = Join-Path $parentDir "Tools"
                    $zipSource = Join-Path $toolsDir "SetLockScreen.zip"

                    if (-not (Test-Path $zipSource)) {
                        Write-Log -LogLevel ERROR -Message "OEM_Branding: SetLockScreen.zip no encontrado. Se omite LockScreen."
                    } else {
                        $lblStatus.Text = "Configurando Lock Screen via binario nativo (Active Setup)..."
                        $form.Refresh()

                        $corpITDir = Join-Path $Script:MOUNT_DIR "Program Files\CorporateIT"
                        if (-not (Test-Path $corpITDir)) { New-Item -Path $corpITDir -ItemType Directory -Force | Out-Null }
                        
                        Write-Log -LogLevel INFO -Message "OEM_Branding: Descomprimiendo SetLockScreen.zip en $corpITDir"
                        Expand-Archive -Path $zipSource -DestinationPath $corpITDir -Force -ErrorAction Stop

                        $guid = "{C2A53B10-8CFC-4D99-8D1F-C04B0B4C4B5C}"
                        $stubPathValue = "C:\Program Files\CorporateIT\SetLockScreen.exe"

                        Set-OfflineKey `
                            -SubPath "OfflineSoftware\Microsoft\Active Setup\Installed Components\$guid" `
                            -Values @{
                                "StubPath"    = @{ Value = $stubPathValue; Type = "String" }
                                "IsInstalled" = @{ Value = 1; Type = "DWord" }
                                "Version"     = @{ Value = "1,0,0,0"; Type = "String" }
                            }
                            
                        Write-Log -LogLevel INFO -Message "OEM_Branding: Active Setup configurado."
                    }
                }
            }

             # ── Bloque 3: Tema visual (Modos Claro/Oscuro) ──────────────────────────────────
            $themeVal   = $null
            $themeLabel = $null
            if (-not $radThemeNone.Checked) {
                $lblStatus.Text = "Configurando esquema global de color..."
                $form.Refresh()

                $themeVal   = if ($radThemeDark.Checked) { 0 } else { 1 }
                $themeLabel = if ($radThemeDark.Checked) { "Oscuro" } else { "Claro" }

                $themeValues = @{
                    "AppsUseLightTheme"    = @{ Value = $themeVal; Type = "DWord" }
                    "SystemUsesLightTheme" = @{ Value = $themeVal; Type = "DWord" }
                    "EnableTransparency"   = @{ Value = 1;         Type = "DWord" }
                }

                Set-OfflineKey -SubPath "OfflineUser\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Values $themeValues
                Set-OfflineKey -SubPath "OfflineSoftware\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Values $themeValues
            }

            # ── Bloque 4: Metadatos OEM ───────────────────────────────────────────────
            $oemApplied = $false
            if ($txtFab.Text -or $txtMod.Text -or $txtPhone.Text -or $txtHours.Text -or $txtUrl.Text) {
                $lblStatus.Text = "Escribiendo metadatos OEM..."
                $form.Refresh()

                $oemValues = @{}
                if ($txtFab.Text)   { $oemValues["Manufacturer"] = @{ Value = $txtFab.Text;   Type = "String" } }
                if ($txtMod.Text)   { $oemValues["Model"]        = @{ Value = $txtMod.Text;   Type = "String" } }
                if ($txtUrl.Text)   { $oemValues["SupportURL"]   = @{ Value = $txtUrl.Text;   Type = "String" } }
                if ($txtPhone.Text) { $oemValues["SupportPhone"] = @{ Value = $txtPhone.Text; Type = "String" } }
                if ($txtHours.Text) { $oemValues["SupportHours"] = @{ Value = $txtHours.Text; Type = "String" } }

                Set-OfflineKey -SubPath "OfflineSoftware\Microsoft\Windows\CurrentVersion\OEMInformation" -Values $oemValues
                $oemApplied = $true
            }

            # ── Bloque 5: Foto de perfil de usuario (Escalado GDI+ Parcheado) ─────────
            if ($txtAvatar.Text -and -not (Test-Path $txtAvatar.Text)) {
                Write-Log -LogLevel WARN -Message "OEM_Branding: Foto de perfil seleccionada ya no existe en disco ($($txtAvatar.Text)). Se omite."
            }
            if ($txtAvatar.Text -and (Test-Path $txtAvatar.Text)) {
                $lblStatus.Text = "Inyectando foto de perfil predeterminada..."
                $form.Refresh()

                $avatarDestDir = Join-Path $Script:MOUNT_DIR "ProgramData\Microsoft\User Account Pictures"
                if (-not (Test-Path $avatarDestDir)) { New-Item -Path $avatarDestDir -ItemType Directory -Force | Out-Null }

                Add-Type -AssemblyName System.Drawing
                $srcBmp = $null

                try {
                    $srcBmp = [System.Drawing.Bitmap]::new($txtAvatar.Text)

                    # Recorte centrado a cuadrado antes de escalar: las dos ramas W10/W11
                    # generaban exactamente los mismos tamanos y archivos, asi que se
                    # unifican en un unico camino. El recorte evita deformar fotos que no
                    # llegan en proporcion 1:1 (antes se estiraban directo al cuadrado).
                    $side = [Math]::Min($srcBmp.Width, $srcBmp.Height)
                    $srcRect = New-Object System.Drawing.Rectangle(
                        [int](($srcBmp.Width  - $side) / 2),
                        [int](($srcBmp.Height - $side) / 2),
                        $side, $side)

                    Write-Log -LogLevel INFO -Message "OEM_Branding: Generando avatares ($osLabel) desde recorte cuadrado ${side}x${side}px."

                    $tamanos = @(32, 40, 48, 192)
                    foreach ($sz in $tamanos) {
                        $dst = [System.Drawing.Bitmap]::new($sz, $sz)
                        $g   = [System.Drawing.Graphics]::FromImage($dst)
                        $g.Clear([System.Drawing.Color]::White)
                        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                        $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                        $destRect = New-Object System.Drawing.Rectangle(0, 0, $sz, $sz)
                        $g.DrawImage($srcBmp, $destRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
                        $g.Dispose()
                        $dst.Save((Join-Path $avatarDestDir "user-$sz.png"), [System.Drawing.Imaging.ImageFormat]::Png)
                        $dst.Dispose()
                    }

                    $dstBase = [System.Drawing.Bitmap]::new(448, 448)
                    $gBase   = [System.Drawing.Graphics]::FromImage($dstBase)
                    $gBase.Clear([System.Drawing.Color]::White)
                    $gBase.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $gBase.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $gBase.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $destRectBase = New-Object System.Drawing.Rectangle(0, 0, 448, 448)
                    $gBase.DrawImage($srcBmp, $destRectBase, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
                    $gBase.Dispose()

                    $dstBase.Save((Join-Path $avatarDestDir "user.png"), [System.Drawing.Imaging.ImageFormat]::Png)
                    $dstBase.Save((Join-Path $avatarDestDir "user.bmp"), [System.Drawing.Imaging.ImageFormat]::Bmp)
                    $dstBase.Save((Join-Path $avatarDestDir "guest.png"), [System.Drawing.Imaging.ImageFormat]::Png)
                    $dstBase.Save((Join-Path $avatarDestDir "guest.bmp"), [System.Drawing.Imaging.ImageFormat]::Bmp)
                    $dstBase.Dispose()
                    $avatarInternal = "OK"
                } finally {
                    if ($null -ne $srcBmp) { $srcBmp.Dispose() }
                }
            }

			# ── Bloque 6: Politicas de Bloqueo Corporativo (CSP y GPO) ──────────────────────
            if ($chkForcePolicy.Checked) {
                $lblStatus.Text = "Aplicando politicas de bloqueo corporativo (CSP/GPO)..."
                $form.Refresh()

                # --- EVALUACIÓN DINÁMICA DE SOPORTE GPO/CSP ---
                $hasCSP = $true
                $gpoLockOk = $false

                if ($editionCategory -match 'Enterprise|Education|Server|LTSC') {
                    # Soportado en todas las builds de Windows 10 y 11
                    $gpoLockOk = $true
                } elseif ($editionCategory -eq 'Pro' -and $isW11_22H2p) {
                    # Soportado en Windows 11 22H2 (Build 22621) o superior
                    $gpoLockOk = $true
                }

                if (-not $gpoLockOk) {
                    Write-Log -LogLevel WARN -Message "OEM_Branding: La GPO de bloqueo de LockScreen no esta soportada oficialmente en $editionId (Build $buildNumber). El sistema la ignorara."
                }

                # 1. Inyeccion de CSP (las claves directas de Control Panel\Desktop ya
                #    quedaron escritas de forma incondicional en el Bloque 1; repetirlas
                #    aqui solo duplicaria ciclos de Unlock/Restore sobre la misma clave)
                if ($null -ne $wallInternal -and $hasCSP) {
                    Set-OfflineKey -SubPath "OfflineSoftware\Microsoft\Windows\CurrentVersion\PersonalizationCSP" -Values @{
                        "DesktopImagePath"   = @{ Value = $wallInternal; Type = "String" }
                        "DesktopImageUrl"    = @{ Value = $wallInternal; Type = "String" }
                        "DesktopImageStatus" = @{ Value = 1;             Type = "DWord"  }
                    }
                }

                # 2. Inyeccion de CSP y GPO para LockScreen
                if ($null -ne $lockInternal) {
                    if ($hasCSP) {
                        Set-OfflineKey -SubPath "OfflineSoftware\Microsoft\Windows\CurrentVersion\PersonalizationCSP" -Values @{
                            "LockScreenImagePath"   = @{ Value = $lockInternal; Type = "String" }
                            "LockScreenImageUrl"    = @{ Value = $lockInternal; Type = "String" }
                            "LockScreenImageStatus" = @{ Value = 1;             Type = "DWord"  }
                        }
                    }

                    if ($gpoLockOk) {
                        Set-OfflineKey -SubPath "OfflineSoftware\Policies\Microsoft\Windows\Personalization" -Values @{
                            "LockScreenImage"      = @{ Value = $lockInternal; Type = "String" }
                            "NoChangingLockScreen" = @{ Value = 1;             Type = "DWord" }
                        }
                    }
                }

                Write-Log -LogLevel ACTION -Message "OEM_Branding: Politicas de bloqueo corporativo (CSP y GPO) evaluadas e inyectadas."
            }

            $methodsUsed = @()
            
            if ($null -ne $wallInternal) { 
                if ($chkForcePolicy.Checked) {
                    $methodsUsed += "Fondo de escritorio (Inyeccion CSP)"
                } else {
                    $methodsUsed += "Fondo de escritorio (oem.theme)"
                }
            }
            
            if ($null -ne $lockInternal) { 
                if ($chkForcePolicy.Checked) {
                    if ($gpoLockOk) {
                        $methodsUsed += "Pantalla de Bloqueo (Inyeccion CSP y GPO)"
                    } else {
                        $methodsUsed += "Pantalla de Bloqueo (Inyeccion CSP - Bloqueo GPO Omitido)"
                    }
                } else {
                    $methodsUsed += "Pantalla de Bloqueo (Active Setup / Zero-GPO)"
                }
            }
            
            if ($null -ne $themeVal)       { $methodsUsed += "Tema visual ($themeLabel)" }
            if ($oemApplied)               { $methodsUsed += "Metadatos OEM (OEMInformation)" }
            if ($null -ne $avatarInternal) { $methodsUsed += "Foto de Perfil (Escalado GDI+)" }
            
            if ($chkForcePolicy.Checked) { 
                if ($gpoLockOk) {
                    $methodsUsed += "Bloqueo Permanente (Politicas Aplicadas)" 
                } else {
                    $methodsUsed += "Bloqueo Permanente (Parcial - Edicion/Build no soportada)" 
                }
            }

            $msg  = "Branding aplicado exitosamente.`n`n"
            $msg += "OS: $osLabel | Edicion: $editionId ($editionCategory)`n"
            $msg += "Arquitectura desplegada:`n  - $($methodsUsed -join "`n  - ")"

            Write-Log -LogLevel ACTION -Message "OEM_Branding: Proceso Zero-GPO completado. $($methodsUsed -join ' | ')"
            $lblStatus.Text      = "Completado exitosamente."
            $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
            [System.Windows.Forms.MessageBox]::Show($msg, "Exito", 'OK', 'Information')

        } catch {
            Write-Log -LogLevel ERROR -Message "OEM_Branding: Fallo critico - $($_.Exception.Message)"
            $lblStatus.Text      = "Error."
            $lblStatus.ForeColor = [System.Drawing.Color]::Salmon
            [System.Windows.Forms.MessageBox]::Show(
                "Error al aplicar Branding:`n$($_.Exception.Message)",
                "Error", 'OK', 'Error')
        } finally {
            $script:isOemApplying = $false
            $form.Cursor          = [System.Windows.Forms.Cursors]::Default
            $btnApply.Enabled     = $true
        }
    })

    # Cierre seguro (confirmacion + Desmontar Hives de registro)
    $form.Add_FormClosing({
        if ($script:isOemApplying) {
            [System.Windows.Forms.MessageBox]::Show("Operacion en curso. Espera a que termine.", "Aviso", 'OK', 'Warning')
            $_.Cancel = $true
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Estas seguro de que deseas salir?",
            "Confirmar Salida",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)

        if ($confirm -eq 'No') {
            $_.Cancel = $true
            return
        }

        Write-Log -LogLevel INFO -Message "OEM_Branding: Cerrando. Desmontando Hives..."
        $lblStatus.Text = "Desmontando Hives..."
        $form.Refresh()
        try {
            Unmount-Hives
        } catch {
            Write-Log -LogLevel WARN -Message "OEM_Branding: Error al desmontar Hives: $($_.Exception.Message)"
        }
    })

    # ------------------------------------------------------------------
    # 4. Mostrar y limpiar
    # ------------------------------------------------------------------
    $form.ShowDialog() | Out-Null
    $form.Dispose()
    [GC]::Collect()
}