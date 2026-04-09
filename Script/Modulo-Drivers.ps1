# =================================================================
#  Modulo-Drivers
#
#  CONTENIDO   : Show-Drivers-GUI
#                Show-Uninstall-Drivers-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#  CARGA       : . "$PSScriptRoot\Modulo-Drivers.ps1"
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

# =================================================================
#  Show-Drivers-GUI — Inyector de drivers offline
# =================================================================
function Show-Drivers-GUI {
    param()

    # ------------------------------------------------------------------
    # 1. Validacion de imagen montada
    # ------------------------------------------------------------------
    if ($Script:IMAGE_MOUNTED -eq 0) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # ------------------------------------------------------------------
    # 2. Construccion del formulario
    # ------------------------------------------------------------------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "Inyector de Drivers - (Offline)"
    $form.Size            = New-Object System.Drawing.Size(1000, 650)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White

    $lblTitle          = New-Object System.Windows.Forms.Label
    $lblTitle.Text     = "Gestion de Drivers"
    $lblTitle.Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 15)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # Botones superiores
    $btnLoadFolder           = New-Object System.Windows.Forms.Button
    $btnLoadFolder.Text      = "[CARPETA] Cargar..."
    $btnLoadFolder.Location  = New-Object System.Drawing.Point(600, 12)
    $btnLoadFolder.Size      = New-Object System.Drawing.Size(160, 30)
    $btnLoadFolder.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
    $btnLoadFolder.ForeColor = [System.Drawing.Color]::White
    $btnLoadFolder.FlatStyle = "Flat"
    $form.Controls.Add($btnLoadFolder)

    $btnAddFile           = New-Object System.Windows.Forms.Button
    $btnAddFile.Text      = "+ Agregar Archivo .INF"
    $btnAddFile.Location  = New-Object System.Drawing.Point(770, 12)
    $btnAddFile.Size      = New-Object System.Drawing.Size(180, 30)
    $btnAddFile.BackColor = [System.Drawing.Color]::RoyalBlue
    $btnAddFile.ForeColor = [System.Drawing.Color]::White
    $btnAddFile.FlatStyle = "Flat"
    $form.Controls.Add($btnAddFile)

    # Leyenda de colores
    $lblLegend           = New-Object System.Windows.Forms.Label
    $lblLegend.Text      = "Amarillo = Ya instalado | Blanco = Nuevo"
    $lblLegend.Location  = New-Object System.Drawing.Point(20, 45)
    $lblLegend.AutoSize  = $true
    $lblLegend.ForeColor = [System.Drawing.Color]::Gold
    $form.Controls.Add($lblLegend)

    # ListView principal
    $listView                  = New-Object System.Windows.Forms.ListView
    $listView.Location         = New-Object System.Drawing.Point(20, 70)
    $listView.Size             = New-Object System.Drawing.Size(940, 470)
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

    # Etiqueta de estado
    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "Listo."
    $lblStatus.Location  = New-Object System.Drawing.Point(20, 550)
    $lblStatus.AutoSize  = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($lblStatus)

    # Botones inferiores
    $btnInstall           = New-Object System.Windows.Forms.Button
    $btnInstall.Text      = "INYECTAR SELECCIONADOS"
    $btnInstall.Location  = New-Object System.Drawing.Point(760, 560)
    $btnInstall.Size      = New-Object System.Drawing.Size(200, 35)
    $btnInstall.BackColor = [System.Drawing.Color]::SeaGreen
    $btnInstall.ForeColor = [System.Drawing.Color]::White
    $btnInstall.FlatStyle = "Flat"
    $form.Controls.Add($btnInstall)

    $btnSelectNew           = New-Object System.Windows.Forms.Button
    $btnSelectNew.Text      = "Seleccionar Solo Nuevos"
    $btnSelectNew.Location  = New-Object System.Drawing.Point(20, 580)
    $btnSelectNew.Size      = New-Object System.Drawing.Size(150, 25)
    $btnSelectNew.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSelectNew.FlatStyle = "Flat"
    $form.Controls.Add($btnSelectNew)

    # ------------------------------------------------------------------
    # 3. Cache de drivers instalados (scope script para limpieza al cerrar)
    # ------------------------------------------------------------------
    $script:cachedInstalledDrivers = @()

    # ------------------------------------------------------------------
    # 4. Helper: procesar un archivo .INF y devolver un ListViewItem
    #    Se guarda como scriptblock en $script: para poder invocarse desde
    #    los eventos Add_Click sin perder el scope del formulario.
    # ------------------------------------------------------------------
    $Script:ProcessInfFile = {
        param($fileObj)

        $classType   = "Desconocido"
        $localVersion = "---"
        $statusText  = "Nuevo"
        $isInstalled = $false

        # Lectura rapida via StreamReader — evita cargar todo el archivo en memoria
        try {
            $stream    = [System.IO.StreamReader]::new($fileObj.FullName)
            $linesRead = 0

            while ($null -ne ($line = $stream.ReadLine()) -and $linesRead -lt 300) {
                if ($line -match "^Class\s*=\s*(.*)") {
                    $classType = $matches[1].Trim()
                }
                if ($line -match "DriverVer\s*=\s*.*?,([0-9\.\s]+)") {
                    $localVersion = $matches[1].Trim()
                }
                # Salida temprana si ya encontramos ambos campos
                if ($classType -ne "Desconocido" -and $localVersion -ne "---") { break }
                $linesRead++
            }
        } catch {
            # Silencioso — archivo bloqueado u otro error de lectura no es fatal
        } finally {
            if ($null -ne $stream) { $stream.Close(); $stream.Dispose() }
        }

        # Comparacion contra la cache de drivers instalados en la imagen
        $foundByName = $script:cachedInstalledDrivers | Where-Object {
            [System.IO.Path]::GetFileName($_.OriginalFileName) -eq $fileObj.Name
        }

        if ($foundByName) {
            $isInstalled = $true; $statusText = "INSTALADO"
        } elseif ($localVersion -ne "---") {
            $foundByVer = $script:cachedInstalledDrivers | Where-Object {
                $_.Version -eq $localVersion -and $_.ClassName -eq $classType
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

    # ------------------------------------------------------------------
    # 5. Eventos
    # ------------------------------------------------------------------

    # Al mostrarse: cargar la cache de drivers ya presentes en la imagen
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

    # Cargar carpeta recursivamente
    $btnLoadFolder.Add_Click({
        $fbd             = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Buscar drivers recursivamente"

        if ($fbd.ShowDialog() -eq 'OK') {
            $lblStatus.Text = "Escaneando..."
            $form.Refresh()
            $listView.BeginUpdate()

            $files = Get-ChildItem -Path $fbd.SelectedPath -Filter "*.inf" -Recurse
            foreach ($f in $files) {
                $newItem = & $Script:ProcessInfFile -fileObj $f
                $listView.Items.Add($newItem) | Out-Null
            }

            $listView.EndUpdate()
            $lblStatus.Text = "Drivers cargados: $($listView.Items.Count)"
        }
    })

    # Agregar archivos .INF individuales
    $btnAddFile.Add_Click({
        $ofd             = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter      = "Archivos INF (*.inf)|*.inf"
        $ofd.Multiselect = $true

        if ($ofd.ShowDialog() -eq 'OK') {
            $listView.BeginUpdate()
            foreach ($fn in $ofd.FileNames) {
                try {
                    $newItem = & $Script:ProcessInfFile -fileObj (Get-Item $fn)
                    $listView.Items.Add($newItem) | Out-Null
                } catch {}
            }
            $listView.EndUpdate()
        }
    })

    # Marcar solo los nuevos
    $btnSelectNew.Add_Click({
        foreach ($item in $listView.Items) {
            $item.Checked = ($item.Text -match "Nuevo")
        }
    })

    # Inyectar drivers seleccionados
    $btnInstall.Add_Click({
        $checkedItems = $listView.CheckedItems
        if ($checkedItems.Count -eq 0) {
            Write-Log -LogLevel WARN -Message "Driver_Injector: Intento de instalacion sin drivers seleccionados en la GUI."
            return
        }

        if ([System.Windows.Forms.MessageBox]::Show(
                "Inyectar $($checkedItems.Count) drivers?", "Confirmar", 'YesNo') -eq 'Yes') {

            Write-Log -LogLevel ACTION -Message "Driver_Injector: Iniciando inyeccion masiva de $($checkedItems.Count) controladores en la imagen."
            $btnInstall.Enabled = $false

            $count   = 0
            $errs    = 0
            $total   = $checkedItems.Count
            $success = 0

            foreach ($item in $checkedItems) {
                $count++
                $driverName = $item.SubItems[1].Text
                $driverPath = $item.Tag

                $lblStatus.Text = "Instalando ($count/$total): $driverName..."
                $form.Refresh()

                Write-Log -LogLevel INFO -Message "Driver_Injector: Procesando [$count/$total] -> $driverPath"

                try {
                    dism /Image:$Script:MOUNT_DIR /Add-Driver /Driver:"$driverPath" /ForceUnsigned | Out-Null

                    if ($LASTEXITCODE -eq 0) {
                        $item.BackColor = [System.Drawing.Color]::DarkGreen
                        $item.Text      = "INSTALADO"
                        $item.Checked   = $false
                        $success++
                        Write-Log -LogLevel INFO -Message "Driver_Injector: Exito. Controlador inyectado correctamente."
                    } else {
                        throw "DISM rechazo el controlador. LASTEXITCODE: $LASTEXITCODE"
                    }
                } catch {
                    $errs++
                    $item.BackColor = [System.Drawing.Color]::DarkRed
                    $item.Text      = "ERROR"
                    Write-Log -LogLevel ERROR -Message "Driver_Injector: Falla critica inyectando [$driverName] - $($_.Exception.Message)"
                }
            }

            Write-Log -LogLevel ACTION -Message "Driver_Injector: Ciclo de inyeccion finalizado. Exitos: $success | Errores: $errs"

            # Reconstruir cache con el estado real post-inyeccion
            $lblStatus.Text = "Actualizando base de datos de drivers... Por favor espera."
            $form.Refresh()
            Write-Log -LogLevel INFO -Message "Driver_Injector: Consultando a DISM para reconstruir la cache interna de drivers instalados..."

            try {
                $dismDrivers = Get-WindowsDriver -Path $Script:MOUNT_DIR -ErrorAction SilentlyContinue
                if ($dismDrivers) {
                    $script:cachedInstalledDrivers = $dismDrivers
                    Write-Log -LogLevel INFO -Message "Driver_Injector: Cache recargada exitosamente. Se encontraron $($dismDrivers.Count) controladores en la imagen."
                } else {
                    Write-Log -LogLevel WARN -Message "Driver_Injector: Get-WindowsDriver no devolvio resultados al recargar la cache."
                }
            } catch {
                Write-Log -LogLevel ERROR -Message "Driver_Injector: Fallo al ejecutar Get-WindowsDriver durante la recarga de cache - $($_.Exception.Message)"
                Write-Warning "No se pudo actualizar la cache de drivers."
            }

            $btnInstall.Enabled = $true
            $lblStatus.Text     = "Proceso terminado. Errores: $errs"
            [System.Windows.Forms.MessageBox]::Show(
                "Proceso terminado.`nErrores: $errs`n`nLa lista de drivers instalados se ha actualizado internamente.",
                "Info", 'OK', 'Information'
            )
        } else {
            Write-Log -LogLevel INFO -Message "Driver_Injector: El usuario cancelo la inyeccion en el cuadro de confirmacion."
        }
    })

    # Cierre seguro
    $form.Add_FormClosing({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Seguro que quieres cerrar esta ventana?",
            "Confirmar",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirm -eq 'No') { $_.Cancel = $true }
    })

    # ------------------------------------------------------------------
    # 6. Mostrar y limpiar
    # ------------------------------------------------------------------
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
    $form.Text            = "Eliminar Drivers de la Imagen - $Script:MOUNT_DIR"
    $form.Size            = New-Object System.Drawing.Size(850, 600)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White

    $lblTitle          = New-Object System.Windows.Forms.Label
    $lblTitle.Text     = "Drivers de Terceros Instalados (OEM)"
    $lblTitle.Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 15)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    $lblWarn           = New-Object System.Windows.Forms.Label
    $lblWarn.Text      = "CUIDADO: No elimines drivers de arranque (Disco/USB) o la imagen no iniciara."
    $lblWarn.Location  = New-Object System.Drawing.Point(350, 20)
    $lblWarn.AutoSize  = $true
    $lblWarn.ForeColor = [System.Drawing.Color]::Salmon
    $form.Controls.Add($lblWarn)

    # ListView principal
    $listView               = New-Object System.Windows.Forms.ListView
    $listView.Location      = New-Object System.Drawing.Point(20, 50)
    $listView.Size          = New-Object System.Drawing.Size(790, 450)
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
    $lblStatus.Location  = New-Object System.Drawing.Point(20, 510)
    $lblStatus.AutoSize  = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($lblStatus)

    $btnDelete           = New-Object System.Windows.Forms.Button
    $btnDelete.Text      = "ELIMINAR SELECCIONADOS"
    $btnDelete.Location  = New-Object System.Drawing.Point(560, 520)
    $btnDelete.Size      = New-Object System.Drawing.Size(250, 35)
    $btnDelete.BackColor = [System.Drawing.Color]::Crimson
    $btnDelete.ForeColor = [System.Drawing.Color]::White
    $btnDelete.FlatStyle = "Flat"
    $form.Controls.Add($btnDelete)

    $btnSelectAll           = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text      = "Marcar Todo"
    $btnSelectAll.Location  = New-Object System.Drawing.Point(20, 530)
    $btnSelectAll.Size      = New-Object System.Drawing.Size(100, 25)
    $btnSelectAll.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSelectAll.FlatStyle = "Flat"
    $form.Controls.Add($btnSelectAll)

    # ------------------------------------------------------------------
    # 3. Eventos
    # ------------------------------------------------------------------

    # Al mostrarse: listar drivers de terceros instalados en la imagen
    $form.Add_Shown({
        $form.Refresh()
        $listView.BeginUpdate()

        try {
            # Sin -All: solo drivers OEM, excluye drivers de bandeja de entrada de Microsoft
            $drivers = Get-WindowsDriver -Path $Script:MOUNT_DIR -ErrorAction Stop

            foreach ($drv in $drivers) {
                $oemName = $drv.Driver  # ej. oem1.inf — lo que DISM necesita para borrar

                $item = New-Object System.Windows.Forms.ListViewItem($oemName)
                $item.SubItems.Add($drv.OriginalFileName) | Out-Null
                $item.SubItems.Add($drv.ClassName)        | Out-Null
                $item.SubItems.Add($drv.ProviderName)     | Out-Null
                $item.SubItems.Add($drv.Version)          | Out-Null
                $item.Tag = $oemName  # guardado para el comando de eliminacion

                $listView.Items.Add($item) | Out-Null
            }

            $lblStatus.Text      = "Drivers encontrados: $($listView.Items.Count)"
            $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
        } catch {
            $lblStatus.Text      = "Error al leer drivers: $_"
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
        }

        $listView.EndUpdate()
    })

    # Marcar todos
    $btnSelectAll.Add_Click({
        foreach ($item in $listView.Items) { $item.Checked = $true }
    })

    # Eliminar drivers seleccionados
    $btnDelete.Add_Click({
        $checkedItems = $listView.CheckedItems
        if ($checkedItems.Count -eq 0) { return }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Se van a ELIMINAR PERMANENTEMENTE $($checkedItems.Count) drivers.`nEstas seguro?",
            "Confirmar Eliminacion", 'YesNo', 'Warning'
        )

        if ($confirm -eq 'Yes') {
            $btnDelete.Enabled = $false

            $count  = 0
            $total  = $checkedItems.Count
            $errors = 0

            foreach ($item in $checkedItems) {
                $count++
                $oemInf  = $item.Tag
                $origName = $item.SubItems[1].Text

                $lblStatus.Text = "Eliminando ($count/$total): $origName ($oemInf)..."
                $form.Refresh()

                Write-Log -LogLevel ACTION -Message "DRIVER_REMOVE: Eliminando $oemInf ($origName)"

                try {
                    dism /Image:$Script:MOUNT_DIR /Remove-Driver /Driver:"$oemInf" | Out-Null

                    if ($LASTEXITCODE -ne 0) { throw "Error DISM $LASTEXITCODE" }

                    $item.BackColor = [System.Drawing.Color]::Gray
                    $item.ForeColor = [System.Drawing.Color]::Black
                    $item.Text      += " [BORRADO]"
                    $item.Checked   = $false
                } catch {
                    $errors++
                    $item.BackColor = [System.Drawing.Color]::DarkRed
                    Write-Log -LogLevel ERROR -Message "Fallo al eliminar $oemInf"
                }
            }

            $btnDelete.Enabled = $true
            $lblStatus.Text    = "Proceso finalizado. Errores: $errors"
            [System.Windows.Forms.MessageBox]::Show(
                "Proceso completado.`nEliminados: $($total - $errors)`nErrores: $errors",
                "Resultado", 'OK', 'Information'
            )
        }
    })

    # Cierre seguro
    $form.Add_FormClosing({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Seguro que quieres cerrar esta ventana?",
            "Confirmar",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirm -eq 'No') { $_.Cancel = $true }
    })

    # ------------------------------------------------------------------
    # 4. Mostrar y limpiar
    # ------------------------------------------------------------------
    $form.ShowDialog() | Out-Null
    if ($null -ne $listView) { $listView.Dispose() }
    $form.Dispose()
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}