# =================================================================
#  Modulo-Entornos
#
#  CONTENIDO   : Manage-WinRE-Menu, Manage-BootWim-Menu
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen, 1 = WIM, 2 = VHD)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - $Script:WIM_FILE_PATH  : ruta del archivo de imagen base
#    - $Script:MOUNTED_INDEX  : indice WIM montado
#    - $Script:Scratch_DIR    : ruta al directorio temporal
#    - Mount-Hives            : montar colmenas offline del registro
#    - Unmount-Hives          : desmontar colmenas offline del registro
#    - Enable-Privileges      : habilitar privilegios de token
#    - Unlock-Single-File     : romper bloqueos de TrustedInstaller en archivos
#    - Restore-FileOwner      : restaurar SDDL original de archivos
#    - Select-PathDialog      : ui para seleccion de rutas
#    - Initialize-ScratchSpace: limpiar y preparar espacio temporal
#    - Unmount-Image          : logica base para desmontar imagenes
#    - Show-Addons-GUI        : invocacion del inyector de addons
#    - Show-Drivers-GUI       : invocacion del inyector de drivers
#  CARGA       : . "$PSScriptRoot\Modulo-Environments.ps1"
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
#  Modulo Avanzado: Gestor de Entorno de RecuperaciOn (WinRE)
# =================================================================
function Manage-WinRE-Menu {
    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host "       Gestor Avanzado de Entorno de Recuperacion      " -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan
    
    Write-Log -LogLevel INFO -Message "WinRE_Manager: Iniciando el modulo de gestion de Entorno de Recuperacion."

    # Acepta tanto WIM (1) como VHD/VHDX (2)
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        Write-Warning "Debes montar una imagen de sistema (install.wim o VHD/VHDX) primero."
        Write-Log -LogLevel WARN -Message "WinRE_Manager: Intento de acceso denegado. No hay imagen montada."
        Pause; return 
    }

    # Ruta estandar donde se esconde WinRE dentro del sistema (WIM o VHD)
    $winrePath = Join-Path $Script:MOUNT_DIR "Windows\System32\Recovery\winre.wim"
    
    if (-not (Test-Path -LiteralPath $winrePath)) {
        Write-Warning "No se encontro 'winre.wim' en la ruta habitual."
        Write-Host "Es posible que la imagen montada sea un boot.wim o que el WinRE ya haya sido eliminado." -ForegroundColor Gray
        Write-Log -LogLevel WARN -Message "WinRE_Manager: No se encontro winre.wim en la ruta esperada ($winrePath)."
        Pause; return
    }

    Write-Host "`n[1/5] Preparando entorno de trabajo temporal..." -ForegroundColor Yellow
    $winreStaging = Join-Path $Script:Scratch_DIR "WinRE_Staging"
    $winreMount = Join-Path $Script:Scratch_DIR "WinRE_Mount"

    Write-Log -LogLevel INFO -Message "WinRE_Manager: Limpiando y creando directorios temporales de trabajo (Staging/Mount)."
    # Limpieza previa por si quedo basura de un intento anterior
    if (Test-Path $winreMount) { dism /unmount-image /mountdir:"$winreMount" /discard 2>$null | Out-Null }
    if (Test-Path $winreStaging) { Remove-Item $winreStaging -Recurse -Force -ErrorAction SilentlyContinue }
    
    New-Item -Path $winreStaging -ItemType Directory -Force | Out-Null
    New-Item -Path $winreMount -ItemType Directory -Force | Out-Null

    Write-Host "[2/5] Extrayendo winre.wim de la imagen principal..." -ForegroundColor Yellow
    
    # --- CAPTURA DE SEGURIDAD Y DESBLOQUEO ARQUITECTÓNICO ---
    # Respaldamos atributos nativos (Hidden, System) antes del desbloqueo
    $winreFile = Get-Item -LiteralPath $winrePath -Force
    $originalAttributes = $winreFile.Attributes
    
    Write-Log -LogLevel ACTION -Message "WinRE_Manager: Rompiendo candados de TrustedInstaller vía Unlock-Single-File..."
    Unlock-Single-File -FilePath $winrePath

    # Copiamos a Staging ya desbloqueado
    $tempWinrePath = Join-Path $winreStaging "winre.wim"
    Copy-Item -LiteralPath $winrePath -Destination $tempWinrePath -Force

    Write-Host "[3/5] Montando winre.wim (Esto puede tardar unos segundos)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "WinRE_Manager: Montando winre.wim temporal via DISM..."
    dism /mount-image /imagefile:"$tempWinrePath" /index:1 /mountdir:"$winreMount"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] No se pudo montar winre.wim. Abortando..." -ForegroundColor Red
        Write-Log -LogLevel ERROR -Message "WinRE_Manager: Fallo critico al montar winre.wim. Codigo DISM: $LASTEXITCODE"
        
        Write-Log -LogLevel INFO -Message "WinRE_Manager: Ejecutando limpieza de emergencia (discard) especificamente en $winreMount."
        dism /unmount-image /mountdir:"$winreMount" /discard 2>$null | Out-Null
        Pause; return
    }

    Write-Host "[OK] WinRE Montado Exitosamente." -ForegroundColor Green
    Write-Log -LogLevel INFO -Message "WinRE_Manager: Montaje exitoso. Desviando variable global MOUNT_DIR hacia el entorno WinRE."
    Start-Sleep -Seconds 2

    Unmount-Hives | Out-Null

    $originalMountDir = $Script:MOUNT_DIR
    $Script:MOUNT_DIR = $winreMount

    try {
        # --- MINI-MENU DE EDICION WINRE ---
        $doneEditing = $false
        while (-not $doneEditing) {
            Clear-Host
            Write-Host "=======================================================" -ForegroundColor Magenta
            Write-Host "          MODO DE EDICION EN WINRE ACTIVO              " -ForegroundColor Magenta
            Write-Host "=======================================================" -ForegroundColor Magenta
            Write-Host "El entorno de recuperacion esta montado y listo."
            Write-Host "Puedes inyectar Addons (DaRT) y Drivers (VMD/RAID/Red)."
            Write-Host ""
            Write-Host "   [1] Inyectar Addons (.tpk, .bpk, .reg,)"
            Write-Host "   [2] Inyectar Drivers (.inf)" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "   [T] Terminar edicion y proceder a Guardar" -ForegroundColor Green
            Write-Host ""
            
            $opcionRE = Read-Host " Elige una opcion"
            switch ($opcionRE.ToUpper()) {
                "1" { Write-Log -LogLevel INFO -Message "WinRE_Manager: Lanzando modulo de Addons."; Show-Addons-GUI }
                "2" { Write-Log -LogLevel INFO -Message "WinRE_Manager: Lanzando modulo de Drivers."; Show-Drivers-GUI }
                "T" { $doneEditing = $true; Write-Log -LogLevel INFO -Message "WinRE_Manager: El usuario termino la edicion interactiva." }
                default { Write-Warning "Opcion invalida."; Start-Sleep 1 }
            }
        }

        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "              GUARDAR Y REINYECTAR WINRE               " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        $guardar = Read-Host "Deseas GUARDAR los cambios y devolver el winre.wim a la imagen principal? (S/N)"

        Write-Host "`n[4/5] Desmontando winre.wim..." -ForegroundColor Yellow
        if ($guardar.ToUpper() -eq 'S') {
            Write-Log -LogLevel ACTION -Message "WinRE_Manager: Iniciando proceso de guardado (Commit) de winre.wim..."
            dism /unmount-image /mountdir:"$winreMount" /commit

            if ($LASTEXITCODE -eq 0) {
                Write-Host "[5/5] Reinyectando winre.wim..." -ForegroundColor Yellow
                Enable-Privileges

                # GUARDIA DE TIMING: DISM puede mantener handle exclusivo sobre $tempWinrePath
                # varios segundos tras el commit. Export-Image o Copy-Item que lean el archivo
                # antes de la liberacion fallan silenciosamente -> winre.wim vacio o ausente.
                Write-Host " -> Esperando liberacion de handle de DISM..." -ForegroundColor DarkGray
                $lockLimit = 15; $lockWait = 0
                while ($lockWait -lt $lockLimit) {
                    try {
                        $fs = [System.IO.File]::Open($tempWinrePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                        $fs.Close(); $fs.Dispose()
                        break
                    } catch { Start-Sleep -Seconds 1; $lockWait++ }
                }
                if ($lockWait -eq $lockLimit) {
                    Write-Log -LogLevel WARN -Message "WinRE_Manager: Timeout esperando liberacion de $tempWinrePath. Continuando sin garantia."
                    Write-Host " -> [WARN] Timeout de handle. Continuando de todas formas." -ForegroundColor Yellow
                }

                # Reconstruccion de diccionario WIM con flag /Bootable
                Write-Host " -> Ejecutando reconstruccion de diccionario WIM (Tardara unos minutos)..." -ForegroundColor Cyan
                Write-Log -LogLevel ACTION -Message "WinRE_Manager: Ejecutando Export-Image con flag /Bootable para reconstruir el diccionario WIM."

                $optimizedWinrePath = Join-Path $winreStaging "winre_optimized.wim"
                $dismArgs = "/Export-Image /SourceImageFile:`"$tempWinrePath`" /SourceIndex:1 /DestinationImageFile:`"$optimizedWinrePath`" /Bootable"
                $proc = Start-Process "dism.exe" -ArgumentList $dismArgs -Wait -NoNewWindow -PassThru

                # Fallback blindado: si Export falla, NO se deja winrePath vacio.
                # Se usa $tempWinrePath (commit exitoso) como fuente de rescate.
                $finalSource = if ($proc.ExitCode -eq 0 -and (Test-Path $optimizedWinrePath)) {
                    Write-Log -LogLevel INFO -Message "WinRE_Manager: Export-Image exitoso. Usando WIM optimizado como fuente final."
                    $optimizedWinrePath
                } else {
                    Write-Log -LogLevel WARN -Message "WinRE_Manager: Export-Image fallo (Code: $($proc.ExitCode)). Fallback a WIM de commit directo."
                    Write-Host " -> Export-Image fallo. Usando WIM de commit como fallback." -ForegroundColor Yellow
                    $tempWinrePath
                }

                Remove-Item -LiteralPath $winrePath -Force -ErrorAction SilentlyContinue
                Copy-Item -LiteralPath $finalSource -Destination $winrePath -Force

                if (Test-Path -LiteralPath $winrePath) {
                    $sizeAfter = (Get-Item -LiteralPath $winrePath).Length
                    $finalMB = [math]::Round($sizeAfter / 1MB, 2)
                    Write-Host "[EXITO] WinRE guardado e integrado correctamente." -ForegroundColor Green
                    Write-Host "        Size final: $finalMB MB." -ForegroundColor DarkGreen
                    Write-Log -LogLevel INFO -Message "WinRE_Manager: Reinyeccion exitosa. Size final: $finalMB MB."
                } else {
                    Write-Host "[ERROR] winre.wim ausente tras reinyeccion. Revisa el log." -ForegroundColor Red
                    Write-Log -LogLevel ERROR -Message "WinRE_Manager: Copy-Item fallo o fuente invalida. winre.wim ausente en destino."
                }
            } else {
                Write-Host "[ERROR] Fallo al guardar winre.wim. La imagen principal no fue modificada." -ForegroundColor Red
                Write-Log -LogLevel ERROR -Message "WinRE_Manager: DISM fallo al hacer commit. Codigo de salida: $LASTEXITCODE"
            }
        } else {
            Write-Log -LogLevel INFO -Message "WinRE_Manager: El usuario eligio descartar los cambios (Discard)."
            dism /unmount-image /mountdir:"$winreMount" /discard
            Write-Host "Cambios descartados. La imagen principal no fue modificada." -ForegroundColor Gray
        }
    } finally {
        # --- RESTAURAR EL ESTADO GLOBAL (CRÍTICO) ---
        Write-Log -LogLevel INFO -Message "WinRE_Manager: Restaurando variable global MOUNT_DIR, permisos y atributos..."
        $Script:MOUNT_DIR = $originalMountDir
        
        # FIX: Restaurar SIEMPRE el SDDL original y los atributos (Hidden, System), 
        # sin importar la ruta tomada (Éxito, Error, Cancelación o Excepción).
        if (Test-Path -LiteralPath $winrePath) {
            Restore-FileOwner -FilePath $winrePath
            
            $restoredFile = Get-Item -LiteralPath $winrePath -Force
            $restoredFile.Attributes = $originalAttributes
            Write-Log -LogLevel INFO -Message "WinRE_Manager: winre.wim devuelto a su estado nativo y protegido."
        }
        
        # Limpieza de basura temporal
        Write-Log -LogLevel INFO -Message "WinRE_Manager: Limpiando directorios de Staging y Mount."
        Remove-Item $winreStaging -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $winreMount -Recurse -Force -ErrorAction SilentlyContinue
    }
    Pause
}

function Manage-BootWim-Menu {
    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host "        Gestor Inteligente de Arranque (boot.wim)      " -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan

    Write-Log -LogLevel INFO -Message "BootWimManager: Iniciando modulo de gestion de arranque (boot.wim)."

    # 1. Seguridad: Verificar que no haya nada montado
    if ($Script:IMAGE_MOUNTED -ne 0) {
        Write-Log -LogLevel WARN -Message "BootWimManager: Acceso bloqueado. Ya existe una imagen montada en $Script:MOUNT_DIR."
        Write-Warning "Ya tienes una imagen montada ($Script:MOUNT_DIR)."
        Write-Host "Debes desmontarla antes de editar el boot.wim para evitar conflictos." -ForegroundColor Gray
        Pause; return
    }

    # 2. Seleccionar archivo
    Write-Host "Selecciona tu archivo 'boot.wim'..." -ForegroundColor Yellow
    $bootPath = Select-PathDialog -DialogType File -Title "Selecciona boot.wim" -Filter "Archivos WIM|*.wim"
    if (-not $bootPath) { 
        Write-Log -LogLevel INFO -Message "BootWimManager: El usuario cancelo la seleccion del archivo boot.wim."
        return 
    }

    Write-Log -LogLevel INFO -Message "BootWimManager: Archivo seleccionado -> $bootPath"

    # 3. Analizar Indices
    Write-Host "Analizando estructura del boot.wim..." -ForegroundColor DarkGray
    try {
        $images = Get-WindowsImage -ImagePath $bootPath
    } catch {
        Write-Log -LogLevel ERROR -Message "BootWimManager: Fallo al leer la estructura de indices del WIM. Probable corrupcion. - $($_.Exception.Message)"
        Write-Warning "Error leyendo el WIM. Esta corrupto?"
        Pause; return
    }

    Write-Host "`nIndices detectados:" -ForegroundColor Cyan
    $idxSetup = $null
    $idxPE = $null

    foreach ($img in $images) {
        $desc = "Generico"
        # Heuristica para identificar que es cada indice
        if ($img.ImageName -match "Setup|Installation|Instalar") { 
            $desc = "Instalador de Windows (Setup)"; $idxSetup = $img.ImageIndex 
        }
        elseif ($img.ImageName -match "PE|Preinstallation") { 
            $desc = "Windows PE (Rescate/Live)"; $idxPE = $img.ImageIndex 
        }
        
        Write-Log -LogLevel INFO -Message "BootWimManager: Indice detectado [$($img.ImageIndex)] $($img.ImageName) -> $desc"
        Write-Host "   [$($img.ImageIndex)] $($img.ImageName)" -NoNewline
        Write-Host " --> $desc" -ForegroundColor Yellow
    }
    Write-Host ""

    # 4. Seleccion Inteligente
    Write-Host "======================================================="
    Write-Host "Donde quieres inyectar DaRT/Addons?"
    Write-Host "   [1] En Windows PE (Indice $idxPE)" -ForegroundColor White
    Write-Host "       (Para crear un USB booteable exclusivo de diagnostico)" -ForegroundColor Gray
    Write-Host ""
	Write-Host "   [2] En el Instalador (Indice $idxSetup)" -ForegroundColor White
    Write-Host "       (Aparecera al pulsar 'Reparar el equipo' durante la instalacion)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "   [M] Seleccion Manual (Si la deteccion fallo)" -ForegroundColor DarkGray
    
    $sel = Read-Host "Selecciona una opcion"
    $targetIndex = $null

    switch ($sel) {
        "1" { $targetIndex = $idxPE }
        "2" { $targetIndex = $idxSetup }
        "M" { $targetIndex = Read-Host "Introduce el numero de Indice manualmente" }
    }

    if (-not $targetIndex -or $targetIndex -eq "") { 
        Write-Log -LogLevel WARN -Message "BootWimManager: Seleccion de indice invalida o vacia."
        Write-Warning "Seleccion invalida."; Pause; return 
    }

    Write-Log -LogLevel INFO -Message "BootWimManager: Indice objetivo fijado en -> [$targetIndex]"

    # 5. Proceso de Montaje y Edicion
    try {
        # Configuramos las variables globales para engañar al resto del script
        $Script:WIM_FILE_PATH = $bootPath
        $Script:MOUNTED_INDEX = $targetIndex
        $Script:IMAGE_MOUNTED = 1 # Flag virtual activado
        
        # Limpieza previa
        Initialize-ScratchSpace

        # Montaje Real
        Write-Log -LogLevel ACTION -Message "BootWimManager: Iniciando montaje del boot.wim (Indice: $targetIndex)..."
        Write-Host "`n[+] Montando boot.wim (Indice $targetIndex)..." -ForegroundColor Yellow
        dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$Script:MOUNTED_INDEX /mountdir:"$Script:MOUNT_DIR"

        if ($LASTEXITCODE -eq 0) {
            Write-Log -LogLevel INFO -Message "BootWimManager: Montaje exitoso. Desplegando menu de edicion en vivo."
            # --- MINI-MENU DE EDICION BOOT.WIM ---
            $doneEditingBoot = $false
            while (-not $doneEditingBoot) {
                Clear-Host
                Write-Host "=======================================================" -ForegroundColor Magenta
                Write-Host "             MODO EDICION BOOT.WIM ACTIVO              " -ForegroundColor Magenta
                Write-Host "=======================================================" -ForegroundColor Magenta
                Write-Host "Imagen montada en: $Script:MOUNT_DIR"
                Write-Host ""
                Write-Host "   [1] Inyectar Addons y Paquetes (Ej. DaRT)"
                Write-Host "   [2] Inyectar Drivers (.inf) -> Vital para detectar discos" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "   [T] Terminar edicion y proceder a Guardar" -ForegroundColor Green
                Write-Host ""
                
                $opcionBoot = Read-Host " Elige una opcion"
                switch ($opcionBoot.ToUpper()) {
                    "1" { Write-Log -LogLevel INFO -Message "BootWimManager: Lanzando inyector de Addons."; Show-Addons-GUI }
                    "2" { Write-Log -LogLevel INFO -Message "BootWimManager: Lanzando inyector de Drivers."; Show-Drivers-GUI }
                    "T" { 
                        Write-Log -LogLevel INFO -Message "BootWimManager: El usuario termino la edicion interactiva."
                        $doneEditingBoot = $true 
                    }
                    default { Write-Warning "Opcion invalida."; Start-Sleep 1 }
                }
            }

            # Pregunta final
            Clear-Host
            Write-Host "======================================================="
            if ((Read-Host "Deseas GUARDAR los cambios en el boot.wim? (S/N)").ToUpper() -eq 'S') {
                Write-Log -LogLevel ACTION -Message "BootWimManager: Iniciando guardado de cambios (Commit) en boot.wim."
                Unmount-Image -Commit
            } else {
                Write-Log -LogLevel INFO -Message "BootWimManager: Descartando cambios (Discard) en boot.wim."
                Unmount-Image # Discard por defecto
            }

        } else {
            Write-Log -LogLevel ERROR -Message "BootWimManager: Fallo critico al montar el boot.wim. Codigo DISM: $LASTEXITCODE"
            Write-Error "Fallo al montar el boot.wim."
            $Script:IMAGE_MOUNTED = 0
            $Script:WIM_FILE_PATH = $null
            $Script:MOUNTED_INDEX = $null
            Pause
        }

    } catch {
        Write-Log -LogLevel ERROR -Message "BootWimManager: Excepcion no controlada en el gestor de arranque - $($_.Exception.Message)"
        Write-Error "Error critico en el gestor de arranque: $_"
        $Script:IMAGE_MOUNTED = 0
        $Script:WIM_FILE_PATH = $null
        $Script:MOUNTED_INDEX = $null
        Pause
    }
}
