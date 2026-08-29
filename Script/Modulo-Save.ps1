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
        Write-Warning "No hay imagen montada para guardar."; Pause; return 
    }

    # 2. BLOQUEO VHD (Como discutimos antes)
    if ($Script:IMAGE_MOUNTED -eq 2) {
        Write-Log -LogLevel INFO -Message "SaveManager: Operacion omitida. El usuario esta trabajando sobre un VHD/VHDX (Guardado en tiempo real)."
        Clear-Host
        Write-Warning "AVISO: Estas trabajando sobre un disco virtual (VHD/VHDX)."
        Write-Host "Los cambios en VHD se guardan automaticamente en tiempo real al editar archivos." -ForegroundColor Cyan
        Write-Host "No es necesario (ni posible) ejecutar operaciones de 'Commit' o 'Capture' aqui." -ForegroundColor Gray
        Write-Host "Simplemente desmonta la imagen para finalizar." -ForegroundColor Yellow
        Pause
        return
    }

    Write-Host "Preparando para guardar..." -ForegroundColor Cyan
    Write-Log -LogLevel INFO -Message "SaveManager: Asegurando que las colmenas de registro (Hives) esten desmontadas antes de llamar a DISM."
    Unmount-Hives

    # 3. BLOQUEO ESD
    # Verificamos si la extension original era .esd
    $isEsd = ($Script:WIM_FILE_PATH -match '\.esd$')

    if ($isEsd -and ($Mode -match 'Commit|Append|NewWim')) {
        Write-Log -LogLevel WARN -Message "SaveManager: Bloqueo de seguridad activado. Intento de escritura directa ('$Mode') sobre un archivo de compresion solida (.ESD)."
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host "      OPERACION NO PERMITIDA EN ARCHIVOS .ESD          " -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Has intentado hacer '$Mode' sobre una imagen ESD comprimida." -ForegroundColor Red
        Write-Host ""
        Write-Host "EXPLICACION TECNICA:" -ForegroundColor Cyan
        Write-Host "Los archivos ESD son de 'compresion solida' y no admiten escritura incremental." -ForegroundColor Gray
        Write-Host "DISM fallara si intentas guardar cambios directamente sobre el archivo original." -ForegroundColor Gray
        Write-Host ""
        Pause
        return
    }

    # 4. Logica Original
    if ($Mode -eq 'Commit') {
        Clear-Host
        Write-Host "[+] Guardando cambios en el indice $Script:MOUNTED_INDEX..." -ForegroundColor Yellow
        Write-Host "    > Por favor espera. DISM esta inicializando el motor de guardado (puede tardar en comenzar)..." -ForegroundColor Gray
        Write-Log -LogLevel ACTION -Message "SaveManager: Ejecutando DISM /Commit-Image para sobrescribir el indice $Script:MOUNTED_INDEX."
        dism /commit-image /mountdir:"$Script:MOUNT_DIR"
    }
    elseif ($Mode -eq 'Append') {
        Clear-Host
        Write-Host "[+] Guardando cambios en un nuevo indice (Append)..." -ForegroundColor Yellow
        Write-Host "    > Por favor espera. DISM esta calculando las diferencias (puede tardar en comenzar)..." -ForegroundColor Gray
        Write-Log -LogLevel ACTION -Message "SaveManager: Ejecutando DISM /Commit-Image /Append para crear un indice nuevo en la imagen."
        dism /commit-image /mountdir:"$Script:MOUNT_DIR" /append
    }
    elseif ($Mode -eq 'NewWim') {
        Clear-Host
        Write-Host "--- Guardar como Nuevo Archivo WIM (Exportar Estado Actual) ---" -ForegroundColor Cyan
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
        
        $DEST_WIM_PATH = Select-SavePathDialog -Title "Guardar copia como..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
        if (-not $DEST_WIM_PATH) { 
            Write-Log -LogLevel INFO -Message "SaveManager: El usuario cancelo la seleccion de la ruta destino para NewWim."
            Write-Warning "Operacion cancelada."; return 
        }

        # =========================================================
        #  Auto-Detección de Edición y Petición de Metadatos
        #  (Lee el registro offline en vivo, detectando si el usuario 
        #  cambio la edicion durante esta sesion).
        # =========================================================
        Write-Host "`n--- Obteniendo metadatos del sistema operativo ---" -ForegroundColor Yellow
        $defaultName = "Custom Image"
        $defaultDesc = "Imagen personalizada creada con AdminImagenOffline el $(Get-Date -Format 'yyyy-MM-dd')"
        $softwareHive = "$Script:MOUNT_DIR\Windows\System32\config\SOFTWARE"

        if (Test-Path -LiteralPath $softwareHive) {
            $tempHive = "HKLM\TempWimSoft_$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                reg load $tempHive $softwareHive 2>$null | Out-Null
                
                if ($LASTEXITCODE -eq 0) {
                    $regData = Get-ItemProperty -Path "Registry::$tempHive\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
                    
                    if ($regData) {
                        if ($regData.EditionID -and (Get-Command Get-WindowsEditionMetadata -ErrorAction SilentlyContinue)) {
                            $metadata = Get-WindowsEditionMetadata -QueryString $regData.EditionID
                            $defaultName = $metadata.Name
                            $defaultDesc = $metadata.Description
                            if ($regData.CurrentBuildNumber -ge 22000) {
                                $defaultName = $defaultName -replace "Windows ", "Windows 11 "
                            } else {
                                $defaultName = $defaultName -replace "Windows ", "Windows 10 "
                            }
                        } elseif ($regData.ProductName) {
                            $defaultName = $regData.ProductName
                            if ($regData.CurrentBuildNumber -ge 22000) {
                                $defaultName = $defaultName -replace "Windows 10", "Windows 11"
                            }
                        }
                    }
                }
            } catch {
                Write-Log -LogLevel WARN -Message "SaveManager: No se pudo auto-detectar la edicion en el registro offline."
            } finally {
                # Garantizado incluso si lanza excepcion: evita que SOFTWARE quede bloqueado para DISM
                reg unload $tempHive 2>$null | Out-Null
                [GC]::Collect()
            }
        }

        # Fallback historico si la colmena falla pero la imagen WIM base tiene info
        if ($defaultName -eq "Custom Image") {
            try {
                $info = Get-WindowsImage -ImagePath $Script:WIM_FILE_PATH -Index $Script:MOUNTED_INDEX -ErrorAction SilentlyContinue
                if ($info -and $info.ImageName) { $defaultName = $info.ImageName }
            } catch {}
        }
        
        Write-Host ""
        $IMAGE_NAME = Read-Host "Ingrese el NOMBRE para la imagen interna (Enter = '$defaultName')"
        if ([string]::IsNullOrWhiteSpace($IMAGE_NAME)) { $IMAGE_NAME = $defaultName }

        $IMAGE_DESC = Read-Host "Ingrese la DESCRIPCION (Enter = Auto-generada)"
        if ([string]::IsNullOrWhiteSpace($IMAGE_DESC)) { $IMAGE_DESC = $defaultDesc }
        
        Write-Host "`n[+] Capturando estado actual a nuevo WIM..." -ForegroundColor Yellow
        Write-Host "    > Por favor espera. DISM esta preparando la compresion maxima (puede tardar unos minutos en iniciar)..." -ForegroundColor Gray
        Write-Log -LogLevel ACTION -Message "SaveManager: Ejecutando DISM /Capture-Image desde la carpeta de montaje hacia '$DEST_WIM_PATH' (Nombre: $IMAGE_NAME)."
        
        # Evaluacion dinamica: Si el WIM original tiene "PE" o "Setup" en el nombre/descripcion, 
        # o si estamos seguros de que es un boot.wim, activamos el flag bootable.
        $bootableFlag = ""
        if ($IMAGE_NAME -match "(?i)PE|Recovery|Recuperacion|Setup|Boot") {
            $bootableFlag = "/Bootable"
        }

        dism /Capture-Image /ImageFile:"$DEST_WIM_PATH" /CaptureDir:"$Script:MOUNT_DIR" /Name:"$IMAGE_NAME" /Description:"$IMAGE_DESC" /Compress:max /CheckIntegrity /ScratchDir:"$Script:Scratch_DIR" $bootableFlag

        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Copia guardada exitosamente en:" -ForegroundColor Green
            Write-Host "     $DEST_WIM_PATH" -ForegroundColor Cyan
            Write-Host "`nNOTA: La imagen original sigue montada. Debes desmontarla (sin guardar) al salir." -ForegroundColor Gray
            Write-Log -LogLevel INFO -Message "SaveManager: Operacion NewWim completada exitosamente. Imagen original continua montada."
        } else {
            Write-Host "[ERROR] Fallo al capturar la nueva imagen (Codigo: $LASTEXITCODE)."
            Write-Log -LogLevel ERROR -Message "SaveManager: Fallo en DISM Capture-Image (NewWim). Codigo LASTEXITCODE: $LASTEXITCODE"
        }
        Pause
        return 
    }

    # Bloque comun para Commit/Append exitoso
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Cambios guardados." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "SaveManager: Cambios ($Mode) guardados exitosamente en la imagen original."
    } else {
        # Si llegamos aqui con un error, es un error legitimo de DISM (no por bloqueo de ESD)
        Write-Host "[ERROR] Fallo al guardar cambios (Codigo: $LASTEXITCODE)."
        Write-Log -LogLevel ERROR -Message "SaveManager: Fallo en DISM al guardar cambios ($Mode). Codigo LASTEXITCODE: $LASTEXITCODE"
    }
    Pause
}
