# =================================================================
#  Modulo-Indices
#
#  CONTENIDO   : Export-Index, Delete-Index
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen, 1 = WIM, 2 = VHD)
#    - $Script:WIM_FILE_PATH  : ruta del archivo de imagen base
#    - $Script:Scratch_DIR    : ruta al directorio temporal
#    - Select-PathDialog      : ui para seleccion de rutas de lectura
#    - Select-SavePathDialog  : ui para guardar nuevos archivos WIM
#  CARGA       : . "$PSScriptRoot\Modulo-EditIndex.ps1"
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
#  FUNCIONES DE ACCION (Edicion de indices)
# =============================================
function Export-Index {
    Clear-Host
    Write-Log -LogLevel INFO -Message "IndexManager: Iniciando modulo de exportacion de indices WIM."

    if (-not $Script:WIM_FILE_PATH) {
        Write-Log -LogLevel INFO -Message "IndexManager: No hay un WIM global cargado. Solicitando archivo origen al usuario."
        $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo WIM de origen" -Filter "Archivos WIM (*.wim)|*.wim|Todos (*.*)|*.*"
        if (-not $path) {
            Write-Log -LogLevel INFO -Message "IndexManager: El usuario cancelo la seleccion del archivo WIM de origen."
            Write-Warning "Operacion cancelada."
            Pause
            return
        }
        $Script:WIM_FILE_PATH = $path
        Write-Log -LogLevel INFO -Message "IndexManager: Archivo WIM de origen seleccionado -> $Script:WIM_FILE_PATH"
    } else {
        Write-Log -LogLevel INFO -Message "IndexManager: Usando archivo WIM global pre-cargado -> $Script:WIM_FILE_PATH"
    }

    $isVhd = ($Script:WIM_FILE_PATH -match '\.vhdx?$')
    if ($isVhd -or $Script:IMAGE_MOUNTED -eq 2) {
        Write-Log -LogLevel WARN -Message "IndexManager: Bloqueo activado. Intento de exportar indices desde un disco virtual."
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Red
        Write-Host "      OPERACION NO PERMITIDA EN DISCOS VIRTUALES       " -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "Has intentado exportar un indice desde un archivo VHD o VHDX." -ForegroundColor White
        Write-Host "EXPLICACION TECNICA:" -ForegroundColor Cyan
        Write-Host "Los discos virtuales usan particiones (bloques), no indices de imagen como los WIM/ESD." -ForegroundColor Gray
        Write-Host "Para extraer Windows de un VHD, usa la opcion 'Convertir VHD/VHDX a WIM' en el menu de Conversion." -ForegroundColor Gray
        Write-Host ""
        Pause
        return
    }

    Write-Host "Archivo WIM actual: $Script:WIM_FILE_PATH" -ForegroundColor Gray
    Write-Log -LogLevel INFO -Message "IndexManager: Consultando a DISM la estructura de indices del archivo origen."
    
    # MENSAJE DE ESPERA AÑADIDO AQUI
    Write-Host "Por favor, espere. DISM esta leyendo la estructura del archivo (Esto puede tardar unos segundos)..." -ForegroundColor Cyan
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"
    
    $INDEX_TO_EXPORT = Read-Host "`nIngrese el numero de Indice que desea exportar"
    # Validar que INDEX_TO_EXPORT sea un numero valido podria añadirse aqui
    Write-Log -LogLevel INFO -Message "IndexManager: Indice objetivo ingresado por el usuario -> [$INDEX_TO_EXPORT]"

    $wimFileObject = Get-Item -Path $Script:WIM_FILE_PATH
    $DEFAULT_DEST_PATH = Join-Path $wimFileObject.DirectoryName "$($wimFileObject.BaseName)_indice_$($INDEX_TO_EXPORT).wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Exportar indice como..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) { 
        Write-Log -LogLevel INFO -Message "IndexManager: El usuario cancelo la seleccion de la ruta de destino."
        Write-Warning "Operacion cancelada."; Pause; return 
    }
    Write-Log -LogLevel INFO -Message "IndexManager: Ruta de destino establecida -> $DEST_WIM_PATH"

    Write-Host "[+] Exportando Indice $INDEX_TO_EXPORT a '$DEST_WIM_PATH'..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "IndexManager: Ejecutando DISM /Export-Image para clonar el Indice $INDEX_TO_EXPORT de '$($Script:WIM_FILE_PATH)' hacia '$DEST_WIM_PATH'."
    
    # MENSAJE DE ESPERA AÑADIDO AQUI
    Write-Host "Por favor, espere. DISM esta iniciando el proceso de exportacion (No cierre la ventana)..." -ForegroundColor Cyan
    dism /export-image /sourceimagefile:"$Script:WIM_FILE_PATH" /sourceindex:$INDEX_TO_EXPORT /destinationimagefile:"$DEST_WIM_PATH" /Compress:max /CheckIntegrity /ScratchDir:"$Script:Scratch_DIR"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Indice exportado exitosamente." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "IndexManager: Exportacion completada exitosamente. El indice $INDEX_TO_EXPORT ha sido extraido a un nuevo archivo."
    } else {
        Write-Host "[ERROR] Fallo al exportar el Indice (Codigo: $LASTEXITCODE)."
        Write-Log -LogLevel ERROR -Message "IndexManager: Fallo la exportacion del indice en DISM. Codigo LASTEXITCODE: $LASTEXITCODE"
    }
    Pause
}

function Delete-Index {
    Clear-Host
    Write-Log -LogLevel INFO -Message "IndexManager: Iniciando modulo de eliminacion de indices WIM."

    if (-not $Script:WIM_FILE_PATH) {
        Write-Log -LogLevel INFO -Message "IndexManager: No hay un WIM global cargado. Solicitando archivo al usuario."
        $path = Select-PathDialog -DialogType File -Title "Seleccione WIM para borrar indice" -Filter "Archivos WIM (*.wim)|*.wim|Todos (*.*)|*.*"
        if (-not $path) { 
            Write-Log -LogLevel INFO -Message "IndexManager: El usuario cancelo la seleccion del archivo WIM."
            Write-Warning "Operacion cancelada."; Pause; return 
        }
        $Script:WIM_FILE_PATH = $path
        Write-Log -LogLevel INFO -Message "IndexManager: Archivo WIM seleccionado -> $Script:WIM_FILE_PATH"
    } else {
        Write-Log -LogLevel INFO -Message "IndexManager: Usando archivo WIM global pre-cargado -> $Script:WIM_FILE_PATH"
    }

    $isVhd = ($Script:WIM_FILE_PATH -match '\.vhdx?$')
    if ($isVhd -or $Script:IMAGE_MOUNTED -eq 2) {
        Write-Log -LogLevel WARN -Message "IndexManager: Bloqueo activado. Intento de eliminar indices en un disco virtual."
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Red
        Write-Host "      OPERACION NO PERMITIDA EN DISCOS VIRTUALES       " -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "Has intentado eliminar un indice de un archivo VHD o VHDX." -ForegroundColor White
        Write-Host "EXPLICACION TECNICA:" -ForegroundColor Cyan
        Write-Host "Los discos virtuales no contienen indices gestionables por DISM." -ForegroundColor Gray
        Write-Host "Si deseas eliminar el sistema operativo o particiones de un VHD, debes montarlo y usar el Administrador de Discos de Windows (diskmgmt.msc)." -ForegroundColor Gray
        Write-Host ""
        Pause
        return
    }

    Write-Host "Archivo WIM actual: $Script:WIM_FILE_PATH" -ForegroundColor Gray
    Write-Log -LogLevel INFO -Message "IndexManager: Consultando a DISM la estructura de indices del archivo."
    
    # MENSAJE DE ESPERA AÑADIDO AQUI
    Write-Host "Por favor, espere. DISM esta leyendo la estructura del archivo (Esto puede tardar unos segundos)..." -ForegroundColor Cyan
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"
    
    $INDEX_TO_DELETE = Read-Host "`nIngrese el numero de Indice que desea eliminar"
    # Validar que INDEX_TO_DELETE sea un numero valido podria añadirse aqui
    Write-Log -LogLevel INFO -Message "IndexManager: Indice objetivo ingresado por el usuario -> [$INDEX_TO_DELETE]"

    $CONFIRM = Read-Host "Esta seguro que desea eliminar el Indice $INDEX_TO_DELETE de forma PERMANENTE? (S/N)"

    if ($CONFIRM -match '^(s|S)$') {
        Write-Host "[+] Eliminando Indice $INDEX_TO_DELETE..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "IndexManager: Ejecutando DISM /Delete-Image para eliminar el Indice $INDEX_TO_DELETE de '$($Script:WIM_FILE_PATH)'."
        
        # MENSAJE DE ESPERA AÑADIDO AQUI
        Write-Host "Por favor, espere. DISM esta procediendo a borrar el indice (La operacion tomara algo de tiempo)..." -ForegroundColor Cyan
        dism /delete-image /imagefile:"$Script:WIM_FILE_PATH" /index:$INDEX_TO_DELETE
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Indice eliminado exitosamente." -ForegroundColor Green
            Write-Log -LogLevel INFO -Message "IndexManager: Eliminacion completada exitosamente. Indice $INDEX_TO_DELETE purgado del WIM."
        } else {
            Write-Host "[ERROR] Error al eliminar el Indice (Codigo: $LASTEXITCODE). Puede que este montado o en uso."
            Write-Log -LogLevel ERROR -Message "IndexManager: Fallo la eliminacion del indice en DISM. Codigo LASTEXITCODE: $LASTEXITCODE. Posible bloqueo de archivo o WIM montado."
        }
    } else {
        Write-Log -LogLevel INFO -Message "IndexManager: El usuario cancelo la eliminacion en la confirmacion de seguridad."
        Write-Warning "Operacion cancelada."
    }
    Pause
}
