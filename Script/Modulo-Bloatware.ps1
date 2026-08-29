# =================================================================
#  Modulo-Bloatware
#
#  CONTENIDO   : Show-Bloatware-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - Mount-Hives            : montar colmenas offline del registro
#    - Unmount-Hives          : desmontar colmenas offline del registro
#    - Unlock-Single-Key      : tomar propiedad de una clave especifica
#    - $PSScriptRoot          : ruta base para localizar Catalogos\Bloatware.ps1
#  CARGA       : . "$PSScriptRoot\Modulo-Bloatware.ps1"
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

function Show-Bloatware-GUI {
    param()

    if ($Script:IMAGE_MOUNTED -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # ------------------------------------------------------------------
    # 2. Construccion del formulario
    # ------------------------------------------------------------------
    $form               = New-Object System.Windows.Forms.Form
    $form.Text          = "Gestor de Aplicaciones (Bloatware) - $Script:MOUNT_DIR"
    $form.Size          = New-Object System.Drawing.Size(800, 730)
    $form.StartPosition = "CenterScreen"
    $form.BackColor     = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor     = [System.Drawing.Color]::White

    $lblTitle          = New-Object System.Windows.Forms.Label
    $lblTitle.Text     = "Eliminacion de Apps Preinstaladas (Nivel Profundo)"
    $lblTitle.Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = "20, 15"
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    $lblSearch          = New-Object System.Windows.Forms.Label
    $lblSearch.Text     = "Buscar:"
    $lblSearch.Location = "20, 50"
    $lblSearch.AutoSize = $true
    $form.Controls.Add($lblSearch)

    $txtSearch          = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = "70, 48"
    $txtSearch.Size     = "400, 23"
    $form.Controls.Add($txtSearch)

    $chkShowSystem           = New-Object System.Windows.Forms.CheckBox
    $chkShowSystem.Text      = "Mostrar Apps del Sistema (Peligroso)"
    $chkShowSystem.Location  = "500, 48"
    $chkShowSystem.AutoSize  = $true
    $chkShowSystem.ForeColor = [System.Drawing.Color]::Salmon
    $form.Controls.Add($chkShowSystem)

    $lv               = New-Object System.Windows.Forms.ListView
    $lv.Location      = "20, 80"
    $lv.Size          = "740, 500"
    $lv.View          = "Details"
    $lv.CheckBoxes    = $true
    $lv.FullRowSelect = $true
    $lv.GridLines     = $true
    $lv.BackColor     = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $lv.ForeColor     = [System.Drawing.Color]::White
    $lv.Columns.Add("Aplicacion (Nombre)", 400) | Out-Null
    $lv.Columns.Add("Categoria",           150) | Out-Null
    $lv.Columns.Add("Package ID",          150) | Out-Null
    $form.Controls.Add($lv)

    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "Cargando catalogo..."
    $lblStatus.Location  = "20, 590"
    $lblStatus.AutoSize  = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    $progressBar          = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = "20, 613"
    $progressBar.Size     = "740, 12"
    $progressBar.Style    = "Continuous"
    $progressBar.Visible  = $false
    $form.Controls.Add($progressBar)

    $btnSelectRec           = New-Object System.Windows.Forms.Button
    $btnSelectRec.Text      = "Marcar Recomendados (Bloat)"
    $btnSelectRec.Location  = "20, 650"
    $btnSelectRec.Size      = "200, 30"
    $btnSelectRec.BackColor = [System.Drawing.Color]::Orange
    $btnSelectRec.ForeColor = [System.Drawing.Color]::Black
    $btnSelectRec.FlatStyle = "Flat"
    $form.Controls.Add($btnSelectRec)

    $btnRemove           = New-Object System.Windows.Forms.Button
    $btnRemove.Text      = "ELIMINAR SELECCIONADOS"
    $btnRemove.Location  = "500, 645"
    $btnRemove.Size      = "260, 40"
    $btnRemove.BackColor = [System.Drawing.Color]::Crimson
    $btnRemove.ForeColor = [System.Drawing.Color]::White
    $btnRemove.FlatStyle = "Flat"
    $btnRemove.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnRemove)

    # ------------------------------------------------------------------
    # 3. Estado compartido entre eventos
    # ------------------------------------------------------------------
    $script:cachedApps   = @()
    $script:safePattern  = ""
    $script:bloatPattern = ""

    # ------------------------------------------------------------------
    # 4. Helper: poblar ListView con filtro y toggle de sistema
    # ------------------------------------------------------------------
    $PopulateList = {
        $lv.BeginUpdate()
        $lv.Items.Clear()
        $filter  = $txtSearch.Text.Trim()
        $showSys = $chkShowSystem.Checked

        foreach ($app in $script:cachedApps) {
            $displayName = [string]$app.DisplayName
            $packageName = [string]$app.PackageName

            # Busqueda literal, no regex: evita errores con caracteres como [, (, *, ?
            # y permite buscar tambien por PackageName.
            if ($filter.Length -gt 0 -and
                $displayName.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
                $packageName.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                continue
            }

            $type  = "Normal"
            $color = [System.Drawing.Color]::White

            if ($script:safePattern -and
                ($packageName -match $script:safePattern -or
                 $displayName -match $script:safePattern)) {
                if (-not $showSys) { continue }
                $type  = "Sistema (Vital)"
                $color = [System.Drawing.Color]::LightGreen
            } elseif ($script:bloatPattern -and
                      ($packageName -match $script:bloatPattern -or
                       $displayName -match $script:bloatPattern)) {
                $type  = "Bloatware"
                $color = [System.Drawing.Color]::Orange
            }

            $item = New-Object System.Windows.Forms.ListViewItem($displayName)
            $item.SubItems.Add($type)        | Out-Null
            $item.SubItems.Add($packageName) | Out-Null
            $item.ForeColor = $color
            $item.Tag       = $packageName
            $lv.Items.Add($item) | Out-Null
        }
        $lv.EndUpdate()
        $lblStatus.Text = "Mostrando: $($lv.Items.Count) aplicaciones."
    }

    # 5. Eventos
    # Carga inicial: catalogo externo + cache DISM del WIM
    $form.Add_Shown({
        $form.Refresh()
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        $safeList  = @()
        $bloatList = @()
        $appsFile  = Join-Path $PSScriptRoot "Catalogos\Bloatware.ps1"
        if (-not (Test-Path $appsFile)) { $appsFile = Join-Path $PSScriptRoot "Bloatware.ps1" }

        if (Test-Path $appsFile) {
            . $appsFile
            if ($script:AppLists) {
                $safeList  = $script:AppLists.Safe
                $bloatList = $script:AppLists.Bloat
            }
        }

        # Guarda vacia cuando no hay catalogo para evitar que regex vacia matchee todo
        $script:safePattern = if ($safeList.Count -gt 0) {
            ($safeList | ForEach-Object { [regex]::Escape($_) }) -join "|"
        } else { "" }
        $script:bloatPattern = if ($bloatList.Count -gt 0) {
            ($bloatList | ForEach-Object { [regex]::Escape($_) }) -join "|"
        } else { "" }

        try {
            $script:cachedApps = Get-AppxProvisionedPackage -Path $Script:MOUNT_DIR | Sort-Object DisplayName
            & $PopulateList
        } catch {
            $lblStatus.Text = "Error: $_"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    $txtSearch.Add_TextChanged({ & $PopulateList })
    $chkShowSystem.Add_CheckedChanged({ & $PopulateList })

    $btnSelectRec.Add_Click({
        foreach ($item in $lv.Items) {
            $item.Checked = ($item.SubItems[1].Text -eq "Bloatware")
        }
    })

    # Motor de eliminacion principal
    $btnRemove.Add_Click({
        # Copia estatica: $lv.CheckedItems es una coleccion viva y cambia si se desmarca un item.
        $selectedApps = @(
            foreach ($item in @($lv.CheckedItems)) {
                [PSCustomObject]@{
                    Item        = $item
                    DisplayName = [string]$item.Text
                    Category    = [string]$item.SubItems[1].Text
                    PackageName = [string]$item.Tag
                    Removed     = $false
                    Error       = $null
                }
            }
        )

        if ($selectedApps.Count -eq 0) {
            Write-Log -LogLevel WARN -Message "AppxManager: Intento de ejecucion sin aplicaciones seleccionadas."
            return
        }

        $hasSystemApps = $selectedApps | Where-Object { $_.Category -eq "Sistema (Vital)" } | Select-Object -First 1

        # Advertencia reforzada cuando la seleccion incluye apps "Sistema (Vital)":
        # implica desbloqueo profundo del registro, no solo una desinstalacion normal.
        $confirmMsg = if ($hasSystemApps) {
            "Eliminar $($selectedApps.Count) apps permanentemente?`n`n" +
            "ATENCION: la seleccion incluye apps de 'Sistema (Vital)'. Se aplicara un " +
            "desbloqueo profundo del registro (bypass IsInbox) ademas de las vacunas Anti-Fantasmas.`n`n" +
            "Esto puede afectar componentes del sistema. Continua solo si sabes lo que haces."
        } else {
            "Eliminar $($selectedApps.Count) apps permanentemente?`n`nSe aplicaran las vacunas Anti-Fantasmas."
        }

        if ([System.Windows.Forms.MessageBox]::Show(
                $confirmMsg, "Confirmar", 'YesNo', 'Warning') -ne 'Yes') {
            Write-Log -LogLevel INFO -Message "AppxManager: El usuario cancelo la eliminacion en el cuadro de confirmacion."
            return
        }

        $btnRemove.Enabled = $false
        $form.Cursor       = [System.Windows.Forms.Cursors]::WaitCursor
        $errs    = 0
        $success = 0

        $inboxBase   = "OfflineSoftware\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications"
        $inboxPSPath = "HKLM:\$inboxBase"

        try {
        # ==============================================================
        # FASE 1: Bypass IsInbox (solo apps marcadas como Sistema Vital)
        # ==============================================================
        if ($hasSystemApps) {
            $lblStatus.Text = "Desbloqueando apps del sistema..."; $form.Refresh()

            if (Mount-Hives) {
                try {
                    foreach ($appInfo in $selectedApps) {
                        if ($appInfo.Category -ne "Sistema (Vital)") { continue }
                        $pkg = $appInfo.PackageName
                        if (Test-Path $inboxPSPath) {
                            foreach ($key in (Get-ChildItem -Path $inboxPSPath -ErrorAction SilentlyContinue)) {
                                # Igualdad exacta (case-insensitive) contra el PackageName tal cual lo
                                # devuelve Get-AppxProvisionedPackage (tilde incluido si aplica): la
                                # evidencia real en WindowsApps confirma que Windows preserva el "~"
                                # literal en esta convencion de nombres, no lo reemplaza.
                                if ($key.PSChildName -ieq $pkg) {
                                    $kPath = "$inboxBase\$($key.PSChildName)"
                                    Unlock-Single-Key -SubKeyPath $kPath
                                    Remove-Item -Path "HKLM:\$kPath" -Recurse -Force -ErrorAction SilentlyContinue
                                    Write-Log -LogLevel INFO -Message "AppxManager: Bypass IsInbox aplicado a -> $pkg"
                                }
                            }
                        }
                    }
                } finally {
                    # Garantiza el desmontaje aunque Unlock-Single-Key u otra operacion lance una excepcion.
                    Unmount-Hives
                }
            }
        } else {
            Write-Log -LogLevel INFO -Message "AppxManager: No se detectaron apps del sistema. Omitiendo Fase 1."
        }

        # ==============================================================
        # FASE 2: Eliminacion logica (DISM) + limpieza fisica
        # ==============================================================
        $windowsAppsPath = Join-Path $Script:MOUNT_DIR "Program Files\WindowsApps"

        $progressBar.Maximum = $selectedApps.Count
        $progressBar.Value   = 0
        $progressBar.Visible = $true

        foreach ($appInfo in $selectedApps) {
            $item = $appInfo.Item
            $pkg  = $appInfo.PackageName
            $item.EnsureVisible()
            $lblStatus.Text = "Purgando y limpiando disco: $($appInfo.DisplayName)..."; $form.Refresh()
            Write-Log -LogLevel INFO -Message "AppxManager: Intentando purgar paquete -> $pkg"

            try {
                Remove-AppxProvisionedPackage -Path $Script:MOUNT_DIR -PackageName $pkg -ErrorAction Stop | Out-Null

                # Limpieza fisica de residuos en Program Files\WindowsApps.
                # Ambito limitado SOLO a las carpetas de este paquete: nunca se tocan permisos
                # de apps que no se estan eliminando, y no hace falta restaurar nada despues
                # porque la carpeta termina borrada de todas formas.
                if (Test-Path $windowsAppsPath) {
                    if (-not [string]::IsNullOrWhiteSpace($pkg)) {
                        # Una app real en WindowsApps casi nunca es UNA sola carpeta: ademas del
                        # paquete "neutral" (que es el que coincide con PackageName, tilde incluido),
                        # suele haber una carpeta de arquitectura (x64/x86) con el contenido real y
                        # carpetas de recursos (idioma, escala). El match exacto contra $pkg solo
                        # encontraba el stub "neutral" y dejaba atras el contenido pesado.
                        # Se filtra por nombre base + version (ambos tomados de $pkg) para cubrir
                        # toda la familia de ESA version especifica, sin tocar otra app ni otra version.
                        $pkgParts = $pkg -split '_'
                        $appNameBase = $pkgParts[0]
                        $appVersion  = if ($pkgParts.Count -gt 1) { $pkgParts[1] } else { $null }

                        $folderFilter = if ($appVersion) { "$appNameBase`_$appVersion`_*" } else { "$appNameBase`_*" }

                        # -Force es obligatorio: las carpetas de paquetes en WindowsApps son
                        # Hidden+System por diseño de Windows y Get-ChildItem las omite sin -Force
                        # (Test-Path si las detecta, por eso el bloque llegaba hasta aqui sin fallar).
                        $residueFolders = @(Get-ChildItem -Path $windowsAppsPath -Directory -Force -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -like $folderFilter })

                        if ($residueFolders.Count -eq 0) {
                            Write-Log -LogLevel WARN -Message "AppxManager: No se encontro ninguna carpeta fisica en WindowsApps para [$pkg] (filtro [$folderFilter])."
                        }

                        foreach ($folder in $residueFolders) {
                            try {
                                Write-Log -LogLevel INFO -Message "AppxManager: Destruyendo residuos fisicos -> $($folder.FullName)"
                                # takeown + icacls encadenados en un solo proceso cmd.exe (en vez de
                                # dos Start-Process separados) para reducir el overhead de spawn,
                                # sin ampliar el alcance a carpetas que no se van a borrar.
                                # SID S-1-5-32-544 = Administrators/Administradores, independiente del idioma.
                                $cmdArgs = "/c takeown /F `"$($folder.FullName)`" /A /R /D Y >nul && " +
                                           "icacls `"$($folder.FullName)`" /grant *S-1-5-32-544:F /T /C /Q >nul"
                                Start-Process "cmd.exe" -ArgumentList $cmdArgs -Wait -WindowStyle Hidden | Out-Null
                                Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction Stop
                            } catch {
                                Write-Log -LogLevel WARN -Message "AppxManager: No se pudo eliminar residuo fisico [$($folder.FullName)] - $($_.Exception.Message)"
                            }
                        }
                    }
                }

                $appInfo.Removed = $true
                $item.ForeColor  = [System.Drawing.Color]::Gray
                if ($item.Text -notmatch "\(ELIMINADO\)$") { $item.Text += " (ELIMINADO)" }
                $item.Checked    = $false
                $success++
                Write-Log -LogLevel INFO -Message "AppxManager: Paquete y archivos fisicos destruidos con exito."
            } catch {
                $errs++
                $appInfo.Error  = $_.Exception.Message
                $item.ForeColor = [System.Drawing.Color]::Red
                Write-Log -LogLevel ERROR -Message "AppxManager: Falla al eliminar paquete [$pkg] - $($_.Exception.Message)"
            } finally {
                $progressBar.Value = [Math]::Min($progressBar.Value + 1, $progressBar.Maximum)
            }
        }

        # ==============================================================
        # FASE 2.5: Clean Room del Menu de Inicio (estrategia de reemplazo)
        # ==============================================================
        $lblStatus.Text = "Inyectando Menu de Inicio Minimalista..."; $form.Refresh()
        Write-Log -LogLevel ACTION -Message "StartMenu: Inyectando plantillas minimalistas W10/W11."

        try {
            $shellPath = Join-Path $Script:MOUNT_DIR "Users\Default\AppData\Local\Microsoft\Windows\Shell"
            if (-not (Test-Path $shellPath)) { New-Item -Path $shellPath -ItemType Directory -Force | Out-Null }

            # Respaldar y neutralizar la plantilla base de Microsoft si existe
            $defaultLayoutPath = Join-Path $shellPath "DefaultLayouts.xml"
            if (Test-Path $defaultLayoutPath) {
                Rename-Item -Path $defaultLayoutPath -NewName "DefaultLayouts.xml.bak" -Force -ErrorAction SilentlyContinue
            }

            # Plantilla W10 (XML): panel derecho colapsado, sin tiles
            $xmlContent = @"
<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" Version="1">
  <LayoutOptions StartTileGroupCellWidth="6" />
  <DefaultLayoutOverride>
    <StartLayoutCollection>
      <defaultlayout:StartLayout GroupCellWidth="6" />
    </StartLayoutCollection>
  </DefaultLayoutOverride>
</LayoutModificationTemplate>
"@
            [System.IO.File]::WriteAllText((Join-Path $shellPath "LayoutModification.xml"), $xmlContent, [System.Text.Encoding]::UTF8)

            # Plantilla W11 (JSON): solo Edge y Configuracion como pines
            $jsonContent = @"
{
  "primaryOEMPins": [
    { "desktopAppLink": "%ALLUSERSPROFILE%\\Microsoft\\Windows\\Start Menu\\Programs\\Microsoft Edge.lnk" },
    { "packagedAppId": "windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel" }
  ],
  "secondaryOEMPins": [],
  "firstRunOEMPins": [],
  "pinnedList": [
    { "desktopAppLink": "%ALLUSERSPROFILE%\\Microsoft\\Windows\\Start Menu\\Programs\\Microsoft Edge.lnk" },
    { "packagedAppId": "windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel" }
  ]
}
"@
            [System.IO.File]::WriteAllText((Join-Path $shellPath "LayoutModification.json"), $jsonContent, [System.Text.Encoding]::UTF8)

            Write-Log -LogLevel INFO -Message "StartMenu: Plantillas minimalistas inyectadas con exito."
        } catch {
            Write-Log -LogLevel WARN -Message "StartMenu: Falla al inyectar plantillas - $($_.Exception.Message)"
        }

        # ==============================================================
        # FASE 3: Vacunas anti-reinstalacion + GPOs de interfaz
        # Cubre W10 22H2, W11 22H2/23H2/24H2+ y edicion Home
        # ==============================================================
        $lblStatus.Text = "Aplicando vacunas y puliendo interfaz..."; $form.Refresh()

        if (Mount-Hives) {
          try {
            # 3.0 Marcar paquetes eliminados como Deprovisioned.
            # La clave se crea si no existe; no dependemos de que venga precreada en la imagen.
            try {
                $deprovPath = "HKLM:\OfflineSoftware\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned"
                if (-not (Test-Path $deprovPath)) { New-Item -Path $deprovPath -Force | Out-Null }

                foreach ($appInfo in ($selectedApps | Where-Object { $_.Removed })) {
                    $null = New-Item -Path (Join-Path $deprovPath $appInfo.PackageName) -Force -ErrorAction Stop
                    Write-Log -LogLevel INFO -Message "AppxManager: Marcado como Deprovisioned -> $($appInfo.PackageName)"
                }
            } catch {
                Write-Log -LogLevel WARN -Message "AppxManager: Fallo al marcar paquetes Deprovisioned - $($_.Exception.Message)"
            }

            # ── Vacuna A: ContentDeliveryManager — NTUSER.DAT (nivel usuario) ──
            # Separada de las GPOs de maquina para que Boot/WinPE no bloquee el resto.
            try {
                if (Test-Path "HKLM:\OfflineUser") {
                    $cdmPath = "HKLM:\OfflineUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
                    if (-not (Test-Path $cdmPath)) { New-Item -Path $cdmPath -Force | Out-Null }

                    Set-ItemProperty -Path $cdmPath -Name "OemPreInstalledAppsEnabled"  -Value 0 -Type DWord -Force
                    Set-ItemProperty -Path $cdmPath -Name "PreInstalledAppsEnabled"     -Value 0 -Type DWord -Force
                    Set-ItemProperty -Path $cdmPath -Name "SilentInstalledAppsEnabled"  -Value 0 -Type DWord -Force
                    Set-ItemProperty -Path $cdmPath -Name "ContentDeliveryAllowed"      -Value 0 -Type DWord -Force
                    Set-ItemProperty -Path $cdmPath -Name "PreInstalledAppsEverEnabled" -Value 1 -Type DWord -Force

                    # SubscribedContent: cierra brecha de Spotlight y sugerencias dinamicas.
                    @(
                        "SubscribedContentEnabled",
                        "SubscribedContent-338380Enabled",
                        "SubscribedContent-338388Enabled",
                        "SubscribedContent-338389Enabled",
                        "SubscribedContent-353694Enabled",
                        "SubscribedContent-353696Enabled",
                        "SystemPaneSuggestionsEnabled",
                        "ShowSyncProviderNotifications"
                    ) | ForEach-Object { Set-ItemProperty -Path $cdmPath -Name $_ -Value 0 -Type DWord -Force }

                    Write-Log -LogLevel INFO -Message "AppxManager: Vacunas de usuario aplicadas en OfflineUser."
                } else {
                    Write-Log -LogLevel WARN -Message "AppxManager: OfflineUser no esta montado. Omitiendo vacunas de usuario CDM."
                }
            } catch {
                Write-Log -LogLevel WARN -Message "AppxManager: Fallo parcial en vacunas de usuario CDM - $($_.Exception.Message)"
            }

            # ── Vacunas/GPOs de maquina — SOFTWARE\Policies ──
            try {
                $gpoPath = "HKLM:\OfflineSoftware\Policies\Microsoft\Windows\CloudContent"
                if (-not (Test-Path $gpoPath)) { New-Item -Path $gpoPath -Force | Out-Null }

                # Escritura directa del valor de politica (en vez de via gpedit.msc): esto ya
                # cubre tambien ediciones Home, donde el editor de GPO no esta disponible pero
                # el registro subyacente si se respeta.
                Set-ItemProperty -Path $gpoPath -Name "DisableWindowsConsumerFeatures"               -Value 1 -Type DWord -Force
                Set-ItemProperty -Path $gpoPath -Name "DisableThirdPartySuggestions"                 -Value 1 -Type DWord -Force
                Set-ItemProperty -Path $gpoPath -Name "DisableTailoredExperiencesWithDiagnosticData" -Value 1 -Type DWord -Force
                Set-ItemProperty -Path $gpoPath -Name "DisableConsumerAccountStateContent"           -Value 1 -Type DWord -Force
                Set-ItemProperty -Path $gpoPath -Name "DisableCloudOptimizedContent"                 -Value 1 -Type DWord -Force

                # GPOs de barra lateral del Explorador (W10).
                $explorerGpoPath = "HKLM:\OfflineSoftware\Policies\Microsoft\Windows\Explorer"
                if (-not (Test-Path $explorerGpoPath)) { New-Item -Path $explorerGpoPath -Force | Out-Null }

                Set-ItemProperty -Path $explorerGpoPath -Name "HideDocumentsGroup"  -Value 1 -Type DWord -Force
                Set-ItemProperty -Path $explorerGpoPath -Name "HidePicturesGroup"   -Value 1 -Type DWord -Force
                Set-ItemProperty -Path $explorerGpoPath -Name "HideMusicGroup"      -Value 1 -Type DWord -Force
                Set-ItemProperty -Path $explorerGpoPath -Name "HideDownloadsGroup"  -Value 1 -Type DWord -Force
                Set-ItemProperty -Path $explorerGpoPath -Name "HideVideosGroup"     -Value 1 -Type DWord -Force

                Write-Log -LogLevel INFO -Message "AppxManager: GPOs de maquina aplicadas (CloudContent + W11-24H2 + Home + Explorer sidebar)."
            } catch {
                Write-Log -LogLevel WARN -Message "AppxManager: Fallo parcial en GPOs de maquina - $($_.Exception.Message)"
            }

          } finally {
            # Garantiza el desmontaje aunque algo inesperado falle fuera de los try/catch internos.
            $lblStatus.Text = "Guardando registro..."; $form.Refresh()
            Unmount-Hives
          }
        }

        } catch {
            $errs++
            Write-Log -LogLevel ERROR -Message "AppxManager: Error inesperado durante el proceso de limpieza - $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show(
                "Ocurrio un error inesperado durante el proceso:`n`n$($_.Exception.Message)`n`nRevisa el log para mas detalle.",
                "Error", 'OK', 'Error') | Out-Null
        } finally {
            # ==============================================================
            # Finalizacion y refresco del catalogo visual (siempre se ejecuta)
            # ==============================================================
            $progressBar.Visible = $false
            $btnRemove.Enabled   = $true
            $form.Cursor         = [System.Windows.Forms.Cursors]::Default
            $lblStatus.Text      = "Listo. Exitos: $success | Errores: $errs"

            Write-Log -LogLevel ACTION -Message "AppxManager: Proceso de limpieza finalizado. Exitos: $success | Errores: $errs"

            if ($errs -gt 0) {
                $failedDetail = ($selectedApps | Where-Object { -not $_.Removed -and $_.Error } |
                    ForEach-Object { " - $($_.DisplayName): $($_.Error)" }) -join "`n"
                if ($failedDetail) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Se completaron $success eliminaciones, pero $errs fallaron:`n`n$failedDetail",
                        "Errores durante la limpieza", 'OK', 'Warning') | Out-Null
                }
            }

            try {
                $script:cachedApps = Get-AppxProvisionedPackage -Path $Script:MOUNT_DIR | Sort-Object DisplayName
                & $PopulateList
            } catch {
                Write-Log -LogLevel WARN -Message "AppxManager: Fallo al refrescar el catalogo tras la limpieza - $($_.Exception.Message)"
            }
        }
    })

    $form.Add_FormClosing({ 
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Estas seguro de que deseas salir del Gestor de Bloatware?", 
            "Confirmar Salida", 
            [System.Windows.Forms.MessageBoxButtons]::YesNo, 
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq 'No') {
            $_.Cancel = $true
        } else { 
        }
    })

    $form.ShowDialog() | Out-Null
    if ($null -ne $lv) { $lv.Dispose() }
    $form.Dispose()
    [GC]::Collect()
    $script:cachedApps = $null
    [GC]::WaitForPendingFinalizers()
}