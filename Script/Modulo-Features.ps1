# =================================================================
#  Modulo-Features
#
#  CONTENIDO   : Show-Features-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - $Script:Scratch_DIR    : directorio temporal para staging NetFx3
#  CARGA       : . "$PSScriptRoot\Modulo-Features.ps1"
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

function Show-Features-GUI {
    param()

    # ------------------------------------------------------------------
    # 1. Validacion de imagen montada
    # ------------------------------------------------------------------
    if ($Script:IMAGE_MOUNTED -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # ------------------------------------------------------------------
    # 2. Construccion del formulario
    # ------------------------------------------------------------------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "Caracteristicas de Windows (Features) - $Script:MOUNT_DIR"
    $form.Size            = New-Object System.Drawing.Size(900, 700)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    # Tooltip para descripciones largas de cada feature
    $toolTip              = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 10000
    $toolTip.InitialDelay = 500
    $toolTip.ReshowDelay  = 500

    $lblTitle          = New-Object System.Windows.Forms.Label
    $lblTitle.Text     = "Gestor de Caracteristicas"
    $lblTitle.Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = "20, 10"
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # Barra de busqueda
    $lblSearch          = New-Object System.Windows.Forms.Label
    $lblSearch.Text     = "Buscar:"
    $lblSearch.Location = "20, 45"
    $lblSearch.AutoSize = $true
    $form.Controls.Add($lblSearch)

    $txtSearch           = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location  = "70, 42"
    $txtSearch.Size      = "600, 23"
    $txtSearch.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtSearch.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($txtSearch)

    # ListView principal
    $lv                  = New-Object System.Windows.Forms.ListView
    $lv.Location         = "20, 80"
    $lv.Size             = "840, 480"
    $lv.View             = "Details"
    $lv.CheckBoxes       = $true
    $lv.FullRowSelect    = $true
    $lv.GridLines        = $true
    $lv.BackColor        = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $lv.ForeColor        = [System.Drawing.Color]::White
    $lv.ShowItemToolTips = $true
    $lv.Columns.Add("Caracteristica",  350) | Out-Null
    $lv.Columns.Add("Estado",          150) | Out-Null
    $lv.Columns.Add("Nombre Interno",  300) | Out-Null
    $form.Controls.Add($lv)

    # Etiqueta de estado
    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "Cargando datos... (La interfaz puede congelarse unos segundos)"
    $lblStatus.Location  = "20, 570"
    $lblStatus.AutoSize  = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    # Boton .NET 3.5 SXS
    $btnNetFx3           = New-Object System.Windows.Forms.Button
    $btnNetFx3.Text      = "INTEGRAR .NET 3.5 (SXS)"
    $btnNetFx3.Location  = "400, 600"
    $btnNetFx3.Size      = "220, 40"
    $btnNetFx3.BackColor = [System.Drawing.Color]::DodgerBlue
    $btnNetFx3.ForeColor = [System.Drawing.Color]::White
    $btnNetFx3.FlatStyle = "Flat"
    $btnNetFx3.Enabled   = $false
    $toolTip.SetToolTip($btnNetFx3, "Instala .NET Framework 3.5 buscando la carpeta 'sxs' localmente.")
    $form.Controls.Add($btnNetFx3)

    # Boton aplicar cambios
    $btnApply           = New-Object System.Windows.Forms.Button
    $btnApply.Text      = "APLICAR CAMBIOS"
    $btnApply.Location  = "640, 600"
    $btnApply.Size      = "220, 40"
    $btnApply.BackColor = [System.Drawing.Color]::SeaGreen
    $btnApply.ForeColor = [System.Drawing.Color]::White
    $btnApply.FlatStyle = "Flat"
    $btnApply.Enabled   = $false
    $form.Controls.Add($btnApply)

    # Cache de features para filtrado rapido sin volver a llamar a DISM
    $script:cachedFeatures = @()

    # ------------------------------------------------------------------
    # 3. Helper: poblar el ListView aplicando el filtro de busqueda
    # ------------------------------------------------------------------
    $PopulateList = {
        param($FilterText)
        $lv.BeginUpdate()
        $lv.Items.Clear()

        foreach ($feat in $script:cachedFeatures) {
            $displayName = if (-not [string]::IsNullOrWhiteSpace($feat.DisplayName)) {
                $feat.DisplayName
            } else {
                $feat.FeatureName
            }

            # Aplicar filtro — omitir si no coincide en nombre visible ni en nombre interno
            if (-not [string]::IsNullOrWhiteSpace($FilterText)) {
                if ($displayName -notmatch $FilterText -and $feat.FeatureName -notmatch $FilterText) {
                    continue
                }
            }

            $item = New-Object System.Windows.Forms.ListViewItem($displayName)

            # Forzar a string para evitar errores con el enum de DISM en WinForms
            $stateString  = $feat.State.ToString()
            $stateDisplay = $stateString
            $color        = [System.Drawing.Color]::White

            switch ($stateString) {
                "Enabled" {
                    $stateDisplay  = "Habilitado"
                    $color         = [System.Drawing.Color]::Cyan
                    $item.Checked  = $true
                }
                "Disabled" {
                    $stateDisplay  = "Deshabilitado"
                    $item.Checked  = $false
                }
                "DisabledWithPayloadRemoved" {
                    $stateDisplay  = "Removido (Requiere Source)"
                    $color         = [System.Drawing.Color]::Salmon
                    $item.Checked  = $false
                }
                "EnablePending" {
                    $stateDisplay  = "Pendiente (Habilitar)"
                    $color         = [System.Drawing.Color]::Yellow
                    $item.Checked  = $true
                }
                "DisablePending" {
                    $stateDisplay  = "Pendiente (Deshabilitar)"
                    $color         = [System.Drawing.Color]::Orange
                    $item.Checked  = $false
                }
                Default {
                    $stateDisplay = $stateString
                }
            }

            $item.SubItems.Add([string]$stateDisplay)     | Out-Null
            $item.SubItems.Add([string]$feat.FeatureName) | Out-Null
            $item.ForeColor    = $color
            $item.ToolTipText  = $feat.Description
            $item.Tag          = $feat

            $lv.Items.Add($item) | Out-Null
        }
        $lv.EndUpdate()
    }

    # ------------------------------------------------------------------
    # 4. Eventos
    # ------------------------------------------------------------------

    # Carga inicial: obtener lista de features del WIM montado
    $form.Add_Shown({
        $form.Refresh()
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        try {
            $script:cachedFeatures = Get-WindowsOptionalFeature -Path $Script:MOUNT_DIR
            & $PopulateList -FilterText ""

            $lblStatus.Text      = "Total: $($script:cachedFeatures.Count). Listo para filtrar o aplicar."
            $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
            $btnApply.Enabled    = $true
            $btnNetFx3.Enabled   = $true
        } catch {
            $lblStatus.Text      = "Error critico al leer features: $_"
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
            Write-Log -LogLevel ERROR -Message "FEATURES_GUI: Error carga inicial: $_"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # Filtro de busqueda en tiempo real
    $txtSearch.Add_TextChanged({ & $PopulateList -FilterText $txtSearch.Text })

    # Boton INTEGRAR .NET 3.5 (SXS) con staging inteligente por arquitectura
    $btnNetFx3.Add_Click({
        $sxsPath = $null

        # 1. Busqueda automatica en la carpeta del script
        $pathLocal = Join-Path $PSScriptRoot "sxs"
        if (Test-Path $pathLocal) {
            $sxsPath = $pathLocal
        } else {
            # 2. Busqueda interactiva si no se encontro automaticamente
            $res = [System.Windows.Forms.MessageBox]::Show(
                "No se detecto la carpeta 'sxs' en la raiz del script automaticamente.`n`nDeseas seleccionarla manualmente?",
                "Buscar Origen (.NET 3.5)",
                'YesNo',
                'Question'
            )
            if ($res -eq 'Yes') {
                $fbd             = New-Object System.Windows.Forms.FolderBrowserDialog
                $fbd.Description = "Selecciona la carpeta 'sxs' (Puede ser la original del ISO de Windows)"
                if ($fbd.ShowDialog() -eq 'OK') { $sxsPath = $fbd.SelectedPath } else { return }
            } else { return }
        }

        if ($sxsPath) {
            # 3. Filtro inteligente de paquetes CAB
            $cabFiles = Get-ChildItem -Path $sxsPath -Filter "*netfx3*.cab" -ErrorAction SilentlyContinue

            if (-not $cabFiles -or $cabFiles.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show(
                    "No se encontro ningun paquete de .NET 3.5 (*netfx3*.cab) en la ruta seleccionada.`n`nPor favor verifica la carpeta.",
                    "Origen Invalido", 'OK', 'Warning')
                return
            }

            $form.Cursor       = [System.Windows.Forms.Cursors]::WaitCursor
            $btnNetFx3.Enabled = $false
            $btnApply.Enabled  = $false
            $lblStatus.Text      = "Aislando paquetes NetFx3 para instalacion rapida..."
            $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
            $form.Refresh()

            try {
                # Auto-deteccion de arquitectura de la imagen montada
                # Microsoft usa 'amd64' en nombres de CAB, no 'x64'
                $imgArch = "amd64"
                if     (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysArm32"))  { $imgArch = "arm64" }
                elseif (-not (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysWOW64"))) { $imgArch = "x86" }

                # A. Entorno esteril de staging en Scratch_DIR
                $isolatedSxs = Join-Path $Script:Scratch_DIR "NetFx3_Staging"
                if (Test-Path $isolatedSxs) { Remove-Item $isolatedSxs -Recurse -Force -ErrorAction SilentlyContinue }
                New-Item -Path $isolatedSxs -ItemType Directory -Force | Out-Null

                # B. Copiar solo los paquetes compatibles con la arquitectura destino
                $neutralCount = 0
                $langCount    = 0
                $skippedCount = 0

                foreach ($cab in $cabFiles) {
                    $cabName = $cab.Name.ToLower()
                    $include = $true

                    if ($cabName -match "~amd64~|~x86~|~arm64~") {
                        switch ($imgArch) {
                            "amd64" {
                                # x64 necesita binarios nativos amd64 y WoW64 x86
                                if ($cabName -notmatch "~amd64~|~x86~") { $include = $false }
                            }
                            "x86" {
                                # 32 bits puro: solo x86
                                if ($cabName -notmatch "~x86~") { $include = $false }
                            }
                            "arm64" {
                                # ARM64 moderno (Win11): copiar todo para no romper emuladores
                            }
                        }
                    }

                    if (-not $include) {
                        $skippedCount++
                    } else {
                        Copy-Item -Path $cab.FullName -Destination $isolatedSxs -Force
                        if ($cab.Name -match "~~\.cab$") { $neutralCount++ } else { $langCount++ }
                    }
                }

                if ($neutralCount -eq 0) {
                    throw "Se filtraron los paquetes y no quedo ningun paquete base de .NET 3.5 compatible con la arquitectura de la imagen ($imgArch)."
                }

                Write-Log -LogLevel ACTION -Message "Smart SXS: Aislados $neutralCount neutros, $langCount idioma. Omitidos $skippedCount incompatibles."

                # C. Ejecutar DISM apuntando solo al directorio de staging
                $lblStatus.Text      = "Instalando .NET 3.5 ($imgArch)..."
                $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
                $form.Refresh()

                dism /Image:"$Script:MOUNT_DIR" /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:"$isolatedSxs" | Out-Null

                if ($LASTEXITCODE -eq 0) {
                    $lblStatus.Text      = "Instalacion de .NET 3.5 exitosa."
                    $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen

                    $msg = ".NET Framework 3.5 se integro correctamente.`n`nSe inyectaron:`n- $neutralCount Paquete(s) Base (Neutral)`n- $langCount Paquete(s) de Idioma (Satelite)"
                    [System.Windows.Forms.MessageBox]::Show($msg, "Exito", 'OK', 'Information')

                    # Refrescar cache y lista tras la instalacion
                    $script:cachedFeatures = Get-WindowsOptionalFeature -Path $Script:MOUNT_DIR
                    & $PopulateList -FilterText $txtSearch.Text
                } else {
                    $lblStatus.Text      = "Error al instalar .NET 3.5 (Codigo $LASTEXITCODE)."
                    $lblStatus.ForeColor = [System.Drawing.Color]::Red
                    [System.Windows.Forms.MessageBox]::Show("Fallo la instalacion.`nCodigo DISM: $LASTEXITCODE", "Error", 'OK', 'Error')
                }
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Excepcion inesperada: $_", "Error", 'OK', 'Error')
            } finally {
                # D. Limpiar siempre el entorno de staging
                if (Test-Path $isolatedSxs) { Remove-Item $isolatedSxs -Recurse -Force -ErrorAction SilentlyContinue }
                $form.Cursor       = [System.Windows.Forms.Cursors]::Default
                $btnNetFx3.Enabled = $true
                $btnApply.Enabled  = $true
            }
        }
    })

    # Boton APLICAR CAMBIOS — habilitar/deshabilitar features seleccionadas
    $btnApply.Add_Click({
        if ($txtSearch.Text.Length -gt 0) {
            $res = [System.Windows.Forms.MessageBox]::Show(
                "Filtro activo. Solo se procesaran elementos visibles.`nContinuar?",
                "Advertencia", 'YesNo', 'Warning')
            if ($res -ne 'Yes') { return }
        }

        $changes = 0
        $errors  = 0

        $form.Cursor       = [System.Windows.Forms.Cursors]::WaitCursor
        $btnApply.Enabled  = $false
        $btnNetFx3.Enabled = $false

        foreach ($item in $lv.Items) {
            $feat          = $item.Tag
            $originalState = $feat.State
            $isNowChecked  = $item.Checked

            $shouldEnable  = ($originalState -ne "Enabled" -and $isNowChecked)
            $shouldDisable = ($originalState -eq "Enabled" -and -not $isNowChecked)

            if ($shouldEnable -or $shouldDisable) {

                # Guardia: .NET 3.5 con payload removido requiere el boton SXS dedicado
                if ($shouldEnable -and $feat.FeatureName -eq "NetFx3" -and $originalState -eq "DisabledWithPayloadRemoved") {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Para habilitar .NET Framework 3.5, por favor usa el boton azul dedicado 'INTEGRAR .NET 3.5 (SXS)'.",
                        "Aviso", 'OK', 'Information')
                    $item.Checked = $false
                    continue
                }

                $action = if ($shouldEnable) { "Enable" } else { "Disable" }
                $lblStatus.Text = "Procesando: $action $($feat.FeatureName)..."
                $form.Refresh()

                try {
                    Write-Log -LogLevel ACTION -Message "FEATURES: $action $($feat.FeatureName)"

                    if ($shouldEnable) {
                        Enable-WindowsOptionalFeature -Path $Script:MOUNT_DIR -FeatureName $feat.FeatureName -All -NoRestart -ErrorAction Stop | Out-Null
                        $item.SubItems[1].Text = "Habilitado"
                        $item.ForeColor        = [System.Drawing.Color]::Cyan
                        $feat.State            = "Enabled"
                    } else {
                        Disable-WindowsOptionalFeature -Path $Script:MOUNT_DIR -FeatureName $feat.FeatureName -NoRestart -ErrorAction Stop | Out-Null
                        $item.SubItems[1].Text = "Deshabilitado"
                        $item.ForeColor        = [System.Drawing.Color]::White
                        $feat.State            = "Disabled"
                    }
                    $changes++
                } catch {
                    $errors++
                    Write-Log -LogLevel ERROR -Message "Fallo $action feature $($feat.FeatureName): $_"
                    $item.ForeColor        = [System.Drawing.Color]::Red
                    $item.SubItems[1].Text = "ERROR"
                }
            }
        }

        $form.Cursor       = [System.Windows.Forms.Cursors]::Default
        $btnApply.Enabled  = $true
        $btnNetFx3.Enabled = $true
        $lblStatus.Text    = "Proceso finalizado."
        [System.Windows.Forms.MessageBox]::Show(
            "Operacion completada.`nCambios: $changes`nErrores: $errors",
            "Informe", 'OK', 'Information')
    })

    # ------------------------------------------------------------------
    # 5. Mostrar y limpiar
    # ------------------------------------------------------------------
    $form.ShowDialog() | Out-Null
    $form.Dispose()
    $script:cachedFeatures = $null
    [GC]::Collect()
}