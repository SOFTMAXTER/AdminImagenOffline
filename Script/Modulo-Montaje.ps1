# =================================================================
#  Modulo-Montaje
#
#  CONTENIDO   : Select-WindowsMediaSource, Mount-Image, 
#                Unmount-Image, Reload-Image
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen, 1 = WIM, 2 = VHD)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - $Script:WIM_FILE_PATH  : ruta del archivo de imagen base
#    - $Script:MOUNTED_INDEX  : indice WIM montado
#    - Select-PathDialog      : ui para seleccion de rutas
#    - Get-UnusedDriveLetter  : deteccion de unidades libres para VHD
#    - Unmount-Hives          : desmontar colmenas offline del registro
#  CARGA       : . "$PSScriptRoot\Modulo-Montaje.ps1"
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
#  FUNCIONES DE ACCION (Montaje/Desmontaje)
# =============================================
function Select-WindowsMediaSource {
	param(
        [string]$ExtractDir = ""
    )

    Write-Log -LogLevel INFO -Message "SourceSelector: Iniciando seleccion de fuente de medios (Solo ISO)."
    $SelectedPath = $null

    Add-Type -AssemblyName System.Windows.Forms

    # --- 1. SELECCION DE ISO ---
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Archivos ISO (*.iso)|*.iso"
    $ofd.Title = "SELECCIONA TU ISO DE WINDOWS"
    
    if ($ofd.ShowDialog() -ne 'OK') { 
        Write-Log -LogLevel INFO -Message "SourceSelector: Usuario cancelo la seleccion de ISO."
        Write-Warning "Operacion cancelada."
        return $null 
    }
    
    $IsoPath = $ofd.FileName
	Clear-Host
	Write-Host ""
    Write-Host "ISO Seleccionada: $IsoPath" -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "SourceSelector: ISO seleccionada -> $IsoPath"

        if ([string]::IsNullOrWhiteSpace($ExtractDir)) {
            $ExtractDir = Join-Path $parentDir "ISO_Extract"
            Write-Host "`nCarpeta de extraccion por defecto: " -NoNewline; Write-Host $ExtractDir -ForegroundColor Cyan
            
            if ((Read-Host "Deseas elegir una carpeta destino diferente para la extraccion? (S/N)").ToUpper() -eq 'S') {
                $customExtract = Select-PathDialog -DialogType Folder -Title "Selecciona la carpeta destino para extraer la ISO"
                if ($customExtract) { 
                    $ExtractDir = $customExtract 
                    Write-Host "Nueva ruta establecida: $ExtractDir" -ForegroundColor Green
                    Write-Log -LogLevel INFO -Message "SourceSelector: El usuario cambio la ruta de extraccion a -> $ExtractDir"
                } else {
                    Write-Host "Manteneniendo ruta por defecto: $ExtractDir" -ForegroundColor Gray
                }
            }
        }

        # --- 2. AVISO Y LIMPIEZA DE CONTENIDO PREVIO ---
        if (Test-Path $ExtractDir) {

        # Verificamos si realmente hay archivos adentro (para no asustar si la carpeta está vacía)
        $existingFiles = Get-ChildItem -Path $ExtractDir -Force
        
        if ($existingFiles.Count -gt 0) {
            $warnMsg = "Se ha detectado contenido previo en la carpeta de extraccion:`n$ExtractDir`n`nPara evitar que los archivos se mezclen y corrompan la imagen, se ELIMINARA todo el contenido actual de esa carpeta antes de extraer la nueva ISO.`n`nEstas de acuerdo en vaciar la carpeta y continuar?"
            
            $dialogRes = [System.Windows.Forms.MessageBox]::Show($warnMsg, "Advertencia de Limpieza", 'YesNo', 'Warning')
            
            if ($dialogRes -ne 'Yes') {
                Write-Log -LogLevel INFO -Message "SourceSelector: Operacion cancelada por el usuario para no borrar el directorio previo."
                Write-Warning "Extracción cancelada para proteger los archivos existentes."
                return $null
            }
            
            Write-Host "  >> Vaciando directorio de extraccion anterior..." -ForegroundColor DarkGray
            Write-Log -LogLevel ACTION -Message "SourceSelector: Eliminando contenido previo en $ExtractDir."
            # Borramos el contenido, no la carpeta principal
            Remove-Item "$ExtractDir\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        # Si no existe, la creamos
        New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null
    }
    
    # --- 3. MONTAJE Y EXTRACCION ---
    try {
        Write-Host "  >> Montando imagen de disco..." -ForegroundColor Gray
        $mountResult = Mount-DiskImage -ImagePath $IsoPath -PassThru -StorageType ISO
        
        # Pausa tactica de veterano
        Start-Sleep -Seconds 2 
        
        $vol = $mountResult | Get-Volume
        
        if (-not $vol) { throw "No se pudo obtener la letra de la unidad montada." }
        
        $driveRoot = "$($vol.DriveLetter):\" 
        
        Write-Host "  >> Copiando archivos (esto puede tardar varios minutos)..." -ForegroundColor Cyan
        Write-Log -LogLevel ACTION -Message "SourceSelector: Copiando contenido de $driveRoot a $ExtractDir via Robocopy."
        
        $argsRobo = @($driveRoot, $ExtractDir, "/E", "/NFL", "/NDL", "/NJH", "/NJS")
        $proc = Start-Process "robocopy.exe" -ArgumentList $argsRobo -Wait -PassThru -NoNewWindow
        
        if ($proc.ExitCode -ge 8) {
            Write-Log -LogLevel WARN -Message "SourceSelector: Robocopy fallo con exit code $($proc.ExitCode). Usando Copy-Item."
            Write-Warning "Robocopy reporto errores. Intentando metodo alternativo (Copy-Item)..."
            Copy-Item -Path "$driveRoot*" -Destination $ExtractDir -Recurse -Force
        }
        
        Write-Log -LogLevel INFO -Message "SourceSelector: Desmontando ISO."
        Dismount-DiskImage -ImagePath $IsoPath | Out-Null
        $SelectedPath = $ExtractDir
        
    } catch {
        Write-Log -LogLevel ERROR -Message "SourceSelector: Fallo al procesar la ISO - $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Error critico al procesar la ISO:`n$($_.Exception.Message)", "Error ISO", 'OK', 'Error')
        
        try { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null } catch {}
        return $null
    }

    # --- 4. PERMISOS ---
    Write-Host "  >> Normalizando atributos de archivos (Quitando Solo Lectura)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "SourceSelector: Eliminando atributos IsReadOnly en $SelectedPath"
    
    try {
        Get-ChildItem -Path $SelectedPath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.IsReadOnly) { $_.IsReadOnly = $false }
        }
        Write-Host "  [OK] Atributos normalizados." -ForegroundColor Green
    } catch {
        Write-Log -LogLevel WARN -Message "SourceSelector: Advertencia menor al cambiar atributos - $($_.Exception.Message)"
    }

    return $SelectedPath
}

function Mount-Image {
    Clear-Host
    Write-Log -LogLevel INFO -Message "MountManager: Iniciando solicitud de montaje de imagen."

    if ($Script:IMAGE_MOUNTED -eq 1) {
        Write-Log -LogLevel WARN -Message "MountManager: Operacion cancelada. Ya existe una imagen montada en el entorno."
        Write-Warning "La imagen ya se encuentra montada."
        Pause; return
    }

    # =======================================================
    #  NUEVA LÓGICA: SELECCIÓN DE ORIGEN (ISO vs Archivo)
    # =======================================================
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host "               SELECCION DE FUENTE                     " -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host " Que deseas montar?`n"
    Write-Host "   [1] Archivo Individual (.wim, .vhd, .vhdx)"
    Write-Host "   [2] Extraer desde una ISO de Windows" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   [V] Cancelar y Volver" -ForegroundColor Red
    Write-Host ""
    
    $sourceType = Read-Host "Elige una opcion"

    if ($sourceType.ToUpper() -eq 'V') { return }

    if ($sourceType -eq '2') {
        Write-Log -LogLevel INFO -Message "MountManager: Usuario eligio extraer desde ISO/Carpeta."

        # Llamamos a nuestra nueva y robusta función
        $ExtractPath = Select-WindowsMediaSource
        
        if (-not $ExtractPath) { 
            Write-Log -LogLevel INFO -Message "MountManager: Seleccion de fuente cancelada."
            return 
        }

        # Auto-detectar la imagen del sistema operativo
        $wimPath = Join-Path $ExtractPath "sources\install.wim"
        $esdPath = Join-Path $ExtractPath "sources\install.esd"

        if (Test-Path -LiteralPath $wimPath) {
            $Script:WIM_FILE_PATH = $wimPath
            Write-Host "`n[OK] Imagen base detectada: install.wim" -ForegroundColor Green
        } elseif (Test-Path -LiteralPath $esdPath) {
            Clear-Host
            Write-Host "=======================================================" -ForegroundColor Red
            Write-Host "             FORMATO ESD DETECTADO                     " -ForegroundColor Yellow
            Write-Host "=======================================================" -ForegroundColor Red
            Write-Host "La ISO extraida contiene un archivo 'install.esd' (Compresion Solida)." -ForegroundColor White
            Write-Host "DISM no permite montar archivos .esd para realizar ediciones directas." -ForegroundColor Gray
            Write-Host ""
            Write-Host "SOLUCION:" -ForegroundColor Cyan
            Write-Host "Ve al Menu Principal -> [2] Convertir Formatos."
            Write-Host "Selecciona 'Convertir ESD a WIM' y apunta a este archivo:" -ForegroundColor Gray
            Write-Host $esdPath -ForegroundColor Yellow
            Write-Host ""
            Write-Log -LogLevel WARN -Message "MountManager: install.esd detectado. Abortando montaje directo."
            Pause; return
        } else {
            Write-Warning "No se encontro install.wim ni install.esd en la ruta: $ExtractPath\sources"
            Write-Log -LogLevel ERROR -Message "MountManager: No se encontro imagen base en la ISO extraida."
            Pause; return
        }

    } elseif ($sourceType -eq '1') {
        $path = Select-PathDialog -DialogType File -Title "Seleccione la imagen a montar" -Filter "Archivos Soportados (*.wim, *.vhd, *.vhdx)|*.wim;*.vhd;*.vhdx|Todos (*.*)|*.*"
        if ([string]::IsNullOrEmpty($path)) { 
            Write-Log -LogLevel INFO -Message "MountManager: El usuario cancelo el dialogo de seleccion de archivo individual."
            Write-Warning "Operacion cancelada."; Pause; return 
        }
        $Script:WIM_FILE_PATH = $path
    } else {
        Write-Warning "Opción no válida."
        Pause; return
    }
    
    $extension = [System.IO.Path]::GetExtension($Script:WIM_FILE_PATH).ToUpper()
    Write-Log -LogLevel INFO -Message "MountManager: Archivo seleccionado -> $Script:WIM_FILE_PATH | Formato detectado: $extension"

    # =======================================================
    #  MODO VHD / VHDX (CON LA PAUSA TÁCTICA APLICADA)
    # =======================================================
    if ($extension -eq ".VHD" -or $extension -eq ".VHDX") {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host "         MODO DE MONTAJE DE DISCO VIRTUAL (VHD)        " -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host "1. NO se usa la carpeta de montaje temporal."
        Write-Host "2. El VHD se monta como unidad nativa (Letra)."
        Write-Host "3. Los cambios son EN TIEMPO REAL." -ForegroundColor Red
        Write-Host ""
        
        Write-Log -LogLevel INFO -Message "MountManager: Cambiando a motor de virtualizacion (Hyper-V/VHD). Solicitando confirmacion al usuario."
        if ((Read-Host "Escribe 'SI' para adjuntar").ToUpper() -ne 'SI') {
            Write-Log -LogLevel INFO -Message "MountManager: El usuario aborto el montaje del disco virtual en la confirmacion."
            $Script:WIM_FILE_PATH = $null; return
        }

        try {
            Write-Host "[+] Montando VHD..." -ForegroundColor Yellow
            Write-Log -LogLevel ACTION -Message "MountManager: Ejecutando Mount-VHD para adjuntar el disco virtual."
            $vhdInfo = Mount-VHD -Path $Script:WIM_FILE_PATH -PassThru -ErrorAction Stop
            
            # --- CORRECCIÓN: Pausa táctica (Respiración del bus virtual) ---
            Write-Log -LogLevel INFO -Message "MountManager: Esperando 2 segundos para inicializacion logica del disco..."
            Start-Sleep -Seconds 2

            # 1. Escaneo Inteligente de Particiones
            Write-Log -LogLevel INFO -Message "MountManager: Escaneando tabla de particiones del disco virtual montado."
            $targetPart = $null
            $partitions = Get-Partition -DiskNumber $vhdInfo.Number | Where-Object { $_.Size -gt 1GB } # Filtramos EFI/MSR

            foreach ($part in $partitions) {
                # Auto-Asignar letra si falta
                if (-not $part.DriveLetter) {
                    $freeLet = Get-UnusedDriveLetter
                    Write-Log -LogLevel INFO -Message "MountManager: Asignando letra temporal [$freeLet] a particion sin montar."
                    Set-Partition -InputObject $part -NewDriveLetter $freeLet -ErrorAction SilentlyContinue
                    $part.DriveLetter = $freeLet # Actualizamos objeto en memoria
                    
                    # --- CORRECCIÓN: Active Polling (Max 5 segundos) ---
                    $timeout = 50
                    while (-not (Test-Path -LiteralPath "$($freeLet):\") -and $timeout -gt 0) {
                        Start-Sleep -Milliseconds 100
                        $timeout--
                    }
                }
                
                # Verificar si es Windows
                if (Test-Path "$($part.DriveLetter):\Windows\System32\config\SYSTEM") {
                    $targetPart = $part
                    Write-Log -LogLevel INFO -Message "MountManager: Instalacion de Windows detectada automaticamente en particion [$($part.DriveLetter):]."
                    break 
                }
            }

            # 2. Seleccion (Automatica o Manual)
            if ($targetPart) {
                Write-Host "[AUTO] Windows detectado en particion $($targetPart.DriveLetter):" -ForegroundColor Green
                $selectedPart = $targetPart
            } else {
                # Fallback: Menu manual si no detectamos Windows
                Write-Log -LogLevel WARN -Message "MountManager: No se detecto instalacion de Windows. Lanzando seleccion manual de particion."
                Write-Warning "No se detecto una instalacion de Windows obvia."
                Write-Host "Seleccione la particion manualmente:" -ForegroundColor Cyan
                
                $menuItems = @{}
                $i = 1
                $allParts = Get-Partition -DiskNumber $vhdInfo.Number | Where-Object { $_.DriveLetter }
                
                foreach ($p in $allParts) {
                    $gb = [math]::Round($p.Size / 1GB, 2)
                    Write-Host "   [$i] Unidad $($p.DriveLetter): ($gb GB)"
                    $menuItems[$i] = $p
                    $i++
                }
                
                $choice = Read-Host "Numero de particion"
                if ($menuItems[$choice]) { 
                    $selectedPart = $menuItems[$choice] 
                    Write-Log -LogLevel INFO -Message "MountManager: El usuario selecciono manualmente la particion [$($selectedPart.DriveLetter):]."
                } else { 
                    throw "Seleccion invalida." 
                }
            }

            # 3. Configurar Entorno Global
            $driveLetter = "$($selectedPart.DriveLetter):\"
            $Script:MOUNT_DIR = $driveLetter
            $Script:IMAGE_MOUNTED = 2         # Estado 2 = VHD
            $Script:MOUNTED_INDEX = $selectedPart.PartitionNumber
            $Script:CachedControlSet = $null
            
            Write-Host "[OK] VHD Montado en: $Script:MOUNT_DIR" -ForegroundColor Green
            Write-Log -LogLevel INFO -Message "MountManager: VHD Montado y vinculado exitosamente. Entorno local redireccionado a $Script:MOUNT_DIR"

        } catch {
            Write-Host "Error VHD: $_"
            Write-Log -LogLevel ERROR -Message "MountManager: Fallo critico durante montaje/escaneo VHD: $($_.Exception.Message)"
            try { Dismount-VHD -Path $Script:WIM_FILE_PATH -ErrorAction SilentlyContinue } catch {}
            $Script:WIM_FILE_PATH = $null
        }
        Pause; return
    }

    # =======================================================
    #  MODO WIM (DISM)
    # =======================================================
    Write-Host "`n[+] Leyendo estructura del WIM..." -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "MountManager: Consultando a DISM la estructura de indices del archivo WIM."
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH" /English

    $INDEX = Read-Host "`nNumero de indice a montar"
    Write-Log -LogLevel INFO -Message "MountManager: Indice seleccionado por el usuario -> [$INDEX]"
    
    # Limpieza proactiva de carpeta corrupta
    if ((Get-ChildItem $Script:MOUNT_DIR -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        Write-Log -LogLevel WARN -Message "MountManager: Se detectaron archivos residuales en la carpeta de montaje ($Script:MOUNT_DIR)."
        Write-Warning "El directorio de montaje no esta vacio ($Script:MOUNT_DIR)."
        if ((Read-Host "Limpiar carpeta? (S/N)") -match 'S') {
            Write-Log -LogLevel INFO -Message "MountManager: Ejecutando limpieza forzada (DISM /cleanup-wim y eliminacion recursiva) en la carpeta de montaje."
            dism /cleanup-wim
            Remove-Item "$Script:MOUNT_DIR\*" -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log -LogLevel INFO -Message "MountManager: El usuario declino limpiar la carpeta. Continuando asumiendo riesgo de montaje sobre directorio no vacio."
        }
    }

    Write-Host "[+] Montando (Indice: $INDEX)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "MountManager: Ejecutando DISM /Mount-Wim para adjuntar indice $INDEX en $Script:MOUNT_DIR."
    
    dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$INDEX /mountdir:"$Script:MOUNT_DIR"

    if ($LASTEXITCODE -eq 0) {
        $Script:IMAGE_MOUNTED = 1
        $Script:MOUNTED_INDEX = $INDEX
        $Script:CachedControlSet = $null
        Write-Host "[OK] Imagen montada." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "MountManager: Montaje WIM completado exitosamente. Entorno listo para personalizacion."
    } else {
        Write-Host "[ERROR] Fallo montaje (Code: $LASTEXITCODE)."
        if (([uint32]$LASTEXITCODE).ToString("X8") -match "C1420116|C1420117") {
            Write-Warning "Posible bloqueo de archivos. Reinicia o ejecuta Limpieza."
            Write-Log -LogLevel ERROR -Message "MountManager: Fallo montaje WIM. Codigo DISM ($LASTEXITCODE) indica directorio no vacio o error de acceso (C1420116/C1420117)."
        } else {
            Write-Log -LogLevel ERROR -Message "MountManager: Fallo montaje WIM. Code: $LASTEXITCODE"
        }
    }
    Pause
}

function Unmount-Image {
    param([switch]$Commit)
    
    Clear-Host
    $modeText = if ($Commit) { "Commit (Guardar y Desmontar)" } else { "Discard (Descartar Cambios)" }
    Write-Log -LogLevel ACTION -Message "UnmountManager: Solicitud de desmontaje iniciada. Modo: [$modeText]"

    if ($Script:IMAGE_MOUNTED -eq 0) {
        Write-Log -LogLevel WARN -Message "UnmountManager: Operacion rechazada. No hay ninguna imagen montada."
        Write-Warning "No hay ninguna imagen montada."
        Pause; return
    }

    # --- BLOQUEO ESD (Si el usuario intenta Guardar y Desmontar un ESD) ---
    $isEsd = ($Script:WIM_FILE_PATH -match '\.esd$')
    if ($Commit -and $isEsd) {
        Write-Log -LogLevel WARN -Message "UnmountManager: Bloqueo de seguridad activado. Intento de 'Commit' sobre archivo de compresion solida (.ESD)."
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host "      OPERACION NO PERMITIDA EN ARCHIVOS .ESD          " -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host "No puedes hacer 'Guardar y Desmontar' sobre una imagen ESD comprimida." -ForegroundColor Red
        Write-Host "Debes usar la opcion 'Desmontar (Descartar Cambios)' o convertirla a WIM primero." -ForegroundColor Gray
        Pause
        return
    }

    Write-Host "[INFO] Iniciando secuencia de desmontaje segura..." -ForegroundColor Cyan

    # 1. Cierre proactivo de Hives (CRÍTICO)
    Write-Host "   > Descargando hives del registro..." -ForegroundColor Gray
    Write-Log -LogLevel INFO -Message "UnmountManager: Ejecutando Unmount-Hives para liberar bloqueos de registro."
    Unmount-Hives
    
    # 2. Garbage Collection para liberar handles de .NET
    Write-Log -LogLevel INFO -Message "UnmountManager: Forzando recoleccion de basura (.NET GC) para soltar handles residuales."
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()

    # 3. Desmontaje VHD (Logica separada)
    if ($Script:IMAGE_MOUNTED -eq 2) {
        try {
            Write-Host "   > Desmontando disco virtual (VHD)..." -ForegroundColor Yellow
            Write-Log -LogLevel ACTION -Message "UnmountManager: Ejecutando Dismount-VHD para el disco virtual en $Script:WIM_FILE_PATH"
            Dismount-VHD -Path $Script:WIM_FILE_PATH -ErrorAction Stop
            
            if ($Commit) {
                Write-Host "[OK] VHD Desmontado (Los cambios en VHD se guardan automaticamente en tiempo real)." -ForegroundColor Green
            } else {
                Write-Host "[OK] VHD Desmontado." -ForegroundColor Green
            }
            
            $Script:IMAGE_MOUNTED = 0
            $Script:WIM_FILE_PATH = $null
            Load-Config
			$Script:CachedControlSet = $null
			$Script:OfflineUserClassesPresent = $null
			
            Write-Log -LogLevel INFO -Message "UnmountManager: Desmontaje de VHD exitoso. Entorno virtualizado cerrado."
        } catch {
            Write-Log -LogLevel ERROR -Message "UnmountManager: Fallo al desmontar VHD - $($_.Exception.Message)"
            Write-Error "Fallo al desmontar VHD: $_"
            Write-Warning "Cierre cualquier carpeta abierta en la unidad virtual e intente de nuevo."
        }
        Pause; return
    }

    # 4. Bucle de Reintentos para WIM (Resiliencia)
    $maxRetries = 3
    $retry = 0
    $success = $false
    
    # Determinamos los argumentos de DISM en base al parametro $Commit
    $dismArg = if ($Commit) { "/commit" } else { "/discard" }
    $actionText = if ($Commit) { "Guardando y Desmontando (Commit)" } else { "Desmontando (Discard)" }

    Write-Log -LogLevel ACTION -Message "UnmountManager: Iniciando bucle de desmontaje WIM para '$Script:MOUNT_DIR' con parametros: $dismArg"

    while ($retry -lt $maxRetries -and -not $success) {
        $retry++
        Write-Host "   > Intento $retry de $($maxRetries): $actionText WIM..." -ForegroundColor Yellow
        Write-Log -LogLevel INFO -Message "UnmountManager: Ejecutando DISM (Intento $retry de $maxRetries)..."
        
        if ($Commit) {
            Write-Host "   [!] Empaquetando y comprimiendo cambios en el archivo WIM..." -ForegroundColor Cyan
            Write-Host "   [!] DISM tardara varios minutos en iniciar la barra de progreso. Por favor, no interrumpa el proceso..." -ForegroundColor DarkGray
        } else {
            Write-Host "   [!] Revirtiendo estructura de directorios y liberando bloqueos..." -ForegroundColor Cyan
            Write-Host "   [!] Esto tomara unos instantes. Por favor, espere..." -ForegroundColor Gray
        }

        dism /unmount-wim /mountdir:"$Script:MOUNT_DIR" $dismArg
        
        if ($LASTEXITCODE -eq 0) {
            $success = $true
        } else {
            Write-Warning "Fallo la operacion (Codigo: $LASTEXITCODE). Esperando 3 segundos..."
            Write-Log -LogLevel WARN -Message "UnmountManager: Intento $retry fallo con LASTEXITCODE $LASTEXITCODE. Pausando 3 segundos para liberar bloqueos."
            Start-Sleep -Seconds 3
            
            # Intento de limpieza intermedio
            if ($retry -eq 2) {
                Write-Host "   > Intentando limpieza de recursos (cleanup-wim)..." -ForegroundColor Red
                Write-Log -LogLevel WARN -Message "UnmountManager: Ejecutando DISM /cleanup-wim de emergencia antes del ultimo intento."
                dism /cleanup-wim
            }
        }
    }

    if ($success) {
        $Script:IMAGE_MOUNTED = 0
        $Script:WIM_FILE_PATH = $null
        $Script:MOUNTED_INDEX = $null
		$Script:CachedControlSet = $null
        $Script:OfflineUserClassesPresent = $null

		Write-Host "[OK] Imagen desmontada correctamente." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "UnmountManager: Operacion WIM completada exitosamente. Entorno local limpio."
    } else {
        Write-Host "[ERROR FATAL] No se pudo desmontar la imagen." -ForegroundColor Red
        Write-Host "Posibles causas: Antivirus escaneando, carpeta abierta en Explorador o CMD." -ForegroundColor Gray
        Write-Log -LogLevel ERROR -Message "UnmountManager: Fallo critico y definitivo al intentar desmontar el WIM tras $retry intentos. (Ultimo LASTEXITCODE: $LASTEXITCODE)"
    }
    Pause
}

function Reload-Image {
    param([int]$RetryCount = 0)

    Clear-Host
    
    if ($RetryCount -eq 0) {
        Write-Log -LogLevel ACTION -Message "ImageReloader: Solicitud de recarga de imagen (Reload) iniciada."
    }

    # Seguridad anti-bucle: Maximo 3 intentos
    if ($RetryCount -ge 3) {
        Write-Host "[ERROR FATAL] Se ha intentado recargar la imagen 3 veces sin exito."
        Write-Host "Es posible que un archivo este bloqueado por un Antivirus o el Explorador."
        Write-Log -LogLevel ERROR -Message "ImageReloader: Abortado tras 3 intentos fallidos por bloqueos del sistema o antivirus."
        Pause
        return
    }

    if ($Script:IMAGE_MOUNTED -eq 0) { 
        Write-Log -LogLevel WARN -Message "ImageReloader: Operacion rechazada. No hay ninguna imagen montada en el sistema."
        Write-Warning "No hay imagen montada."; Pause; return 
    }
    
    # Asegurar descarga de Hives antes de recargar
    Write-Log -LogLevel INFO -Message "ImageReloader: [Intento $($RetryCount + 1)] Desmontando colmenas de registro residuales..."
    Unmount-Hives 

    Write-Host "Intento de recarga: $($RetryCount + 1)" -ForegroundColor DarkGray
    Write-Host "[+] Desmontando imagen..." -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "ImageReloader: Ejecutando DISM /Unmount-Wim con parametro /Discard..."
    
    dism /unmount-wim /mountdir:"$Script:MOUNT_DIR" /discard

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Error al desmontar. Ejecutando limpieza profunda..."
        Write-Log -LogLevel ERROR -Message "ImageReloader: Fallo el desmontaje (LASTEXITCODE: $LASTEXITCODE). Ejecutando DISM /Cleanup-Wim..."
        
        dism /cleanup-wim
        
        # --- Pausa de seguridad ---
        Write-Host "Esperando 5 segundos para liberar archivos..." -ForegroundColor Cyan
        Write-Log -LogLevel INFO -Message "ImageReloader: Forzando pausa de 5 segundos para liberar handles de archivos del sistema operativo."
        Start-Sleep -Seconds 5 
        
        # Llamada recursiva con contador incrementado
        Write-Log -LogLevel WARN -Message "ImageReloader: Iniciando llamada recursiva de recarga..."
        Reload-Image -RetryCount ($RetryCount + 1) 
        return
    }

    Write-Host "[+] Remontando imagen..." -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "ImageReloader: Imagen desmontada. Ejecutando DISM /Mount-Wim para restaurar el estado original."
    dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$Script:MOUNTED_INDEX /mountdir:"$Script:MOUNT_DIR"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Imagen recargada exitosamente." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "ImageReloader: Recarga completada exitosamente. El entorno esta listo para seguir trabajando."
        $Script:IMAGE_MOUNTED = 1
		$Script:CachedControlSet = $null
    } else {
        Write-Host "[ERROR] Error al remontar la imagen."
        Write-Log -LogLevel ERROR -Message "ImageReloader: Fallo critico al remontar la imagen. El entorno ha quedado desmontado. LASTEXITCODE: $LASTEXITCODE"
        $Script:IMAGE_MOUNTED = 0
    }
    Pause
}