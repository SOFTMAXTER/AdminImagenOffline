# =================================================================
#  Modulo-Guardar
#
#  CONTENIDO   : Save-Changes
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen, 1 = WIM, 2 = VHD)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - $Script:WIM_FILE_PATH  : ruta del archivo de imagen base
#    - $Script:Scratch_DIR    : ruta al directorio temporal
#    - $Script:MOUNTED_INDEX  : indice WIM montado
#    - Unmount-Hives          : desmontar colmenas offline del registro
#    - Select-SavePathDialog  : ui para guardar nuevos archivos WIM
#  CARGA       : . "$PSScriptRoot\Modulo-Save.ps1"
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

# =============================================
#  FUNCIONES DE ACCION (Guardar Cambios)
# =============================================
function Save-Changes {
    param ([string]$Mode) # 'Commit', 'Append' o 'NewWim'

    Write-Log -LogLevel INFO -Message "SaveManager: Solicitud de guardado iniciada. Modo solicitado: [$Mode]"

    # 1. Validacion de Montaje
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        Write-Log -LogLevel WARN -Message "SaveManager: Operacion rechazada. No hay ninguna imagen montada en el sistema."
        Write-Warning (Get-AIOString 'save.no_image_mounted'); Pause; return 
    }

    # 2. BLOQUEO VHD (Como discutimos antes)
    if ($Script:IMAGE_MOUNTED -eq 2) {
        Write-Log -LogLevel INFO -Message "SaveManager: Operacion omitida. El usuario esta trabajando sobre un VHD/VHDX (Guardado en tiempo real)."
        Clear-Host
        Write-Warning (Get-AIOString 'save.vhd_warn')
        Write-Host (Get-AIOString 'save.vhd_realtime') -ForegroundColor Cyan
        Write-Host (Get-AIOString 'save.vhd_no_commit') -ForegroundColor Gray
        Write-Host (Get-AIOString 'save.vhd_unmount_hint') -ForegroundColor Yellow
        Pause
        return
    }

    Write-Host (Get-AIOString 'save.preparing') -ForegroundColor Cyan
    Write-Log -LogLevel INFO -Message "SaveManager: Asegurando que las colmenas de registro (Hives) esten desmontadas antes de llamar a DISM."
    Unmount-Hives

    # 3. BLOQUEO ESD
    # Verificamos si la extension original era .esd
    $isEsd = ($Script:WIM_FILE_PATH -match '\.esd$')

    if ($isEsd -and ($Mode -match 'Commit|Append|NewWim')) {
        Write-Log -LogLevel WARN -Message "SaveManager: Bloqueo de seguridad activado. Intento de escritura directa ('$Mode') sobre un archivo de compresion solida (.ESD)."
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host (Get-AIOString 'save.esd_title') -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host (Get-AIOString 'save.esd_attempted' $Mode) -ForegroundColor Red
        Write-Host ""
        Write-Host (Get-AIOString 'save.esd_tech_header') -ForegroundColor Cyan
        Write-Host (Get-AIOString 'save.esd_tech_line1') -ForegroundColor Gray
        Write-Host (Get-AIOString 'save.esd_tech_line2') -ForegroundColor Gray
        Write-Host ""
        Pause
        return
    }

    # 4. Logica Original
    if ($Mode -eq 'Commit') {
        Clear-Host
        Write-Host (Get-AIOString 'save.commit_start' $Script:MOUNTED_INDEX) -ForegroundColor Yellow
        Write-Host (Get-AIOString 'save.commit_wait') -ForegroundColor Gray
        Write-Log -LogLevel ACTION -Message "SaveManager: Ejecutando DISM /Commit-Image para sobrescribir el indice $Script:MOUNTED_INDEX."
        dism /commit-image /mountdir:"$Script:MOUNT_DIR"
    }
    elseif ($Mode -eq 'Append') {
        Clear-Host
        Write-Host (Get-AIOString 'save.append_start') -ForegroundColor Yellow
        Write-Host (Get-AIOString 'save.append_wait') -ForegroundColor Gray
        Write-Log -LogLevel ACTION -Message "SaveManager: Ejecutando DISM /Commit-Image /Append para crear un indice nuevo en la imagen."
        dism /commit-image /mountdir:"$Script:MOUNT_DIR" /append
    }
    elseif ($Mode -eq 'NewWim') {
        Clear-Host
        Write-Host (Get-AIOString 'save.newwim_header') -ForegroundColor Cyan
        Write-Log -LogLevel INFO -Message "SaveManager: Modo NewWim (Capture-Image) activado. Solicitando ruta de destino y metadatos."
        
        # 1. Seleccionar destino
        if ($Script:WIM_FILE_PATH) {
            $wimFileObject = Get-Item -Path $Script:WIM_FILE_PATH
            $baseName = $wimFileObject.BaseName
            $dirName = $wimFileObject.DirectoryName
        } else {
            $baseName = "Imagen"
            $dirName = "C:\"
        }
        
        $DEFAULT_DEST_PATH = Join-Path $dirName "${baseName}_MOD.wim"
        
        $DEST_WIM_PATH = Select-SavePathDialog -Title (Get-AIOString 'save.newwim_dialog_title') -Filter (Get-AIOString 'save.wim_filter') -DefaultFileName $DEFAULT_DEST_PATH
        if (-not $DEST_WIM_PATH) { 
            Write-Log -LogLevel INFO -Message "SaveManager: El usuario cancelo la seleccion de la ruta destino para NewWim."
            Write-Warning (Get-AIOString 'common.operation_cancelled'); return 
        }

        # =========================================================
        try {
            $destParent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($DEST_WIM_PATH))
            $parentIdentity = Get-AIOFileIdentity $destParent
            $mountIdentity = Get-AIOFileIdentity $Script:MOUNT_DIR
            $sourceIdentity = Get-AIOFileIdentity $Script:WIM_FILE_PATH
            $previous = Get-AIOOutputSnapshot $DEST_WIM_PATH
            if ((Test-AIOPathWithin $parentIdentity.Path $mountIdentity.Path) -or ($previous -and $previous.Id -eq $sourceIdentity.Id)) {
                throw 'La copia debe guardarse fuera del montaje y en un archivo distinto del WIM de origen.'
            }
        } catch { Write-Warning $_.Exception.Message; Pause; return }

        #  Auto-Detección de Edición y Petición de Metadatos
        #  (Reutiliza la edicion efectiva del Dashboard y la descripcion
        #  del catalogo central, sin depender de haber abierto otro menu).
        # =========================================================
        Write-Host (Get-AIOString 'save.reading_os_meta') -ForegroundColor Yellow
        $defaultName = "Custom Image"
        $defaultDesc = "Imagen personalizada creada con AdminImagenOffline el $(Get-Date -Format 'yyyy-MM-dd')"
        # Reutiliza los metadatos del Dashboard (nombre efectivo segun build y edicion,
        # ya normalizado para Windows 10/11, Cloud, Server y WinPE). Una cache valida
        # evita otra lectura de SOFTWARE; ForceMenuRefresh solicita actualizarla.
        $dashMeta = $null
        try {
            if (Get-Command Get-AIOCachedDashboardMetadata -ErrorAction SilentlyContinue) {
                $dashMeta = Get-AIOCachedDashboardMetadata -MountState $Script:IMAGE_MOUNTED -MountPath $Script:MOUNT_DIR `
                    -ImagePath $Script:WIM_FILE_PATH -Index $Script:MOUNTED_INDEX -ForceRefresh:$Script:ForceMenuRefresh
                $dashName = if ($null -ne $dashMeta) { ([string]$dashMeta.Name).Trim() } else { '' }
                if ($dashName -and $dashName -notmatch '^No disponible$|nombre no disponible|edicion no disponible') {
                    $defaultName = $dashName
                }
            }
        } catch {
            Write-Log -LogLevel WARN -Message "SaveManager: No se pudo auto-detectar la edicion con los metadatos del Dashboard: $($_.Exception.Message)"
        }

        # El nombre proviene del Dashboard; la descripcion se conserva literalmente
        # del catalogo, usando la edicion efectiva y una coincidencia exacta.
        # Cargar aqui el catalogo no requiere haber abierto Cambio-Edicion-Menu.
        try {
            $effectiveEdition = if ($null -ne $dashMeta) { ([string]$dashMeta.Edition).Trim() } else { '' }
            if ($effectiveEdition -and $effectiveEdition -ne 'No disponible') {
                $catalogPath = Join-Path $PSScriptRoot 'Catalogos\Ediciones.ps1'
                if (Test-Path -LiteralPath $catalogPath -PathType Leaf) {
                    . $catalogPath
                    $catalogEntry = $script:EditionCatalog | Where-Object {
                        $_.EditionID -ieq $effectiveEdition
                    } | Select-Object -First 1
                    if ($null -ne $catalogEntry -and -not [string]::IsNullOrWhiteSpace([string]$catalogEntry.Description)) {
                        $defaultDesc = [string]$catalogEntry.Description
                    }
                }
            }
        } catch {
            Write-Log -LogLevel WARN -Message "SaveManager: No se pudo leer la descripcion del catalogo; se conserva la descripcion generica. $($_.Exception.Message)"
        }

        # Fallback historico si los metadatos no estan disponibles pero la imagen WIM base tiene info
        if ($defaultName -eq "Custom Image") {
            try {
                $info = Get-WindowsImage -ImagePath $Script:WIM_FILE_PATH -Index $Script:MOUNTED_INDEX -ErrorAction SilentlyContinue
                if ($info -and $info.ImageName) { $defaultName = $info.ImageName }
            } catch {}
        }
        
        Write-Host ""
        $IMAGE_NAME = Read-Host (Get-AIOString 'save.prompt_name' $defaultName)
        if ([string]::IsNullOrWhiteSpace($IMAGE_NAME)) { $IMAGE_NAME = $defaultName }

        Write-Host (Get-AIOString 'save.default_desc_label') -ForegroundColor Cyan -NoNewline
        Write-Host $defaultDesc -ForegroundColor Gray
        $IMAGE_DESC = Read-Host (Get-AIOString 'save.prompt_desc')
        if ([string]::IsNullOrWhiteSpace($IMAGE_DESC)) { $IMAGE_DESC = $defaultDesc }
        
        Write-Host (Get-AIOString 'save.capture_start') -ForegroundColor Yellow
        Write-Host (Get-AIOString 'save.capture_wait') -ForegroundColor Gray
        Write-Log -LogLevel ACTION -Message "SaveManager: Ejecutando DISM /Capture-Image desde la carpeta de montaje hacia '$DEST_WIM_PATH' (Nombre: $IMAGE_NAME)."
        
        $pending = Join-Path $destParent ('.captura-' + [Guid]::NewGuid().ToString('N') + '.wim')
        try {
            $source = Get-AIOWimContainerInfo -Path $Script:WIM_FILE_PATH
            $bootable = ($source.BootIndex -gt 0 -and $source.BootIndex -eq $Script:MOUNTED_INDEX)
            $arguments = @('/Capture-Image', "/ImageFile:$pending", "/CaptureDir:$Script:MOUNT_DIR", "/Name:$IMAGE_NAME",
                "/Description:$IMAGE_DESC", '/Compress:max', '/CheckIntegrity', "/ScratchDir:$Script:Scratch_DIR")
            if ($bootable) { $arguments += '/Bootable' }
            $result = Invoke-AIOConsoleSystemTool -Tool dism.exe -Arguments $arguments
            if ($result.ExitCode -ne 0) { throw "DISM no completo la captura (codigo $($result.ExitCode))." }
            $indexes = @(Get-WindowsImage -ImagePath $pending -ErrorAction Stop)
            $outputInfo = Get-AIOWimContainerInfo -Path $pending
            if ($indexes.Count -ne 1 -or $indexes[0].ImageIndex -ne 1 -or $indexes[0].ImageName -cne $IMAGE_NAME -or
                $outputInfo.BootIndex -ne [int]$bootable) { throw 'No se pudo verificar el indice de la copia capturada.' }
            if ((Get-AIOFileIdentity $destParent).Id -ne $parentIdentity.Id) { throw 'Cambio el directorio de destino.' }
            Publish-AIOVerifiedFile $pending $DEST_WIM_PATH $previous
            Write-Host (Get-AIOString 'save.capture_ok' $DEST_WIM_PATH) -ForegroundColor Green
            Write-Log -LogLevel INFO -Message "SaveManager: Nueva copia verificada en '$DEST_WIM_PATH'."
        } catch {
            Write-Warning $_.Exception.Message
            Write-Log -LogLevel ERROR -Message "SaveManager: $($_.Exception.Message)"
        } finally {
            if ([IO.File]::Exists($pending)) { Remove-Item -LiteralPath $pending -Force -ErrorAction Continue }
        }
        Pause
        return 
    }

    # Bloque comun para Commit/Append exitoso
    # Nota: Commit/Append vuelca el montaje actual al archivo .wim sin alterar
    # los metadatos del SO montado en MOUNT_DIR, por lo que se conserva la cache del Dashboard.
    if ($LASTEXITCODE -eq 0) {
        Write-Host (Get-AIOString 'save.saved_ok') -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "SaveManager: Cambios ($Mode) guardados exitosamente en la imagen original."
    } else {
        # Si llegamos aqui con un error, es un error legitimo de DISM (no por bloqueo de ESD)
        Write-Host (Get-AIOString 'save.save_failed' $LASTEXITCODE)
        Write-Log -LogLevel ERROR -Message "SaveManager: Fallo en DISM al guardar cambios ($Mode). Codigo LASTEXITCODE: $LASTEXITCODE"
    }
    Pause
}
