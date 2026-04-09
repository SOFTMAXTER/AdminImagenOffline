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
    # 2. Construccion del formulario
    # ------------------------------------------------------------------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "OEM Branding - Personalizacion"
    $form.Size            = New-Object System.Drawing.Size(600, 550)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    $lblTitle          = New-Object System.Windows.Forms.Label
    $lblTitle.Text     = "Inyeccion de Branding y Propiedades del Sistema"
    $lblTitle.Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = "20, 15"
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    $lblOsInfo           = New-Object System.Windows.Forms.Label
    $lblOsInfo.Text      = "Analizando imagen..."
    $lblOsInfo.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblOsInfo.ForeColor = [System.Drawing.Color]::LightGreen
    $lblOsInfo.Location  = "20, 40"
    $lblOsInfo.AutoSize  = $true
    $form.Controls.Add($lblOsInfo)

    # ------------------------------------------------------------------
    # Grupo 1: Imagenes y Tema
    # ------------------------------------------------------------------
    $grpImages           = New-Object System.Windows.Forms.GroupBox
    $grpImages.Text      = " Politicas de Imagen y Tema "
    $grpImages.Location  = "20, 60"
    $grpImages.Size      = "550, 185"
    $grpImages.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($grpImages)

    $lblWall           = New-Object System.Windows.Forms.Label
    $lblWall.Text      = "Fondo de Escritorio (JPG/PNG):"
    $lblWall.Location  = "15, 28"
    $lblWall.AutoSize  = $true
    $lblWall.ForeColor = [System.Drawing.Color]::White
    $grpImages.Controls.Add($lblWall)

    $txtWall           = New-Object System.Windows.Forms.TextBox
    $txtWall.Location  = "15, 48"
    $txtWall.Size      = "430, 23"
    $txtWall.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtWall.ForeColor = [System.Drawing.Color]::White
    $txtWall.ReadOnly  = $true
    $grpImages.Controls.Add($txtWall)

    $btnWall           = New-Object System.Windows.Forms.Button
    $btnWall.Text      = "Examinar..."
    $btnWall.Location  = "455, 46"
    $btnWall.Size      = "80, 26"
    $btnWall.BackColor = [System.Drawing.Color]::Gray
    $btnWall.FlatStyle = "Flat"
    $grpImages.Controls.Add($btnWall)

    $lblLock           = New-Object System.Windows.Forms.Label
    $lblLock.Text      = "Pantalla de Bloqueo (JPG/PNG):"
    $lblLock.Location  = "15, 82"
    $lblLock.AutoSize  = $true
    $lblLock.ForeColor = [System.Drawing.Color]::White
    $grpImages.Controls.Add($lblLock)

    $txtLock           = New-Object System.Windows.Forms.TextBox
    $txtLock.Location  = "15, 100"
    $txtLock.Size      = "430, 23"
    $txtLock.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtLock.ForeColor = [System.Drawing.Color]::White
    $txtLock.ReadOnly  = $true
    $grpImages.Controls.Add($txtLock)

    $btnLock           = New-Object System.Windows.Forms.Button
    $btnLock.Text      = "Examinar..."
    $btnLock.Location  = "455, 98"
    $btnLock.Size      = "80, 26"
    $btnLock.BackColor = [System.Drawing.Color]::Gray
    $btnLock.FlatStyle = "Flat"
    $grpImages.Controls.Add($btnLock)

    $lblTheme          = New-Object System.Windows.Forms.Label
    $lblTheme.Text     = "Tema:"
    $lblTheme.Location = "15, 140"
    $lblTheme.AutoSize = $true
    $lblTheme.ForeColor = [System.Drawing.Color]::White
    $grpImages.Controls.Add($lblTheme)

    $radThemeNone          = New-Object System.Windows.Forms.RadioButton
    $radThemeNone.Text     = "No alterar"
    $radThemeNone.Location = "120, 138"
    $radThemeNone.AutoSize = $true
    $radThemeNone.Checked  = $true
    $grpImages.Controls.Add($radThemeNone)

    $radThemeDark          = New-Object System.Windows.Forms.RadioButton
    $radThemeDark.Text     = "Oscuro"
    $radThemeDark.Location = "220, 138"
    $radThemeDark.AutoSize = $true
    $grpImages.Controls.Add($radThemeDark)

    $radThemeLight          = New-Object System.Windows.Forms.RadioButton
    $radThemeLight.Text     = "Claro"
    $radThemeLight.Location = "310, 138"
    $radThemeLight.AutoSize = $true
    $grpImages.Controls.Add($radThemeLight)

    # ------------------------------------------------------------------
    # Grupo 2: Informacion OEM
    # ------------------------------------------------------------------
    $grpOem           = New-Object System.Windows.Forms.GroupBox
    $grpOem.Text      = " Informacion del Ensamblador (OEM) "
    $grpOem.Location  = "20, 255"
    $grpOem.Size      = "550, 150"
    $grpOem.ForeColor = [System.Drawing.Color]::Orange
    $form.Controls.Add($grpOem)

    $lblFab           = New-Object System.Windows.Forms.Label
    $lblFab.Text      = "Fabricante:"
    $lblFab.Location  = "15, 30"
    $lblFab.AutoSize  = $true
    $lblFab.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblFab)

    $txtFab           = New-Object System.Windows.Forms.TextBox
    $txtFab.Location  = "90, 27"
    $txtFab.Size      = "160, 23"
    $txtFab.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtFab.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($txtFab)

    $lblMod           = New-Object System.Windows.Forms.Label
    $lblMod.Text      = "Modelo:"
    $lblMod.Location  = "270, 30"
    $lblMod.AutoSize  = $true
    $lblMod.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblMod)

    $txtMod           = New-Object System.Windows.Forms.TextBox
    $txtMod.Location  = "330, 27"
    $txtMod.Size      = "200, 23"
    $txtMod.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtMod.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($txtMod)

    $lblUrl           = New-Object System.Windows.Forms.Label
    $lblUrl.Text      = "URL Web:"
    $lblUrl.Location  = "15, 68"
    $lblUrl.AutoSize  = $true
    $lblUrl.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblUrl)

    $txtUrl           = New-Object System.Windows.Forms.TextBox
    $txtUrl.Location  = "90, 65"
    $txtUrl.Size      = "440, 23"
    $txtUrl.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtUrl.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($txtUrl)

    $lblPhone           = New-Object System.Windows.Forms.Label
    $lblPhone.Text      = "Telefono:"
    $lblPhone.Location  = "15, 108"
    $lblPhone.AutoSize  = $true
    $lblPhone.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblPhone)

    $txtPhone           = New-Object System.Windows.Forms.TextBox
    $txtPhone.Location  = "90, 105"
    $txtPhone.Size      = "160, 23"
    $txtPhone.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtPhone.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($txtPhone)

    $lblHours           = New-Object System.Windows.Forms.Label
    $lblHours.Text      = "Horario:"
    $lblHours.Location  = "270, 108"
    $lblHours.AutoSize  = $true
    $lblHours.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblHours)

    $txtHours           = New-Object System.Windows.Forms.TextBox
    $txtHours.Location  = "330, 105"
    $txtHours.Size      = "200, 23"
    $txtHours.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtHours.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($txtHours)

    # ------------------------------------------------------------------
    # Barra de estado y boton aplicar
    # ------------------------------------------------------------------
    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "Listo."
    $lblStatus.Location  = "20, 420"
    $lblStatus.Size      = "550, 18"
    $lblStatus.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($lblStatus)

    $btnApply           = New-Object System.Windows.Forms.Button
    $btnApply.Text      = "APLICAR BRANDING A LA IMAGEN"
    $btnApply.Location  = "100, 443"
    $btnApply.Size      = "380, 45"
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
        Write-Log -LogLevel INFO -Message "OEM_Branding: Precargando datos existentes y analizando imagen..."

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

            $lblOsInfo.Text = "Detectado: $osName | Edicion: $edition | Build: $build"
            Write-Log -LogLevel INFO -Message "OEM_Branding: $osName | $edition | Build $build"
        }

        # Precargar OEMInformation existente
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

    # Selectores de imagen
    $btnWall.Add_Click({
        $ofd        = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Imagenes (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png"
        if ($ofd.ShowDialog() -eq 'OK') { $txtWall.Text = $ofd.FileName }
    })

    $btnLock.Add_Click({
        $ofd        = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Imagenes (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png"
        if ($ofd.ShowDialog() -eq 'OK') { $txtLock.Text = $ofd.FileName }
    })

    # Motor de aplicacion principal
    $btnApply.Add_Click({

        # Validacion: al menos un campo debe tener valor
        if (-not $txtWall.Text  -and -not $txtLock.Text  -and $radThemeNone.Checked -and
            -not $txtFab.Text   -and -not $txtMod.Text   -and -not $txtUrl.Text -and
            -not $txtPhone.Text -and -not $txtHours.Text) {
            [System.Windows.Forms.MessageBox]::Show(
                "Selecciona al menos un fondo, un tema o datos OEM.",
                "Aviso", 'OK', 'Warning')
            return
        }

        $script:isOemApplying    = $true
        $form.Cursor             = [System.Windows.Forms.Cursors]::WaitCursor
        $btnApply.Enabled        = $false
        $lblStatus.Text          = "Analizando imagen..."
        $lblStatus.ForeColor     = [System.Drawing.Color]::Yellow
        $form.Refresh()

        Write-Log -LogLevel ACTION -Message "OEM_Branding: Iniciando motor de inyeccion."

        try {
            # Leer datos del OS desde el registro offline
            $editionId   = "Desconocida"
            $buildNumber = 0

            $verData = Get-ItemProperty `
                -Path "HKLM:\OfflineSoftware\Microsoft\Windows NT\CurrentVersion" `
                -ErrorAction SilentlyContinue

            if ($verData) {
                if ($null -ne $verData.EditionID)          { $editionId   = $verData.EditionID }
                if ($null -ne $verData.CurrentBuildNumber) { $buildNumber = [int]$verData.CurrentBuildNumber }
            }

            $isW11       = $buildNumber -ge 22000
            $isW11_22H2p = $buildNumber -ge 22621
            $isW11_24H2p = $buildNumber -ge 26100
            $isEnterprise = $editionId -match "Enterprise|Education|Server"
            $isPro        = $editionId -match "^Pro"
            $hasCSP       = $buildNumber -ge 15063
            $gpoLockOk    = $isEnterprise -or ($isPro -and $isW11_22H2p)

            $osLabel = if     ($isW11_24H2p) { "W11 24H2+" }
                       elseif ($isW11_22H2p) { "W11 22H2/23H2" }
                       elseif ($isW11)       { "W11 21H2" }
                       else                  { "W10 22H2" }

            Write-Log -LogLevel INFO -Message "OEM_Branding: OS=$osLabel | Ed=$editionId | Build=$buildNumber | CSP=$hasCSP | GPO-Lock=$gpoLockOk"

            $lblStatus.Text = "Aplicando para $osLabel ($editionId)..."
            $form.Refresh()

            Enable-Privileges

            # Directorio OEM para archivos de fondo
            $oemDir = Join-Path $Script:MOUNT_DIR "Windows\Web\Wallpaper\OEM"
            if (-not (Test-Path $oemDir)) {
                New-Item -Path $oemDir -ItemType Directory -Force | Out-Null
            }

            # Helper local: escritura atomica en clave de registro offline
            # Toma propiedad, escribe todos los valores, restaura propietario.
            function Set-OfflineKey {
                param(
                    [string]$SubPath,
                    [hashtable]$Values
                )
                $psPath = "HKLM:\$SubPath"
                Unlock-OfflineKey -KeyPath $psPath
                try {
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

            # ── Bloque 1: Fondo de escritorio ─────────────────────────
            if ($txtWall.Text -and (Test-Path $txtWall.Text)) {
                $lblStatus.Text = "Inyectando fondo de escritorio..."
                $form.Refresh()

                $wallExt      = [System.IO.Path]::GetExtension($txtWall.Text)
                $wallName     = "Fondo_OEM$wallExt"
                $wallInternal = "C:\Windows\Web\Wallpaper\OEM\$wallName"

                Copy-Item -Path $txtWall.Text `
                          -Destination (Join-Path $oemDir $wallName) `
                          -Force -ErrorAction Stop

                # Metodo A: PersonalizationCSP — universal (Home, Pro, Enterprise, W10+)
                if ($hasCSP) {
                    Set-OfflineKey `
                        -SubPath "OfflineSoftware\Microsoft\Windows\CurrentVersion\PersonalizationCSP" `
                        -Values @{
                            "DesktopImagePath"   = @{ Value = $wallInternal; Type = "String" }
                            "DesktopImageUrl"    = @{ Value = $wallInternal; Type = "String" }
                            "DesktopImageStatus" = @{ Value = 1;             Type = "DWord"  }
                        }
                    Write-Log -LogLevel INFO -Message "OEM_Branding: Wallpaper -> PersonalizationCSP OK"
                }

                # Metodo B: Perfil de usuario predeterminado (seed para nuevos perfiles)
                Set-OfflineKey `
                    -SubPath "OfflineUser\Control Panel\Desktop" `
                    -Values @{
                        "Wallpaper"      = @{ Value = $wallInternal; Type = "String" }
                        "WallpaperStyle" = @{ Value = "10";          Type = "String" }
                        "TileWallpaper"  = @{ Value = "0";           Type = "String" }
                    }
                Write-Log -LogLevel INFO -Message "OEM_Branding: Wallpaper -> Perfil Default OK"

                # Metodo C: GPO — solo Enterprise/Education/Server
                if ($isEnterprise) {
                    Set-OfflineKey `
                        -SubPath "OfflineSoftware\Policies\Microsoft\Windows\Personalization" `
                        -Values @{
                            "DesktopWallpaper" = @{ Value = $wallInternal; Type = "String" }
                        }
                    Write-Log -LogLevel INFO -Message "OEM_Branding: Wallpaper -> GPO Policy OK (Enterprise)"
                }
            }

            # ── Bloque 2: Pantalla de bloqueo ─────────────────────────
            if ($txtLock.Text -and (Test-Path $txtLock.Text)) {
                $lblStatus.Text = "Inyectando pantalla de bloqueo..."
                $form.Refresh()

                $lockExt      = [System.IO.Path]::GetExtension($txtLock.Text)
                $lockName     = "Lock_OEM$lockExt"
                $lockInternal = "C:\Windows\Web\Wallpaper\OEM\$lockName"

                Copy-Item -Path $txtLock.Text `
                          -Destination (Join-Path $oemDir $lockName) `
                          -Force -ErrorAction Stop

                # Metodo A: PersonalizationCSP — unico confiable para Home/Pro W10 22H2
                if ($hasCSP) {
                    Set-OfflineKey `
                        -SubPath "OfflineSoftware\Microsoft\Windows\CurrentVersion\PersonalizationCSP" `
                        -Values @{
                            "LockScreenImagePath"   = @{ Value = $lockInternal; Type = "String" }
                            "LockScreenImageUrl"    = @{ Value = $lockInternal; Type = "String" }
                            "LockScreenImageStatus" = @{ Value = 1;             Type = "DWord"  }
                        }
                    Write-Log -LogLevel INFO -Message "OEM_Branding: Lock Screen -> PersonalizationCSP OK"
                }

                # Metodo B: GPO — Enterprise/Education/Server en W10+, Pro en W11 22H2+
                if ($gpoLockOk) {
                    Set-OfflineKey `
                        -SubPath "OfflineSoftware\Policies\Microsoft\Windows\Personalization" `
                        -Values @{
                            "LockScreenImage" = @{ Value = $lockInternal; Type = "String" }
                        }
                    Write-Log -LogLevel INFO -Message "OEM_Branding: Lock Screen -> GPO Policy OK (ed=$editionId)"
                }
            }

            # ── Bloque 3: Tema visual ──────────────────────────────────
            if (-not $radThemeNone.Checked) {
                $lblStatus.Text = "Configurando tema visual..."
                $form.Refresh()

                $themeVal   = if ($radThemeDark.Checked) { 0 } else { 1 }
                $themeLabel = if ($radThemeDark.Checked) { "Oscuro" } else { "Claro" }

                $themeValues = @{
                    "AppsUseLightTheme"    = @{ Value = $themeVal; Type = "DWord" }
                    "SystemUsesLightTheme" = @{ Value = $themeVal; Type = "DWord" }
                    "EnableTransparency"   = @{ Value = 1;         Type = "DWord" }
                    "ColorPrevalence"      = @{ Value = 0;         Type = "DWord" }
                }

                # A: Perfil Default → seed para nuevos usuarios
                Set-OfflineKey `
                    -SubPath "OfflineUser\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" `
                    -Values $themeValues

                # B: HKLM SOFTWARE → logon screen y OOBE pre-usuario
                Set-OfflineKey `
                    -SubPath "OfflineSoftware\Microsoft\Windows\CurrentVersion\Themes\Personalize" `
                    -Values $themeValues

                # C: Script RunOnce que aplica el tema al primer login y
                #    emite WM_SETTINGCHANGE "ImmersiveColorSet" para activarlo en vivo
                $setupScriptsDir = Join-Path $Script:MOUNT_DIR "Windows\Setup\Scripts"
                if (-not (Test-Path $setupScriptsDir)) {
                    New-Item -Path $setupScriptsDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                $themeScriptPath = Join-Path $setupScriptsDir "OEMApplyTheme.ps1"

                $themeScriptContent = @"
`$tp = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
if (-not (Test-Path `$tp)) { New-Item -Path `$tp -Force | Out-Null }
Set-ItemProperty -Path `$tp -Name 'AppsUseLightTheme'    -Value $themeVal -Type DWord -Force
Set-ItemProperty -Path `$tp -Name 'SystemUsesLightTheme' -Value $themeVal -Type DWord -Force
Set-ItemProperty -Path `$tp -Name 'EnableTransparency'   -Value 1         -Type DWord -Force
Set-ItemProperty -Path `$tp -Name 'ColorPrevalence'      -Value 0         -Type DWord -Force

if (-not ([System.Management.Automation.PSTypeName]'Win32.OEMBroadcast').Type) {
    `$sig = '[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
    Add-Type -MemberDefinition `$sig -Name 'OEMBroadcast' -Namespace 'Win32' -PassThru | Out-Null
}
`$r = [UIntPtr]::Zero
[Win32.OEMBroadcast]::SendMessageTimeout(
    [IntPtr]0xFFFF,
    0x001A,
    [UIntPtr]::Zero,
    'ImmersiveColorSet',
    2,
    5000,
    [ref]`$r
) | Out-Null
"@
                [System.IO.File]::WriteAllText(
                    $themeScriptPath,
                    $themeScriptContent,
                    [System.Text.Encoding]::UTF8
                )
                Write-Log -LogLevel INFO -Message "OEM_Branding: Script OEMApplyTheme.ps1 escrito en Windows\Setup\Scripts"

                Set-OfflineKey `
                    -SubPath "OfflineUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" `
                    -Values @{
                        "!OEMApplyTheme" = @{
                            Value = 'powershell.exe -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\OEMApplyTheme.ps1"'
                            Type  = "String"
                        }
                    }

                Write-Log -LogLevel INFO -Message "OEM_Branding: Tema $themeLabel -> Default Profile + HKLM + RunOnce PS1 (WM_SETTINGCHANGE)"
            }

            # ── Bloque 4: Metadatos OEM ────────────────────────────────
            if ($txtFab.Text -or $txtMod.Text -or $txtPhone.Text -or
                $txtHours.Text -or $txtUrl.Text) {

                $lblStatus.Text = "Escribiendo metadatos OEM..."
                $form.Refresh()

                $oemValues = @{}
                if ($txtFab.Text)   { $oemValues["Manufacturer"] = @{ Value = $txtFab.Text;   Type = "String" } }
                if ($txtMod.Text)   { $oemValues["Model"]        = @{ Value = $txtMod.Text;   Type = "String" } }
                if ($txtUrl.Text)   { $oemValues["SupportURL"]   = @{ Value = $txtUrl.Text;   Type = "String" } }
                if ($txtPhone.Text) { $oemValues["SupportPhone"] = @{ Value = $txtPhone.Text; Type = "String" } }
                if ($txtHours.Text) { $oemValues["SupportHours"] = @{ Value = $txtHours.Text; Type = "String" } }

                Set-OfflineKey `
                    -SubPath "OfflineSoftware\Microsoft\Windows\CurrentVersion\OEMInformation" `
                    -Values $oemValues

                Write-Log -LogLevel INFO -Message "OEM_Branding: Metadatos OEM escritos correctamente."
            }

            # Resumen de metodos aplicados
            $methodsUsed = @()
            if ($hasCSP)                    { $methodsUsed += "PersonalizationCSP" }
            if ($gpoLockOk)                 { $methodsUsed += "GPO Lock Screen" }
            if ($isEnterprise)              { $methodsUsed += "GPO Wallpaper" }
            $methodsUsed += "Perfil Predeterminado"
            if (-not $radThemeNone.Checked) { $methodsUsed += "RunOnce Post-OOBE (Tema + WM_SETTINGCHANGE)" }

            $msg  = "Branding aplicado correctamente.`n`n"
            $msg += "OS: $osLabel | Edicion: $editionId`n"
            $msg += "Metodos usados:`n  - $($methodsUsed -join "`n  - ")"

            Write-Log -LogLevel ACTION -Message "OEM_Branding: Proceso completado. $($methodsUsed -join ' | ')"

            $lblStatus.Text      = "Completado."
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

    # Cierre seguro — bloquear si hay operacion en curso, desmontar hives al salir
    $form.Add_FormClosing({
        if ($script:isOemApplying) {
            [System.Windows.Forms.MessageBox]::Show(
                "Operacion en curso. Espera a que termine.",
                "Aviso", 'OK', 'Warning')
            $_.Cancel = $true
            return
        }
        Write-Log -LogLevel INFO -Message "OEM_Branding: Cerrando. Desmontando Hives..."
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