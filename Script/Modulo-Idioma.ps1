# =================================================================
#  Modulo-Idioma
#
#  CONTENIDO   : Inject-WinReLanguage
#                Inject-BootWimLanguage
#                Inject-OsLanguage
#                Show-LanguageInjector
#
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0=ninguna, 1=WIM, 2=VHD)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - Select-PathDialog      : dialogo de seleccion de carpeta/archivo
#
#  ARQUITECTURA:
#    Show-LanguageInjector  (orquestador de consola, 4 pasos interactivos)
#      ├─ Inject-WinReLanguage   (Fase 1 — winre.wim dentro del OS montado)
#      ├─ Inject-OsLanguage      (Fase 2 — install.wim montado en MOUNT_DIR)
#      └─ Inject-BootWimLanguage (Fase 3 — boot.wim en la distribucion ISO)
#  CARGA       : . "$PSScriptRoot\Modulo-Idioma.ps1"
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
#  Inject-WinReLanguage
#  Inyecta un paquete de idioma en el winre.wim embebido dentro de
#  la imagen OS montada. Opera en un directorio de trabajo aislado
#  en $env:TEMP para no comprometer el montaje principal.
# =================================================================
function Inject-WinReLanguage {
    param (
        [Parameter(Mandatory=$true)][string]$InstallMountDir,
        [Parameter(Mandatory=$true)][string]$WinPeLangPackPath,
        [Parameter(Mandatory=$true)][string]$LangCode
    )

    Write-Log -LogLevel ACTION -Message "LangInjector[WinRE]: Iniciando inyeccion del idioma [$LangCode] en el entorno de recuperacion."

    $winRePath    = Join-Path $InstallMountDir "Windows\System32\Recovery\winre.wim"
    $tempWorkDir  = Join-Path $env:TEMP "DeltaPack_WinRE_Workspace"
    $winReMountDir = Join-Path $tempWorkDir "Mount"
    $winReTempPath = Join-Path $tempWorkDir "winre.wim"

    $operationSucceeded  = $false
    $dismountedWithDiscard = $false

    if (-not (Test-Path $winRePath)) {
        Write-Log -LogLevel WARN -Message "LangInjector[WinRE]: No se encontro winre.wim en la ruta estandar."
        Write-Warning "No se encontro winre.wim en la imagen. Se omitira la inyeccion de recuperacion."
        return $false
    }

    try {
        Write-Log -LogLevel INFO -Message "LangInjector[WinRE]: Preparando entorno de trabajo aislado en $tempWorkDir"
        if (Test-Path $tempWorkDir) { Remove-Item -Path $tempWorkDir -Recurse -Force -ErrorAction SilentlyContinue }
        $null = New-Item -ItemType Directory -Path $winReMountDir -Force

        # Quitar atributo read-only/system antes de copiar
        Set-ItemProperty -Path $winRePath -Name Attributes -Value "Normal" -ErrorAction SilentlyContinue
        Copy-Item -Path $winRePath -Destination $winReTempPath -Force

        Write-Log -LogLevel ACTION -Message "LangInjector[WinRE]: Ejecutando DISM /Mount-Wim para winre.wim..."
        dism /mount-wim /wimfile:"$winReTempPath" /index:1 /mountdir:"$winReMountDir" | Out-Null

        if ($LASTEXITCODE -ne 0) { throw "Fallo al montar winre.wim. Codigo DISM: $LASTEXITCODE" }

        # Buscar CABs: primero en subcarpeta por codigo, luego por nombre de archivo
        Write-Log -LogLevel INFO -Message "LangInjector[WinRE]: Buscando e inyectando paquetes .cab de idioma..."
        $langSubDir = Join-Path $WinPeLangPackPath $LangCode
        $cabFiles   = @()

        if (Test-Path $langSubDir) {
            $cabFiles = Get-ChildItem -Path $langSubDir -Filter "*.cab" -Recurse
        } else {
            $cabFiles = Get-ChildItem -Path $WinPeLangPackPath -Filter "*$LangCode*.cab" -Recurse
        }

        if ($cabFiles.Count -eq 0) { throw "No se encontraron paquetes .cab para el idioma $LangCode." }

        foreach ($cab in $cabFiles) {
            Write-Log -LogLevel INFO -Message "LangInjector[WinRE]: Inyectando paquete -> $($cab.Name)"
            dism /image:"$winReMountDir" /add-package /packagepath:"$($cab.FullName)" | Out-Null
            # Codigo 3010 = reinicio requerido, no es error
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
                throw "Fallo al inyectar $($cab.Name). Codigo: $LASTEXITCODE"
            }
        }

        Write-Log -LogLevel ACTION -Message "LangInjector[WinRE]: Configurando [$LangCode] como idioma predeterminado del entorno..."
        dism /image:"$winReMountDir" /Set-AllIntl:$LangCode | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Fallo al establecer el idioma predeterminado. Codigo: $LASTEXITCODE" }

        $operationSucceeded = $true

    } catch {
        Write-Log -LogLevel ERROR -Message "LangInjector[WinRE]: Falla critica durante el proceso - $($_.Exception.Message)"
        Write-Error "Fallo la inyeccion en WinRE: $($_.Exception.Message)"

        if (Test-Path $winReMountDir) {
            dism /unmount-wim /mountdir:"$winReMountDir" /discard | Out-Null
            $dismountedWithDiscard = $true
        }
    } finally {
        if (-not $dismountedWithDiscard -and (Test-Path $winReMountDir)) {
            $mountInfo = dism /get-mountedwiminfo | Select-String $winReMountDir
            if ($mountInfo) {
                Write-Log -LogLevel ACTION -Message "LangInjector[WinRE]: Guardando cambios y desmontando winre.wim..."
                dism /unmount-wim /mountdir:"$winReMountDir" /commit | Out-Null

                if ($LASTEXITCODE -eq 0) {
                    # Bug 1 corregido: I/O aislado para no enmascarar excepciones originales
                    try {
                        Write-Host "`n   > Optimizando tamano final del WinRE (Exportando)..." -ForegroundColor Yellow
                        $winReOptimized = Join-Path $tempWorkDir "winre_optimized.wim"
                        dism /export-image /sourceimagefile:"$winReTempPath" /sourceindex:1 /destinationimagefile:"$winReOptimized" /compress:max | Out-Null

                        $exportOk = $false
                        if ($LASTEXITCODE -eq 0 -and (Test-Path $winReOptimized)) {
                            Copy-Item -Path $winReOptimized -Destination $winRePath -Force
                            $exportOk = $true
                        }

                        if (-not $exportOk) {
                            Copy-Item -Path $winReTempPath -Destination $winRePath -Force
                        }

                        # Restaurar atributos de sistema/oculto propios de winre.wim
                        Set-ItemProperty -Path $winRePath -Name Attributes -Value "Hidden, System" -ErrorAction SilentlyContinue
                    } catch {
                        Write-Log -LogLevel ERROR -Message "LangInjector[WinRE]: Fallo la copia del WinRE al destino final - $($_.Exception.Message)"
                        $operationSucceeded = $false
                    }
                } else {
                    Write-Log -LogLevel ERROR -Message "LangInjector[WinRE]: Error critico al desmontar winre.wim. Codigo: $LASTEXITCODE"
                    $operationSucceeded = $false
                }
            }
        }

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Remove-Item -Path $tempWorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $operationSucceeded
}


# =================================================================
#  Inject-BootWimLanguage
#  Inyecta idioma en todos los indices del boot.wim de la distribucion
#  ISO. Regenera Lang.ini en el indice 2 (setup). Exporta y reemplaza
#  el archivo final para reducir tamaño.
# =================================================================
function Inject-BootWimLanguage {
    param (
        [Parameter(Mandatory=$true)][string]$BootWimPath,
        [Parameter(Mandatory=$true)][string]$IsoDistributionDir,
        [Parameter(Mandatory=$true)][string]$WinPeLangPackPath,
        [Parameter(Mandatory=$true)][string]$LangCode
    )

    Write-Log -LogLevel ACTION -Message "LangInjector[Boot]: Iniciando inyeccion Tier 1 para el idioma [$LangCode] en el Boot.wim."

    $tempWorkDir  = Join-Path $env:TEMP "DeltaPack_Boot_Workspace"
    $bootMountDir = Join-Path $tempWorkDir "Mount"
    $operationSucceeded = $false

    try {
        if (Test-Path $tempWorkDir) { Remove-Item -Path $tempWorkDir -Recurse -Force -ErrorAction SilentlyContinue }
        $null = New-Item -ItemType Directory -Path $bootMountDir -Force

        $bootImages = Get-WindowsImage -ImagePath $BootWimPath -ErrorAction Stop
        $indexCount = $bootImages.Count

        # Resolver paquetes CAB: subcarpeta por codigo o por patron en nombre de archivo
        $langSubDir = Join-Path $WinPeLangPackPath $LangCode
        $cabFiles   = @()

        if (Test-Path $langSubDir) {
            $cabFiles = Get-ChildItem -Path $langSubDir -Filter "*.cab" -Recurse
        } else {
            $cabFiles = Get-ChildItem -Path $WinPeLangPackPath -Filter "*$LangCode*.cab" -Recurse
        }

        if ($cabFiles.Count -eq 0) { throw "No se encontraron paquetes WinPE/Setup para $LangCode." }

        # Procesar cada indice del boot.wim (tipicamente 1=WinPE, 2=Setup)
        for ($i = 1; $i -le $indexCount; $i++) {
            try {
                Write-Host "`n[+] Procesando boot.wim (Indice $i de $indexCount)..." -ForegroundColor Yellow
                dism /mount-wim /wimfile:"$BootWimPath" /index:$i /mountdir:"$bootMountDir" | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Fallo al montar el Indice $i del boot.wim. Codigo: $LASTEXITCODE" }

                Write-Host "   > Inyectando paquetes de idioma WinPE/Setup..." -ForegroundColor DarkGray
                foreach ($cab in $cabFiles) {
                    dism /image:"$bootMountDir" /add-package /packagepath:"$($cab.FullName)" | Out-Null
                }

                Write-Host "   > Configurando $LangCode por defecto..." -ForegroundColor DarkGray
                dism /image:"$bootMountDir" /Set-AllIntl:$LangCode | Out-Null

                # Regenerar Lang.ini en el indice de Setup (2) o si solo hay uno
                if ($i -eq 2 -or $indexCount -eq 1) {
                    if (Test-Path $IsoDistributionDir) {
                        Write-Host "   > Regenerando archivo de orquestacion Lang.ini..." -ForegroundColor Cyan
                        dism /image:"$bootMountDir" /Gen-LangINI /distribution:"$IsoDistributionDir" | Out-Null
                        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) {
                            dism /image:"$bootMountDir" /Set-SetupUILang:$LangCode /distribution:"$IsoDistributionDir" | Out-Null
                        }
                    }
                }

                Write-Host "   > Guardando cambios en el Indice $i..." -ForegroundColor Green
                dism /unmount-wim /mountdir:"$bootMountDir" /commit | Out-Null

                if ($LASTEXITCODE -ne 0) {
                    throw "Fallo al guardar cambios en el indice $i del boot.wim. Codigo: $LASTEXITCODE"
                }

            } catch {
                Write-Log -LogLevel ERROR -Message "LangInjector[Boot]: Falla en el Indice $i - $($_.Exception.Message)"
                Write-Error "Error en el indice $i del boot.wim: $($_.Exception.Message)"
                dism /unmount-wim /mountdir:"$bootMountDir" /discard | Out-Null
                throw $_   # Re-lanzar para que el catch externo lo capture
            }
        }

        # Exportar todos los indices para comprimir y reducir tamaño del boot.wim
        Write-Host "`n[+] Optimizando tamano final del boot.wim (Exportando indices)..." -ForegroundColor Yellow
        $bootOptimized = Join-Path $tempWorkDir "boot_optimized.wim"
        $exportSuccess = $true

        for ($j = 1; $j -le $indexCount; $j++) {
            dism /export-image /sourceimagefile:"$BootWimPath" /sourceindex:$j /destinationimagefile:"$bootOptimized" /compress:max | Out-Null
            if ($LASTEXITCODE -ne 0) { $exportSuccess = $false; break }
        }

        if ($exportSuccess -and (Test-Path $bootOptimized)) {
            $bootWimBackup = "$BootWimPath.bak"
            try {
                Copy-Item -Path $BootWimPath   -Destination $bootWimBackup  -Force
                Copy-Item -Path $bootOptimized -Destination $BootWimPath    -Force
                Remove-Item -Path $bootWimBackup -Force -ErrorAction SilentlyContinue
                Write-Log -LogLevel INFO -Message "LangInjector[Boot]: Exportacion y reemplazo de boot.wim exitosos."
            } catch {
                # Rollback: restaurar backup si falla la copia final
                if (Test-Path $bootWimBackup) {
                    Copy-Item -Path $bootWimBackup -Destination $BootWimPath -Force
                    Remove-Item -Path $bootWimBackup -Force -ErrorAction SilentlyContinue
                }
                throw "Fallo la copia fisica del boot.wim optimizado. Se restauro la copia de seguridad original. Error: $($_.Exception.Message)"
            }
        } else {
            # Bug 2 corregido: advertencia explicita cuando la optimizacion falla
            Write-Log -LogLevel WARN -Message "LangInjector[Boot]: La optimizacion (export) fallo o fue omitida. El boot.wim conserva su tamano original sin comprimir."
            Write-Warning "boot.wim no pudo ser optimizado. Revisa el log para detalles."
        }

        $operationSucceeded = $true

    } catch {
        Write-Log -LogLevel ERROR -Message "LangInjector[Boot]: $($_.Exception.Message)"
        $operationSucceeded = $false
    } finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Remove-Item -Path $tempWorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $operationSucceeded
}


# =================================================================
#  Inject-OsLanguage
#  Inyecta en la imagen OS montada: el LP principal, las Features
#  on Demand (Basic, Fonts, Handwriting, Speech, TextToSpeech) y
#  el paquete de experiencia local (LXP UWP si existe).
# =================================================================
function Inject-OsLanguage {
    param (
        [Parameter(Mandatory=$true)][string]$MountDir,
        [Parameter(Mandatory=$true)][string]$LangPackPath,
        [Parameter(Mandatory=$true)][string]$FodPath,
        [Parameter(Mandatory=$false)][string]$LxpPath,
        [Parameter(Mandatory=$true)][string]$LangCode
    )

    Write-Log -LogLevel ACTION -Message "LangInjector[OS]: Iniciando inyeccion Tier 1 para el idioma [$LangCode] en el Install.wim."

    try {
        # 1. Paquete de idioma principal (Client Language Pack)
        Write-Log -LogLevel INFO -Message "LangInjector[OS]: Buscando el paquete de idioma principal (Client-Language-Pack)..."
        $lpCab = Get-ChildItem -Path $LangPackPath -Filter "*Client-Language-Pack*$LangCode*.cab" -Recurse |
                 Select-Object -First 1

        if (-not $lpCab) {
            throw "No se encontro el paquete de idioma principal (LP) para $LangCode en la ruta proporcionada."
        }

        Write-Host "   > Inyectando paquete base ($LangCode)..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "LangInjector[OS]: Inyectando LP -> $($lpCab.Name)"

        dism /image:"$MountDir" /Add-Package /PackagePath:"$($lpCab.FullName)" | Out-Null
        if ($LASTEXITCODE -notin @(0, 3010)) { throw "Error al inyectar el LP. Codigo DISM: $LASTEXITCODE" }

        # 2. Features on Demand (opcionales pero recomendadas)
        Write-Host "   > Inyectando caracteristicas bajo demanda (Voz, Fuentes, Texto)..." -ForegroundColor Yellow
        $fodTypes = @("Basic", "Fonts", "Handwriting", "Speech", "TextToSpeech")

        foreach ($fod in $fodTypes) {
            $fodCab = Get-ChildItem -Path $FodPath -Filter "*LanguageFeatures-$fod*$LangCode*.cab" -Recurse |
                      Select-Object -First 1
            if ($fodCab) {
                dism /image:"$MountDir" /Add-Package /PackagePath:"$($fodCab.FullName)" | Out-Null
            } else {
                Write-Log -LogLevel WARN -Message "LangInjector[OS]: FOD '$fod' no encontrado para $LangCode. Se omitira."
            }
        }

        # 3. Paquete de Experiencia Local (LXP UWP, opcional)
        # Bug 3 corregido: Start-Process en lugar de Invoke-Expression para blindar rutas con espacios
        if ($LxpPath -and (Test-Path $LxpPath)) {
            Write-Host "   > Inyectando paquete de experiencia local (LXP UWP)..." -ForegroundColor Yellow
            $lxpAppx    = Get-ChildItem -Path $LxpPath -Filter "*$LangCode*.appx*" -Recurse | Select-Object -First 1
            $lxpLicense = Get-ChildItem -Path $LxpPath -Filter "*$LangCode*license*.xml" -Recurse | Select-Object -First 1

            if ($lxpAppx) {
                Write-Log -LogLevel ACTION -Message "LangInjector[OS]: Inyectando LXP Appx -> $($lxpAppx.Name)"

                $dismArgs = @(
                    "/image:$MountDir",
                    "/Add-ProvisionedAppxPackage",
                    "/PackagePath:$($lxpAppx.FullName)",
                    "/SkipLicense"
                )

                if ($lxpLicense) {
                    # Reemplazar /SkipLicense por la licencia real si existe
                    $dismArgs[-1] = "/LicensePath:$($lxpLicense.FullName)"
                }

                $proc = Start-Process dism.exe -ArgumentList $dismArgs -Wait -PassThru -WindowStyle Hidden
                if ($proc.ExitCode -notin @(0, 3010)) {
                    Write-Log -LogLevel WARN -Message "LangInjector[OS]: Error al inyectar LXP. Codigo: $($proc.ExitCode)"
                }
            }
        }

        # 4. Configurar como idioma predeterminado del sistema
        Write-Host "   > Configurando $LangCode como idioma predeterminado del sistema..." -ForegroundColor Yellow
        dism /image:"$MountDir" /Set-AllIntl:$LangCode | Out-Null
        dism /image:"$MountDir" /Set-SKUIntlDefaults:$LangCode | Out-Null

        if ($LASTEXITCODE -notin @(0, 3010)) {
            throw "Error al configurar el idioma predeterminado. Codigo: $LASTEXITCODE"
        }

        Write-Log -LogLevel ACTION -Message "LangInjector[OS]: Inyeccion en Install.wim finalizada exitosamente."
        return $true

    } catch {
        Write-Log -LogLevel ERROR -Message "LangInjector[OS]: Falla critica en la inyeccion principal - $($_.Exception.Message)"
        Write-Error "Fallo la inyeccion en Install.wim: $($_.Exception.Message)"
        return $false
    }
}


# =================================================================
#  Show-LanguageInjector
#  Orquestador de consola interactivo de 4 pasos. Guia al usuario
#  en la recopilacion de rutas y ejecuta las tres fases en secuencia:
#    Fase 1 → Inject-WinReLanguage
#    Fase 2 → Inject-OsLanguage
#    Fase 3 → Inject-BootWimLanguage
# =================================================================
function Show-LanguageInjector {
    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host "         Inyector de Idiomas (OSD Offline)             " -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan

    # Bug 6 corregido: aceptar tanto WIM (1) como VHD (2)
    if ($Script:IMAGE_MOUNTED -eq 0) {
        Write-Log -LogLevel WARN -Message "LangInjectorGUI: Acceso denegado. No hay ninguna imagen montada."
        Write-Warning "Debes montar una imagen (WIM o VHD) antes de iniciar este proceso."
        Pause; return
    }

    if ($Script:IMAGE_MOUNTED -eq 2) {
        Write-Warning "Imagen VHD detectada. La inyeccion en WinRE podria omitirse si el archivo winre.wim no existe en la ruta estandar."
    }

    Write-Host "Este asistente automatizado procesara WinRE, el OS y Boot.wim en secuencia." -ForegroundColor DarkGray
    Write-Host "Requisitos previos:" -ForegroundColor Yellow
    Write-Host " 1. ISO de Idiomas (Language and Optional Features) extraida." -ForegroundColor White
    Write-Host " 2. Windows ADK instalado O carpeta de WinPE Addons manual." -ForegroundColor White
    Write-Host " 3. Carpeta de distribucion de tu ISO de Windows (donde esta 'sources').`n" -ForegroundColor White

    $langCode = Read-Host "Ingrese el codigo de idioma objetivo (Ej: es-MX, es-ES, en-US)"
    if ([string]::IsNullOrWhiteSpace($langCode)) { return }

    # Paso 1: Carpeta raiz de la ISO de Idiomas (FODs y Client LP)
    Write-Host "`n[Paso 1 de 4] Selecciona la carpeta raiz de la ISO de Idiomas (FODs y Client LP)..." -ForegroundColor Cyan
    $osLangPath = Select-PathDialog -DialogType Folder -Title "Selecciona carpeta de la ISO de Idiomas"
    if (-not $osLangPath) { return }

    # Paso 2: Localizar paquetes WinPE — ADK oficial, copia local, o seleccion manual
    Write-Host "`n[Paso 2 de 4] Buscando paquetes WinPE (ADK) para el idioma [$langCode]..." -ForegroundColor Cyan

    # Bug 4 corregido: deteccion de arquitectura dinamica desde la imagen montada
    $imgArch = "amd64"
    if (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysArm32")) {
        $imgArch = "arm64"
    } elseif (-not (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysWOW64"))) {
        $imgArch = "x86"
    }

    $peLangPath   = $null
    $adkPath      = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\$imgArch\WinPE_OCs"
    $localPePath  = Join-Path $PSScriptRoot "WinPE\$imgArch\WinPE_OCs"

    if ((Test-Path $adkPath) -and (Test-Path (Join-Path $adkPath $langCode))) {
        $peLangPath = $adkPath
        Write-Host "   [OK] ADK oficial detectado automaticamente en:" -ForegroundColor Green
        Write-Host "   $peLangPath" -ForegroundColor Gray
    } elseif ((Test-Path $localPePath) -and (Test-Path (Join-Path $localPePath $langCode))) {
        $peLangPath = $localPePath
        Write-Host "   [OK] Carpeta WinPE local detectada automaticamente en:" -ForegroundColor Green
        Write-Host "   $peLangPath" -ForegroundColor Gray
    } else {
        Write-Host "   [!] No se encontro el ADK de Windows instalado para la arquitectura $imgArch." -ForegroundColor Yellow
        Write-Host "   Por favor, selecciona manualmente la carpeta raiz 'WinPE_OCs' (NO la subcarpeta del idioma)..." -ForegroundColor Cyan

        # Bug 5 corregido: titulo del dialogo clarificado para evitar confusion
        $peLangPath = Select-PathDialog -DialogType Folder -Title "Selecciona la raiz de WinPE Addons (ej. ...\amd64\WinPE_OCs)"
        if (-not $peLangPath) { return }
    }

    # Paso 3: Carpeta raiz de la distribucion ISO de Windows (donde esta 'sources')
    Write-Host "`n[Paso 3 de 4] Selecciona la carpeta raiz de tu ISO de Windows (Distribucion con carpeta 'sources')..." -ForegroundColor Cyan
    $isoDistPath = Select-PathDialog -DialogType Folder -Title "Selecciona la raiz de la ISO de Windows a compilar"
    if (-not $isoDistPath) { return }

    $bootWimPath = Join-Path $isoDistPath "sources\boot.wim"
    if (-not (Test-Path $bootWimPath)) {
        Write-Warning "No se encontro el archivo 'sources\boot.wim' en la carpeta seleccionada."
        Pause; return
    }

    # Paso 4: Confirmacion antes de ejecutar
    Write-Host "`n[Paso 4 de 4] Confirmacion Final" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Imagen OS montada : $Script:MOUNT_DIR" -ForegroundColor Gray
    Write-Host "  Idioma objetivo   : $langCode" -ForegroundColor Gray
    Write-Host "  WinPE Addons      : $peLangPath" -ForegroundColor Gray
    Write-Host "  ISO Idiomas       : $osLangPath" -ForegroundColor Gray
    Write-Host "  ISO Distribucion  : $isoDistPath" -ForegroundColor Gray
    Write-Host ""

    $confirm = Read-Host "Iniciar inyeccion masiva para [$langCode]? (S/N)"
    if ($confirm -notmatch '^(s|S)$') { return }

    $startTime = Get-Date

    try {
        # Fase 1: winre.wim
        Write-Host "`n=======================================================" -ForegroundColor Magenta
        Write-Host " FASE 1: Procesando Entorno de Recuperacion (winre.wim)" -ForegroundColor Magenta
        Write-Host "=======================================================" -ForegroundColor Magenta
        $winReSuccess = Inject-WinReLanguage `
            -InstallMountDir   $Script:MOUNT_DIR `
            -WinPeLangPackPath $peLangPath `
            -LangCode          $langCode

        if (-not $winReSuccess) {
            Write-Warning "La inyeccion en WinRE fallo o se omitio. Continuando con el OS principal..."
        }

        # Fase 2: install.wim (imagen OS montada)
        Write-Host "`n=======================================================" -ForegroundColor Magenta
        Write-Host " FASE 2: Procesando Sistema Operativo (install.wim)" -ForegroundColor Magenta
        Write-Host "=======================================================" -ForegroundColor Magenta
        $osSuccess = Inject-OsLanguage `
            -MountDir    $Script:MOUNT_DIR `
            -LangPackPath $osLangPath `
            -FodPath      $osLangPath `
            -LxpPath      $osLangPath `
            -LangCode     $langCode

        if (-not $osSuccess) {
            throw "La inyeccion en el sistema operativo fallo. Abortando secuencia."
        }

        # Fase 3: boot.wim en la distribucion ISO
        Write-Host "`n=======================================================" -ForegroundColor Magenta
        Write-Host " FASE 3: Procesando Instalador y Lang.ini (boot.wim)" -ForegroundColor Magenta
        Write-Host "=======================================================" -ForegroundColor Magenta
        $bootSuccess = Inject-BootWimLanguage `
            -BootWimPath        $bootWimPath `
            -IsoDistributionDir $isoDistPath `
            -WinPeLangPackPath  $peLangPath `
            -LangCode           $langCode

        if (-not $bootSuccess) {
            Write-Warning "La inyeccion en boot.wim tuvo errores. Revisa los logs."
        }

        # Resumen final
        $timeSpan = New-TimeSpan -Start $startTime -End (Get-Date)

        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Green
        Write-Host "        INYECCION DE IDIOMA COMPLETADA ($langCode)     " -ForegroundColor Green
        Write-Host "=======================================================" -ForegroundColor Green
        Write-Host "Tiempo transcurrido: $($timeSpan.Minutes) min $($timeSpan.Seconds) seg" -ForegroundColor Gray

        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "Inyeccion del idioma $langCode completada en la estructura base y el instalador.",
            "Operacion Exitosa", 'OK', 'Information')

    } catch {
        Write-Error "El orquestador de idiomas sufrio un error fatal: $_"
    }

    Pause
}
