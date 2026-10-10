# =================================================================
#  Modulo-Conversion
#
#  CONTENIDO   : Convert-ESD, Convert-VHD
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:WIM_FILE_PATH  : ruta del archivo de imagen base (se actualiza al convertir)
#    - $Script:Scratch_DIR    : ruta al directorio temporal
#    - Select-PathDialog      : ui para seleccion de rutas de lectura
#    - Select-SavePathDialog  : ui para guardar nuevos archivos WIM
#    - Get-UnusedDriveLetter  : deteccion de unidades libres para VHD
#  CARGA       : . "$PSScriptRoot\Modulo-Conversion.ps1"
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
#  FUNCIONES DE ACCION (Conversion de Imagen)
# =============================================
function Convert-ESD {
    Clear-Host; Write-Host "--- Convertir ESD a WIM ---" -ForegroundColor Yellow

    Write-Log -LogLevel INFO -Message "ConvertESD: Iniciando modulo de conversion y descompresion (ESD -> WIM)."

    $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo ESD a convertir" -Filter "Archivos ESD (*.esd)|*.esd|Todos (*.*)|*.*"
    if (-not $path) {
        Write-Log -LogLevel INFO -Message "ConvertESD: El usuario cancelo la seleccion del archivo de origen."
        Write-Warning "Operacion cancelada."; Pause; return
    }
    $ESD_FILE_PATH = $path
    Write-Log -LogLevel INFO -Message "ConvertESD: Archivo origen seleccionado -> $ESD_FILE_PATH"

    Write-Host "[+] Obteniendo informacion de los indices del ESD..." -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "ConvertESD: Consultando a DISM la estructura de indices del archivo."
    Write-Host "   > Inicializando motor DISM, por favor espere..." -ForegroundColor Cyan

    # /English permite identificar los indices independientemente del idioma de Windows.
    try {
        $imageInfo = @(dism /English /get-wiminfo /wimfile:"$ESD_FILE_PATH" | ForEach-Object {
            Write-Host $_
            $_
        })
        $infoExitCode = $LASTEXITCODE
        if ($infoExitCode -ne 0) {
            throw "DISM no pudo consultar el ESD (Codigo: $infoExitCode)."
        }

        $availableIndices = @($imageInfo | ForEach-Object {
            if ($_ -match '^\s*Index\s*:\s*([0-9]+)\s*$') {
                [int]$Matches[1]
            }
        } | Sort-Object -Unique)
        if ($availableIndices.Count -eq 0) {
            throw "No se encontraron indices validos en el archivo ESD."
        }
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        Write-Log -LogLevel ERROR -Message "ConvertESD: Error al consultar indices - $($_.Exception.Message)"
        Pause; return
    }

    Write-Host "`n--- Seleccion de indices ---" -ForegroundColor Yellow
    Write-Host "Un indice: 2 | Varios: 1,3,5 | Todos: T o TODOS | Cancelar: 0" -ForegroundColor Cyan
    Write-Host "Los indices seleccionados se exportaran a un mismo archivo WIM." -ForegroundColor Gray

    while ($true) {
        $selection = (Read-Host "Ingrese los indices separados por comas, T para todos o 0 para cancelar").Trim()
        if ($selection -eq '0') {
            Write-Log -LogLevel INFO -Message "ConvertESD: El usuario cancelo la seleccion de indices."
            Write-Warning "Operacion cancelada."; Pause; return
        }

        $selectAll = $selection -match '^(T|TODO|TODOS|ALL|\*)$'
        if ($selectAll) {
            $INDICES_TO_CONVERT = @($availableIndices)
            break
        }
        if ($selection -notmatch '^[0-9]+(?:\s*,\s*[0-9]+)*$') {
            Write-Warning "Entrada no valida. Use un indice, una lista como 1,3,5 o T para todos."
            continue
        }

        $selectedIndices = New-Object 'System.Collections.Generic.List[int]'
        $invalidTokens = New-Object 'System.Collections.Generic.List[string]'
        foreach ($token in ($selection -split ',')) {
            $index = 0
            if (-not [int]::TryParse($token.Trim(), [ref]$index) -or $availableIndices -notcontains $index) {
                $invalidTokens.Add($token.Trim())
                continue
            }
            # Evitar exportaciones repetidas y conservar el orden ingresado.
            if (-not $selectedIndices.Contains($index)) { $selectedIndices.Add($index) }
        }
        if ($invalidTokens.Count -gt 0) {
            Write-Warning "Indices no disponibles: $($invalidTokens -join ', '). Disponibles: $($availableIndices -join ', ')."
            continue
        }

        $INDICES_TO_CONVERT = @($selectedIndices.ToArray())
        break
    }

    $indicesText = $INDICES_TO_CONVERT -join ', '
    Write-Host "`nIndices seleccionados: $indicesText (Total: $($INDICES_TO_CONVERT.Count))" -ForegroundColor Cyan
    Write-Log -LogLevel INFO -Message "ConvertESD: Indices seleccionados -> [$indicesText]"

    $esdFileObject = Get-Item -LiteralPath $ESD_FILE_PATH
    if ($selectAll) {
        $destinationSuffix = 'todos'
    } elseif ($INDICES_TO_CONVERT.Count -eq 1) {
        $destinationSuffix = "indice_$($INDICES_TO_CONVERT[0])"
    } else {
        $destinationSuffix = "indices_$($INDICES_TO_CONVERT -join '_')"
    }
    $DEFAULT_DEST_PATH = Join-Path $esdFileObject.DirectoryName "$($esdFileObject.BaseName)_$destinationSuffix.wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Convertir ESD a WIM..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) {
        Write-Log -LogLevel INFO -Message "ConvertESD: El usuario cancelo la seleccion de la ruta de destino."
        Write-Warning "Operacion cancelada."; Pause; return
    }
    if ([System.IO.Path]::GetFullPath($DEST_WIM_PATH) -eq [System.IO.Path]::GetFullPath($ESD_FILE_PATH)) {
        Write-Warning "El archivo de destino debe ser diferente del archivo de origen."
        Write-Log -LogLevel WARN -Message "ConvertESD: La ruta de destino coincide con el origen. Operacion cancelada."
        Pause; return
    }
    Write-Log -LogLevel INFO -Message "ConvertESD: Ruta de destino establecida -> $DEST_WIM_PATH"

    if (Test-Path -LiteralPath $DEST_WIM_PATH) {
        Write-Warning "El WIM de destino ya existe. Los indices seleccionados se agregaran a los que ya contiene."
    } else {
        Write-Host "Los indices del nuevo WIM se numeraran desde 1, en el orden seleccionado." -ForegroundColor Gray
    }

    Write-Host "[+] Convirtiendo... Esto puede tardar varios minutos." -ForegroundColor Yellow
    $completedIndices = New-Object 'System.Collections.Generic.List[int]'
    $conversionError = $null

    foreach ($INDEX_TO_CONVERT in $INDICES_TO_CONVERT) {
        $position = $completedIndices.Count + 1
        Write-Host "`n[ $position / $($INDICES_TO_CONVERT.Count) ] Exportando indice $INDEX_TO_CONVERT..." -ForegroundColor Cyan
        Write-Log -LogLevel ACTION -Message "ConvertESD: Exportando indice $INDEX_TO_CONVERT ($position de $($INDICES_TO_CONVERT.Count)) de '$ESD_FILE_PATH' hacia '$DEST_WIM_PATH'."

        try {
            # La primera exportacion crea el WIM; las siguientes agregan imagenes al mismo archivo.
            $dismArguments = @(
                '/export-image'
                "/SourceImageFile:$ESD_FILE_PATH"
                "/SourceIndex:$INDEX_TO_CONVERT"
                "/DestinationImageFile:$DEST_WIM_PATH"
                '/CheckIntegrity'
                "/ScratchDir:$Script:Scratch_DIR"
            )
            # DISM solo permite elegir la compresion al crear el WIM de destino.
            if (-not (Test-Path -LiteralPath $DEST_WIM_PATH)) { $dismArguments += '/Compress:max' }
            dism @dismArguments
            $exportExitCode = $LASTEXITCODE
            if ($exportExitCode -ne 0) {
                throw "Fallo la conversion del indice $INDEX_TO_CONVERT (Codigo: $exportExitCode)."
            }
            $completedIndices.Add($INDEX_TO_CONVERT)
            Write-Log -LogLevel INFO -Message "ConvertESD: Indice $INDEX_TO_CONVERT exportado correctamente."
        } catch {
            $conversionError = $_.Exception.Message
            Write-Log -LogLevel ERROR -Message "ConvertESD: $conversionError Completados: $($completedIndices.Count) de $($INDICES_TO_CONVERT.Count)."
            break
        }
    }

    if (-not $conversionError) {
        Write-Host "`n[OK] Conversion completada: $($completedIndices.Count) indice(s) exportado(s)." -ForegroundColor Green
        Write-Host "Archivo WIM de destino: `"$DEST_WIM_PATH`"" -ForegroundColor Gray
        $Script:WIM_FILE_PATH = $DEST_WIM_PATH
        Write-Host "La ruta del WIM ha sido cargada en el script." -ForegroundColor Cyan
        Write-Log -LogLevel INFO -Message "ConvertESD: Conversion completa de los indices [$indicesText]. Variable global del WIM actualizada a la nueva ruta."
    } else {
        Write-Host "`n[ERROR] $conversionError" -ForegroundColor Red
        Write-Host "Conversion detenida. Completados: $($completedIndices.Count) de $($INDICES_TO_CONVERT.Count)." -ForegroundColor Yellow
        if ($completedIndices.Count -gt 0) {
            Write-Host "Indices de origen exportados: $($completedIndices -join ', ')." -ForegroundColor Gray
        }
        if (Test-Path -LiteralPath $DEST_WIM_PATH) {
            Write-Warning "El archivo '$DEST_WIM_PATH' puede contener una conversion parcial. Reviselo antes de reutilizarlo."
        }
        Write-Host "La ruta del WIM activo no se ha cambiado." -ForegroundColor Gray
    }
    Pause
}

function Convert-VHD {
    Clear-Host
    Write-Host "--- Convertir VHD/VHDX a WIM (Auto-Mount) ---" -ForegroundColor Yellow
    
    Write-Log -LogLevel INFO -Message "ConvertVHD: Iniciando modulo de conversion inteligente de VHD/VHDX a WIM."

    # 1. Verificar modulo Hyper-V
    if (-not (Get-Command "Mount-Vhd" -ErrorAction SilentlyContinue)) {
        Write-Log -LogLevel ERROR -Message "ConvertVHD: Faltan dependencias. El cmdlet 'Mount-Vhd' no esta disponible."
        Write-Host "[ERROR] El cmdlet 'Mount-Vhd' no esta disponible en el sistema actual." -ForegroundColor Red
        Write-Host "Necesitas habilitar las herramientas de gestion de discos virtuales de Hyper-V." -ForegroundColor Gray
        Write-Host ""
        Write-Host "Para solucionarlo, abre una consola PowerShell como Administrador y ejecuta:" -ForegroundColor Yellow
        Write-Host "Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell" -ForegroundColor Cyan
        Write-Host ""
        Pause; return
    }

    # 2. Seleccion de Archivo
    $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo VHD o VHDX a convertir" -Filter "Archivos VHD (*.vhd, *.vhdx)|*.vhd;*.vhdx|Todos (*.*)|*.*"
    if (-not $path) { 
        Write-Log -LogLevel INFO -Message "ConvertVHD: El usuario cancelo la seleccion del archivo de origen."
        Write-Warning "Operacion cancelada."; Pause; return 
    }
    $VHD_FILE_PATH = $path
    Write-Log -LogLevel INFO -Message "ConvertVHD: Archivo origen seleccionado -> $VHD_FILE_PATH"

    # 3. Seleccion de Destino
    $vhdFileObject = Get-Item -Path $VHD_FILE_PATH
    $DEFAULT_DEST_PATH = Join-Path $vhdFileObject.DirectoryName "$($vhdFileObject.BaseName).wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Capturar VHD como WIM..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) { 
        Write-Log -LogLevel INFO -Message "ConvertVHD: El usuario cancelo la seleccion del archivo de destino."
        Write-Warning "Operacion cancelada."; Pause; return 
    }
    Write-Log -LogLevel INFO -Message "ConvertVHD: Archivo destino establecido -> $DEST_WIM_PATH"

    # 4. Proceso de Montaje y Captura
    Write-Host "`n[+] Montando y analizando estructura del VHD..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "ConvertVHD: Iniciando proceso de montaje y analisis de particiones."

    $DRIVE_LETTER = $null
    $mountedDisk = $null

    try {
        # A. Montar VHD
        $mountedDisk = Mount-Vhd -Path $VHD_FILE_PATH -NoDriveLetter -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2

        # B. Obtener particiones y encontrar Windows
        $partitions = Get-Partition -DiskNumber $mountedDisk.Number | Where-Object { 
            $_.Type -notin @('System', 'Reserved', 'Recovery') -and 
            $_.IsHidden -eq $false -and
            $_.Size -gt 500MB 
        }

        foreach ($part in $partitions) {
            $currentLet = $part.DriveLetter
            $assignedTemp = $false
            
            if (-not $currentLet) {
                try {
                    $freeLet = Get-UnusedDriveLetter
                    Write-Host "   > Inspeccionando particion sin letra. Asignando $freeLet`: temporalmente..." -ForegroundColor Gray
                    Set-Partition -InputObject $part -NewDriveLetter $freeLet -ErrorAction Stop
                    $currentLet = $freeLet
                    $assignedTemp = $true
                    
                    $timeout = 50
                    while (-not (Test-Path -LiteralPath "$($freeLet):\") -and $timeout -gt 0) { Start-Sleep -Milliseconds 100; $timeout-- }
                } catch { continue }
            }

            if ($currentLet) {
                $winPath = "$currentLet`:\Windows\System32\config\SYSTEM"
                if (Test-Path -LiteralPath $winPath) {
                    $DRIVE_LETTER = $currentLet
                    Write-Host "   [OK] Windows detectado en particion $DRIVE_LETTER`:" -ForegroundColor Green
                    break 
                } else {
                    Write-Host "   [-] Particion $currentLet`: no contiene Windows. Ignorando." -ForegroundColor Gray
                    if ($assignedTemp) { Remove-PartitionAccessPath -InputObject $part -AccessPath "$currentLet`:" -ErrorAction SilentlyContinue }
                }
            }
        }

        if (-not $DRIVE_LETTER) {
            throw "No se encontro ninguna instalacion de Windows valida en el VHD. Asegurese de que la imagen no esta cifrada con BitLocker."
        }

        # =========================================================
        #  Auto-Detección de Edición y Petición de Metadatos (ACTUALIZADO CON CATÁLOGO)
        # =========================================================
        Write-Host "`n--- Obteniendo metadatos del sistema operativo ---" -ForegroundColor Yellow
        $defaultName = "Captured VHD"
        $defaultDesc = "Imagen capturada desde VHD el $(Get-Date -Format 'yyyy-MM-dd')"
        $softwareHive = "$DRIVE_LETTER`:\Windows\System32\config\SOFTWARE"

        if (Test-Path -LiteralPath $softwareHive) {
            $tempHive = "HKLM\TempVhdSoft_$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
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
                Write-Log -LogLevel WARN -Message "ConvertVHD: No se pudo auto-detectar la edicion en el registro offline."
            } finally {
                reg unload $tempHive 2>$null | Out-Null
                [GC]::Collect()
            }
        }

        Write-Host "`n--- Ingrese los metadatos para la nueva imagen WIM ---" -ForegroundColor Yellow
        $inputName = Read-Host "Ingrese el NOMBRE de la imagen (Enter = '$defaultName')"
        $inputDesc = Read-Host "Ingrese la DESCRIPCION (Enter = Auto-generada)"
        
        if ([string]::IsNullOrWhiteSpace($inputName)) { $IMAGE_NAME = $defaultName } else { $IMAGE_NAME = $inputName }
        if ([string]::IsNullOrWhiteSpace($inputDesc)) { $IMAGE_DESC = $defaultDesc } else { $IMAGE_DESC = $inputDesc }

        Write-Log -LogLevel INFO -Message "ConvertVHD: Metadatos -> Nombre: [$IMAGE_NAME] | Desc: [$IMAGE_DESC]"

        Write-Host "`n   > Optimizando volumen antes de la captura (Trim)..." -ForegroundColor Gray
        try { Optimize-Volume -DriveLetter $DRIVE_LETTER -ReTrim -ErrorAction Stop | Out-Null } catch {}
        
        # 5. Captura (DISM)
        Write-Host "`n[+] Capturando volumen $DRIVE_LETTER`: a WIM..." -ForegroundColor Yellow
        Write-Host "   > Inicializando motor DISM, por favor espere..." -ForegroundColor Cyan
        
        dism /capture-image /imagefile:"$DEST_WIM_PATH" /capturedir:"$DRIVE_LETTER`:\" /name:"$IMAGE_NAME" /description:"$IMAGE_DESC" /compress:max /checkintegrity /ScratchDir:"$Script:Scratch_DIR"

        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Captura completada exitosamente." -ForegroundColor Green
            $Script:WIM_FILE_PATH = $DEST_WIM_PATH
        } else {
            Write-Host "[ERROR] Fallo DISM (Codigo: $LASTEXITCODE)."
            Write-Log -LogLevel ERROR -Message "ConvertVHD: DISM fallo con LASTEXITCODE: $LASTEXITCODE"
        }

    } catch {
        Write-Host "Error critico durante la conversion: $($_.Exception.Message)"
        Write-Log -LogLevel ERROR -Message "ConvertVHD: Excepcion critica durante la conversion - $($_.Exception.Message)"
    } finally {
        # 6. Limpieza Final (Importante)
        if ($mountedDisk) {
            Write-Host "[+] Desmontando VHD..." -ForegroundColor Yellow
            Dismount-Vhd -Path $VHD_FILE_PATH -ErrorAction SilentlyContinue
        }
        Pause
    }
}