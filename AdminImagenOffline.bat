@echo off
title Administrador de Imagen offline by SOFTMAXTER V1.2
Color 0A
setlocal enabledelayedexpansion

:: Verifica si se ejecuta como administrador
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo.
    echo Necesitas ejecutar este script como administrador.
    echo.
    echo Reiniciando con permisos elevados...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& {Start-Process '%~f0' -Verb RunAs}"
    exit /b
)

:: Variables Globales
set "WIM_FILE_PATH="
set "MOUNT_DIR=C:\TEMP"
set "Scratch_DIR=C:\TEMP1"
set "IMAGE_MOUNTED=0"
set "MOUNTED_INDEX="

:: =================================================================
::  CORREGIDO: Rutina de verificación de montaje existente (dinámica)
:: =================================================================
set "IMAGE_MOUNTED=0"
set "WIM_FILE_PATH="
set "MOUNTED_INDEX="
set "TEMP_DISM_OUT=%TEMP%\dism_check_%RANDOM%.tmp"

REM Guarda la información de imágenes montadas en un archivo temporal
dism /get-mountedimageinfo > "%TEMP_DISM_OUT%" 2>nul

REM Busca si existe CUALQUIER directorio de montaje en el resultado
findstr /I /L /C:"Mount Dir :" "%TEMP_DISM_OUT%" >nul
if %errorlevel% neq 0 goto :no_mount_found

REM --- Este código solo se ejecuta si se encuentra una imagen montada ---
set "IMAGE_MOUNTED=1"

REM Extrae dinámicamente el directorio de montaje
for /f "tokens=1,* delims=:" %%A in ('findstr /I /L /C:"Mount Dir :" "%TEMP_DISM_OUT%"') do (
    set "MOUNT_DIR=%%B"
    call :trim_leading_spaces MOUNT_DIR
    goto :got_mount_dir
)
:got_mount_dir

REM Extrae dinámicamente la ruta del WIM
for /f "tokens=1,* delims=:" %%A in ('findstr /I /L /C:"Image File :" "%TEMP_DISM_OUT%"') do (
    set "WIM_FILE_PATH=%%B"
    call :trim_leading_spaces WIM_FILE_PATH
    if /I "!WIM_FILE_PATH:~0,4!"=="\\?\" (
        set "WIM_FILE_PATH=!WIM_FILE_PATH:~4!"
    )
    goto :got_wim_path
)
:got_wim_path

REM Extrae dinámicamente el índice de la imagen
for /f "tokens=1,* delims=:" %%A in ('findstr /I /L /C:"Image Index" "%TEMP_DISM_OUT%"') do (
    set "MOUNTED_INDEX=%%B"
    call :trim_leading_spaces MOUNTED_INDEX
    goto :got_index
)
:got_index

REM Salta al final de la rutina de limpieza
goto :cleanup_temp_file

:no_mount_found
REM Etiqueta a la que salta si no se encuentra ninguna imagen montada

:cleanup_temp_file
REM Limpia el archivo temporal al final
if exist "%TEMP_DISM_OUT%" del "%TEMP_DISM_OUT%"

:main_menu
cls
echo.
echo =========================================================================
echo.
echo  Administrador de Imagen offline by SOFTMAXTER V1.2
echo.
echo =========================================================================
echo.
echo  Ruta del WIM: !WIM_FILE_PATH!
echo  Estado: %IMAGE_MOUNTED% (0=Desmontado, 1=Montado)
echo.
echo =========================================================================
echo.
echo  1. Gestionar Imagen (Montar/Desmontar/Guardar)
echo.
echo  2. Cambiar Edicion de Windows
echo     (Muestra las ediciones disponibles y permite el cambio)
echo.
echo  3. Herramientas de Limpieza
echo     (Ejecuta tareas de mantenimiento, verificacion y reparacion)
echo.
echo ----------------------------------------------------------------
echo.
echo  0. Salir
echo.
set /p opcionM="Ingrese el numero de la opcion: "

if "%opcionM%"=="1" goto image_management_menu
if "%opcionM%"=="2" goto cambio_edicion
if "%opcionM%"=="3" goto limpieza
if "%opcionM%"=="0" (
    echo Saliendo...
    exit /b
)
echo Opcion no valida.
Intente nuevamente.
pause
goto main_menu

:: =============================================
::  Menu de Gestion de Imagen
:: =============================================
:image_management_menu
cls
echo.
echo =========================================================================
echo.
echo  Gestion de Imagen
echo.
echo =========================================================================
echo.
echo  1. Montar/Desmontar Imagen 
echo.
echo  2. Guardar Cambios 
echo.
echo  3. Editar Indices 
echo.
echo  4. Convertir Imagen a WIM
echo.
echo ----------------------------------------------------------------
echo.
echo  0. Volver al Menu Principal 
echo.
set /p opcionIM="Ingrese el numero de la opcion: "

if "%opcionIM%"=="1" goto mount_unmount_menu
if "%opcionIM%"=="2" goto save_changes_menu
if "%opcionIM%"=="3" goto edit_indexes_menu
if "%opcionIM%"=="4" goto convert_image_menu
if "%opcionIM%"=="0" goto main_menu
echo Opcion no valida. 
Intente nuevamente. 
pause
goto image_management_menu

:: =============================================
::  Submenu Montar/Desmontar
:: =============================================
:mount_unmount_menu
cls
echo.
echo =========================================================================
echo.
echo  Montar/Desmontar Imagen
echo.
echo =========================================================================
echo.
echo  1. Montar Imagen
echo.
echo  2. Desmontar Imagen
echo.
echo  3. Recargar Imagen (Descartar cambios)
echo.
echo ----------------------------------------------------------------
echo.
echo  0. Volver al menu anterior
echo.
set /p opcionMU="Ingrese el numero de la opcion: "

if "%opcionMU%"=="1" goto mount_image
if "%opcionMU%"=="2" goto unmount_image
if "%opcionMU%"=="3" goto reload_image
if "%opcionMU%"=="0" goto image_management_menu
echo Opcion no valida.
Intente nuevamente.
pause
goto mount_unmount_menu

:reload_image
cls
if "%IMAGE_MOUNTED%"=="0" (
    echo.
    echo No hay ninguna imagen montada para recargar.
    pause
    goto mount_unmount_menu
)
if not defined WIM_FILE_PATH (
    echo.
    echo ERROR: No se puede encontrar la ruta del archivo WIM original.
    pause
    goto mount_unmount_menu
)
if not defined MOUNTED_INDEX (
    echo.
    echo ERROR: No se pudo determinar el Indice de la imagen montada.
    pause
    goto mount_unmount_menu
)

echo.
echo Va a recargar la imagen descartando todos los cambios no guardados.
echo.
echo   Ruta del WIM: !WIM_FILE_PATH!
echo   Indice Montado: !MOUNTED_INDEX!
echo.
set /p "CONFIRM=Desea continuar? (S/N): "
if /i not "%CONFIRM%"=="S" (
    echo.
    echo Operacion cancelada.
    pause
    goto mount_unmount_menu
)

echo.
echo Desmontando imagen...
dism /unmount-wim /mountdir:"%MOUNT_DIR%" /discard >nul
if !errorlevel! neq 0 (
    echo.
    echo Error al intentar desmontar la imagen. Se intentara una limpieza automatica.
    echo Ejecutando 'dism /cleanup-wim'...
    dism /cleanup-wim
    echo.
    echo Limpieza completada. Se reintentara la operacion de recarga en 5 segundos...
    timeout /t 5 >nul
    goto :reload_image
)

echo.
echo Remontando imagen (Indice: !MOUNTED_INDEX!)... 
dism /mount-wim /wimfile:"!WIM_FILE_PATH!" /index:!MOUNTED_INDEX! /mountdir:"%MOUNT_DIR%" 
if !errorlevel! equ 0 (
    echo Imagen recargada exitosamente.
    set "IMAGE_MOUNTED=1" 
) else (
    echo Error al remontar la imagen.
    set "IMAGE_MOUNTED=0"
    set "WIM_FILE_PATH="
    set "MOUNTED_INDEX="
)
pause
goto mount_unmount_menu

:mount_image
cls
if "%IMAGE_MOUNTED%"=="1" (
    echo.
    echo La imagen ya se encuentra montada.
    pause
    goto mount_unmount_menu
)
set /p "WIM_FILE_PATH=Ingrese la ruta completa del archivo WIM: "
if not exist "!WIM_FILE_PATH!" (
    echo.
    echo El archivo no existe.
    pause
    goto mount_image
)

dism /get-wiminfo /wimfile:"!WIM_FILE_PATH!"
set /p "INDEX=Ingrese el numero de indice a montar: "

if not exist "%MOUNT_DIR%" mkdir "%MOUNT_DIR%"

dism /mount-wim /wimfile:"!WIM_FILE_PATH!" /index:!INDEX! /mountdir:"%MOUNT_DIR%"
if !errorlevel! equ 0 (
    set "IMAGE_MOUNTED=1"
    set "MOUNTED_INDEX=!INDEX!"
    echo.
    echo Imagen montada exitosamente.
) else (
    echo Error al montar la imagen.
)
pause
goto mount_unmount_menu

:unmount_image
cls
if "%IMAGE_MOUNTED%"=="0" (
    echo.
    echo No hay ninguna imagen montada.
    pause
    goto mount_unmount_menu
)
echo.
echo Desmontando imagen...
dism /unmount-wim /mountdir:"%MOUNT_DIR%" /discard
set "IMAGE_MOUNTED=0"
set "WIM_FILE_PATH="
set "MOUNTED_INDEX="
echo.
echo Imagen desmontada.
pause
goto mount_unmount_menu

:: =============================================
::  Submenu Guardar Cambios
:: =============================================
:save_changes_menu
cls
if "%IMAGE_MOUNTED%"=="0" (
    echo No hay ninguna imagen montada para guardar.
    pause
    goto image_management_menu
)
echo.
echo =========================================================================
echo.
echo  Guardar Cambios (Sin desmontar)
echo.
echo =========================================================================
echo.
echo  1. Guardar cambios en el Indice actual
echo.
echo  2. Guardar cambios en un nuevo Indice (Append)
echo.
echo ----------------------------------------------------------------
echo.
echo  0. Volver al menu anterior
echo.
set /p opcionSC="Ingrese el numero de la opcion: "

if "%opcionSC%"=="1" (
    dism /commit-image /mountdir:"%MOUNT_DIR%"
    echo Cambios guardados en el indice actual.
    pause
    goto save_changes_menu
)
if "%opcionSC%"=="2" (
    dism /commit-image /mountdir:"%MOUNT_DIR%" /append
    echo Cambios guardados en un nuevo indice.
    pause
    goto save_changes_menu
)
if "%opcionSC%"=="0" goto image_management_menu
echo Opcion no valida.
Intente nuevamente.
pause
goto save_changes_menu

:: =============================================
::  NUEVO Submenu Editar Índices
:: =============================================
:edit_indexes_menu
cls
echo.
echo =========================================================================
echo.
echo  Editar Indices del WIM
echo.
echo =========================================================================
echo.
echo  1. Exportar un Indice
echo.
echo  2. Eliminar un Indice
echo.
echo ----------------------------------------------------------------
echo.
echo  0. Volver al menu anterior
echo.
set /p opcionEI="Ingrese el numero de la opcion: "

if "%opcionEI%"=="1" goto export_index
if "%opcionEI%"=="2" goto delete_index
if "%opcionEI%"=="0" goto image_management_menu
echo Opcion no valida.
Intente nuevamente.
pause
goto edit_indexes_menu

:export_index
cls
if "!WIM_FILE_PATH!"=="" (
    set /p "WIM_FILE_PATH=Ingrese la ruta completa del archivo WIM de origen: "
    if not exist "!WIM_FILE_PATH!" (
        echo El archivo no existe.
        set "WIM_FILE_PATH="
        pause
        goto edit_indexes_menu
    )
)
echo.
echo Archivo WIM actual: !WIM_FILE_PATH!
echo.
dism /get-wiminfo /wimfile:"!WIM_FILE_PATH!"
echo.
set /p "INDEX_TO_EXPORT=Ingrese el numero de Indice que desea exportar: "

REM Obtener las partes del archivo original para crear un nombre por defecto
for %%F in ("!WIM_FILE_PATH!") do (
    set "WIM_DIR=%%~dpF"
    set "WIM_NAME=%%~nF"
)
set "DEFAULT_DEST_PATH=!WIM_DIR!!WIM_NAME!_indice_!INDEX_TO_EXPORT!.wim"

echo.
echo Ruta de destino sugerida:
echo !DEFAULT_DEST_PATH!
echo.
set /p "DEST_WIM_PATH=Ingrese la ruta completa (o presione Enter para usar la sugerida): "

REM Si el usuario no ingresa nada, usar la ruta por defecto
if "!DEST_WIM_PATH!"=="" set "DEST_WIM_PATH=!DEFAULT_DEST_PATH!"

dism /export-image /sourceimagefile:"!WIM_FILE_PATH!" /sourceindex:!INDEX_TO_EXPORT! /destinationimagefile:"!DEST_WIM_PATH!"
if !errorlevel! equ 0 (
    echo.
    echo Indice !INDEX_TO_EXPORT! exportado exitosamente a "!DEST_WIM_PATH!".
) else (
    echo.
    echo Error al exportar el Indice. Verifique la ruta y los permisos.
)
pause
goto edit_indexes_menu

:delete_index
cls
if "!WIM_FILE_PATH!"=="" (
    set /p "WIM_FILE_PATH=Ingrese la ruta completa del archivo WIM: "
    if not exist "!WIM_FILE_PATH!" (
        echo El archivo no existe.
        set "WIM_FILE_PATH="
        pause
        goto edit_indexes_menu
    )
)
echo.
echo Archivo WIM actual: !WIM_FILE_PATH!
echo.
dism /get-wiminfo /wimfile:"!WIM_FILE_PATH!"
echo.
set /p "INDEX_TO_DELETE=Ingrese el número de Indice que desea eliminar: "
echo.
set /p "CONFIRM=Está seguro que desea eliminar el Indice !INDEX_TO_DELETE! de forma permanente? (S/N): "

if /i "%CONFIRM%"=="S" (
    dism /delete-image /imagefile:"!WIM_FILE_PATH!" /index:!INDEX_TO_DELETE!
    if !errorlevel! equ 0 (
        echo.
        echo Indice !INDEX_TO_DELETE! eliminado exitosamente.
    ) else (
        echo.
        echo Error al eliminar el Indice. Puede que esté montado o que el archivo esté en uso.
    )
) else (
    echo.
    echo Operación cancelada.
)
pause
goto edit_indexes_menu

:: =============================================
::  NUEVO Submenu Convertir Imagen
:: =============================================
:convert_image_menu
cls
echo.
echo =========================================================================
echo.
echo  Convertir otro formato de imagen a WIM
echo.
echo =========================================================================
echo.
echo  1. Convertir ESD a WIM
echo.
echo  2. Convertir VHD/VHDX a WIM
echo.
echo ----------------------------------------------------------------
echo.
echo  0. Volver al menu anterior
echo.
set /p opcionCI="Ingrese el numero de la opcion: "

if "%opcionCI%"=="1" goto convert_esd
if "%opcionCI%"=="2" goto convert_vhd
if "%opcionCI%"=="0" goto image_management_menu
echo Opcion no valida.
Intente nuevamente.
pause
goto convert_image_menu

:convert_esd
cls
echo.
echo --- Convertir ESD a WIM ---
echo.
set /p "ESD_FILE_PATH=Ingrese la ruta completa del archivo ESD: "
if not exist "!ESD_FILE_PATH!" (
    echo El archivo no existe.
    pause
    goto convert_image_menu
)

echo.
echo Obteniendo informacion de los indices del archivo ESD...
dism /get-wiminfo /wimfile:"!ESD_FILE_PATH!"
echo.
set /p "INDEX_TO_CONVERT=Ingrese el numero de indice que desea convertir: "

for %%F in ("!ESD_FILE_PATH!") do (
    set "ESD_DIR=%%~dpF"
    set "ESD_NAME=%%~nF"
)
set "DEFAULT_DEST_PATH=!ESD_DIR!!ESD_NAME!_indice_!INDEX_TO_CONVERT!.wim"

echo.
echo Ruta de destino sugerida para el nuevo WIM:
echo !DEFAULT_DEST_PATH!
echo.
set /p "DEST_WIM_PATH=Ingrese la ruta completa (o presione Enter para usar la sugerida): "
if "!DEST_WIM_PATH!"=="" set "DEST_WIM_PATH=!DEFAULT_DEST_PATH!"

echo.
echo Convirtiendo... Esto puede tardar varios minutos.
dism /export-image /SourceImageFile:"!ESD_FILE_PATH!" /SourceIndex:!INDEX_TO_CONVERT! /DestinationImageFile:"!DEST_WIM_PATH!" /Compress:max /CheckIntegrity

if !errorlevel! equ 0 (
    echo.
    echo Conversion completada exitosamente.
    echo Nuevo archivo WIM creado en: "!DEST_WIM_PATH!"
    set "WIM_FILE_PATH=!DEST_WIM_PATH!"
    echo.
    echo La ruta del nuevo archivo WIM ha sido cargada en el script.
) else (
    echo.
    echo Error durante la conversion.
)
pause
goto convert_image_menu

:convert_vhd
cls
echo.
echo --- Convertir VHD/VHDX a WIM --- 
echo.
set /p "VHD_FILE_PATH=Ingrese la ruta completa del archivo VHD o VHDX: "
if not exist "!VHD_FILE_PATH!" ( 
    echo El archivo no existe. 
    pause
    goto convert_image_menu
)

for %%F in ("!VHD_FILE_PATH!") do (
    set "VHD_DIR=%%~dpF"
    set "VHD_NAME=%%~nF"
)
set "DEFAULT_DEST_PATH=!VHD_DIR!!VHD_NAME!.wim"

echo.
echo Ruta de destino sugerida para el nuevo WIM: 
echo !DEFAULT_DEST_PATH! 
echo.
set /p "DEST_WIM_PATH=Ingrese la ruta completa (o presione Enter para usar la sugerida): " 
if "!DEST_WIM_PATH!"=="" set "DEST_WIM_PATH=!DEFAULT_DEST_PATH!" 

echo.
echo --- Ingrese los metadatos para la nueva imagen WIM ---
echo.
set /p "IMAGE_NAME=Ingrese el NOMBRE de la imagen (ej: Captured VHD): "
set /p "IMAGE_DESC=Ingrese la DESCRIPCION de la imagen: "
if "!IMAGE_NAME!"=="" set "IMAGE_NAME=Captured VHD"

echo.
echo Montando el VHD... 
set "DRIVE_LETTER="
for /f "delims=" %%L in ('powershell -NoProfile -Command "(Mount-Vhd -Path '!VHD_FILE_PATH!' -PassThru | Get-Disk | Get-Partition | Get-Volume).DriveLetter"') do (
    if not defined DRIVE_LETTER set "DRIVE_LETTER=%%L"
)

if not defined DRIVE_LETTER (
    echo.
    echo Error: No se pudo montar el VHD o no se encontro una letra de unidad.
    pause
    goto convert_image_menu
)

echo VHD montado en la unidad: !DRIVE_LETTER!:
echo.
echo Capturando la imagen a WIM... Esto puede tardar mucho tiempo. 
dism /capture-image /imagefile:"!DEST_WIM_PATH!" /capturedir:!DRIVE_LETTER!:\ /name:"!IMAGE_NAME!" /description:"!IMAGE_DESC!" /compress:max /checkintegrity

if !errorlevel! equ 0 ( 
    echo.
    echo Captura completada exitosamente. 
    echo Nuevo archivo WIM creado en: "!DEST_WIM_PATH!" 
    set "WIM_FILE_PATH=!DEST_WIM_PATH!" 
    echo.
    echo La ruta del nuevo archivo WIM ha sido cargada en el script. 
) else (
    echo.
    echo Error durante la captura de la imagen.
)

echo.
echo Desmontando el VHD... 
powershell -NoProfile -Command "Dismount-Vhd -Path '!VHD_FILE_PATH!'" >nul 2>&1
echo VHD desmontado.
pause 
goto convert_image_menu

:: =============================================
::  Seccion para cambiar la edicion de Windows
:: =============================================
:cambio_edicion
cls
if "%IMAGE_MOUNTED%"=="0" (
    echo Necesita montar una imagen primero desde el menu 'Gestionar Imagen'.
    pause
    goto main_menu
)
echo.
echo Obteniendo informacion de la version y edicion de Windows de la imagen...
set "WIN_PRODUCT_NAME="
set "WIN_CURRENT_BUILD="
set "WIN_VERSION_FRIENDLY=Desconocida"
set "CURRENT_EDITION_DETECTED=Desconocida"
set "REG_LOAD_ERROR="

REM Intentar cargar el hive del registro de la imagen offline para obtener detalles
reg load HKLM\OfflineImage %MOUNT_DIR%\Windows\System32\config\SOFTWARE >nul 2>&1
if errorlevel 1 (
    echo ADVERTENCIA: No se pudo cargar el hive del registro de la imagen offline. Se intentara obtener informacion basica.
    set "REG_LOAD_ERROR=true"
) else (
    REM Obtener ProductName
    for /f "tokens=2,*" %%a in ('reg query "HKLM\OfflineImage\Microsoft\Windows NT\CurrentVersion" /v ProductName 2^>nul ^| findstr /R /C:"ProductName"') do (
        set "WIN_PRODUCT_NAME=%%b"
    )
    REM Obtener CurrentBuildNumber
    for /f "tokens=2,*" %%a in ('reg query "HKLM\OfflineImage\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul ^| findstr /R /C:"CurrentBuildNumber"') do (
        set "WIN_CURRENT_BUILD=%%b"
    )
    reg unload HKLM\OfflineImage >nul 2>&1
)

REM Determinar si es Windows 10 o Windows 11 basado en CurrentBuildNumber
if defined WIN_CURRENT_BUILD (
    if !WIN_CURRENT_BUILD! GEQ 22000 (
        set "WIN_VERSION_FRIENDLY=Windows 11"
    ) else if !WIN_CURRENT_BUILD! LSS 22000 (
        if !WIN_CURRENT_BUILD! GEQ 17763 (
            set "WIN_VERSION_FRIENDLY=Windows 10"
        ) else if !WIN_CURRENT_BUILD! GEQ 10240 (
            set "WIN_VERSION_FRIENDLY=Windows 10"
        ) else if !WIN_CURRENT_BUILD! EQU 9255 (
            set "WIN_VERSION_FRIENDLY=Windows 8.1"
        ) else if !WIN_CURRENT_BUILD! EQU 7601 (
            set "WIN_VERSION_FRIENDLY=Windows 7"
        ) else if !WIN_CURRENT_BUILD! EQU 7600 (
            set "WIN_VERSION_FRIENDLY=Windows 7"
        )
    )
)

REM Si no se pudo determinar por el build, intentar con ProductName
if "!WIN_VERSION_FRIENDLY!"=="Desconocida" (
    if defined WIN_PRODUCT_NAME (
        echo !WIN_PRODUCT_NAME! | findstr /I /C:"Windows 11" >nul
        if not errorlevel 1 set "WIN_VERSION_FRIENDLY=Windows 11"

        if "!WIN_VERSION_FRIENDLY!"=="Desconocida" (
            echo !WIN_PRODUCT_NAME! | findstr /I /C:"Windows 10" >nul
            if not errorlevel 1 set "WIN_VERSION_FRIENDLY=Windows 10"
        )
        if "!WIN_VERSION_FRIENDLY!"=="Desconocida" (
            echo !WIN_PRODUCT_NAME! | findstr /I /C:"Windows 8.1" >nul
            if not errorlevel 1 set "WIN_VERSION_FRIENDLY=Windows 8.1"
        )
        if "!WIN_VERSION_FRIENDLY!"=="Desconocida" (
            echo !WIN_PRODUCT_NAME! | findstr /I /C:"Windows Server 2012 R2" >nul
            if not errorlevel 1 set "WIN_VERSION_FRIENDLY=Windows 8.1"
        )
        if "!WIN_VERSION_FRIENDLY!"=="Desconocida" (
            echo !WIN_PRODUCT_NAME! | findstr /I /C:"Windows 7" >nul
            if not errorlevel 1 set "WIN_VERSION_FRIENDLY=Windows 7"
        )
        if "!WIN_VERSION_FRIENDLY!"=="Desconocida" (
            echo !WIN_PRODUCT_NAME! | findstr /I /C:"Windows Server 2008 R2" >nul
            if not errorlevel 1 set "WIN_VERSION_FRIENDLY=Windows 7"
        )
    )
)

REM Obtener la edicion actual usando DISM
for /f "tokens=*" %%i in ('dism /Image:%MOUNT_DIR% /Get-CurrentEdition 2^>nul ^| findstr /R /C:"Current Edition :"') do (
    set "line=%%i"
    set "line=!line:*Current Edition :=!"
    call :trim_leading_spaces line
    if defined line set "CURRENT_EDITION_DETECTED=!line!"
)

REM Traducir nombres de ediciones para visualizacion
set "DISPLAY_EDITION=!CURRENT_EDITION_DETECTED!"
if /I "!CURRENT_EDITION_DETECTED!"=="Core" set "DISPLAY_EDITION=Home"
if /I "!CURRENT_EDITION_DETECTED!"=="CoreSingleLanguage" set "DISPLAY_EDITION=Home Single Language"
if /I "!CURRENT_EDITION_DETECTED!"=="ProfessionalCountrySpecific" set "DISPLAY_EDITION=Professional Country Specific"
if /I "!CURRENT_EDITION_DETECTED!"=="ProfessionalEducation" set "DISPLAY_EDITION=Professional Education"
if /I "!CURRENT_EDITION_DETECTED!"=="ProfessionalSingleLanguage" set "DISPLAY_EDITION=Professional Single Language"
if /I "!CURRENT_EDITION_DETECTED!"=="ProfessionalWorkstation" set "DISPLAY_EDITION=Professional Workstation"
if /I "!CURRENT_EDITION_DETECTED!"=="IoTEnterprise" set "DISPLAY_EDITION=IoT Enterprise"
if /I "!CURRENT_EDITION_DETECTED!"=="IoTEnterpriseK" set "DISPLAY_EDITION=IoT Enterprise K"
if /I "!CURRENT_EDITION_DETECTED!"=="IoTEnterpriseS" set "DISPLAY_EDITION=IoT Enterprise LTSC"
if /I "!CURRENT_EDITION_DETECTED!"=="EnterpriseS" set "DISPLAY_EDITION=Enterprise LTSC"
if /I "!CURRENT_EDITION_DETECTED!"=="ServerRdsh" set "DISPLAY_EDITION=Server Rdsh"

cls
echo.
echo ================================================================
echo.
echo  Informacion de la Imagen en %MOUNT_DIR%:
echo    Sistema Operativo: !WIN_VERSION_FRIENDLY!
echo    Edicion Actual: !DISPLAY_EDITION!
echo.
echo ================================================================
echo.
set "edition_count=0"
for /L %%i in (1,1,30) do set "targetEdition_%%i="

set "column_output_buffer="
set "items_in_buffer=0"
set "column_width=40"

REM Comando para obtener las ediciones y procesarlas
for /f "tokens=1,* delims=:" %%a in ('dism /Image:%MOUNT_DIR% /Get-TargetEditions 2^>nul ^| findstr /R /C:"Target Edition :"') do (
    set "line=%%b"
    call :trim_leading_spaces line
    
    if defined line (
        set /a edition_count+=1
        set "targetEdition_!edition_count!=!line!"
        
        set "display_line=!line!"
        if /I "!line!"=="CoreSingleLanguage" set "display_line=Home Single Language"
        if /I "!line!"=="Core" set "display_line=Home"
        if /I "!line!"=="ProfessionalEducation" set "display_line=Professional Education"
        if /I "!line!"=="ProfessionalWorkstation" set "display_line=Professional Workstation"
        if /I "!line!"=="ProfessionalCountrySpecific" set "display_line=Professional Country Specific"
        if /I "!line!"=="ProfessionalSingleLanguage" set "display_line=Professional Single Language"
        if /I "!line!"=="ServerRdsh" set "display_line=Server Rdsh"
        if /I "!line!"=="IoTEnterprise" set "display_line=IoT Enterprise"
        if /I "!line!"=="IoTEnterpriseK" set "display_line=IoT Enterprise K"
        if /I "!line!"=="IoTEnterpriseS" set "display_line=IoT Enterprise LTSC"
        if /I "!line!"=="EnterpriseS" set "display_line=Enterprise LTSC"

        set "item_display_text=  !edition_count!. !display_line!"
        
        if !items_in_buffer! == 0 (
            set "column_output_buffer=!item_display_text!"
            set /a items_in_buffer=1
        ) else (
            set "temp_padding_buffer=!column_output_buffer!                                                                      "
            set "padded_first_item=!temp_padding_buffer:~0,%column_width%!"
            echo !padded_first_item!!item_display_text!
            set "column_output_buffer="
            set /a items_in_buffer=0
        )
    )
)

if !items_in_buffer! == 1 (
    echo !column_output_buffer!
)

echo.

if !edition_count! LSS 1 goto no_editions_found

echo ---------------------------------------------------------------------
echo.
echo  0. Volver al Menu Principal
echo.
set /p opcionEdicion="Seleccione la edicion a la que desea cambiar (0-!edition_count!): "

if "%opcionEdicion%"=="0" goto main_menu

set "isValidChoice="
if "%opcionEdicion%" NEQ "" (
    for /L %%N in (1,1,!edition_count!) do (
        if "%%N"=="%opcionEdicion%" (
            set "isValidChoice=true"
        )
    )
)

if not defined isValidChoice (
    echo.
    echo Opcion no valida: "%opcionEdicion%".
    echo Por favor, ingrese un numero entre 1 y !edition_count!, o 0 para volver.
    echo.
    pause
    goto cambio_edicion
)

set "selectedEdition=!targetEdition_%opcionEdicion%!"
if not defined selectedEdition (
    echo.
    echo ERROR CRITICO: No se pudo determinar la edicion seleccionada.
    echo.
    pause
    goto cambio_edicion
)

echo.
echo Cambiando la edicion de la imagen de !WIN_VERSION_FRIENDLY! !DISPLAY_EDITION! a: !selectedEdition!
echo. 
echo Esta operacion puede tardar varios minutos. Por favor, espere...
echo.
dism /Image:%MOUNT_DIR% /Set-Edition:!selectedEdition!
echo.
pause
goto main_menu

:no_editions_found
echo.
echo  No se encontraron ediciones de destino validas para la imagen.
echo  Asegurese de que la imagen sea valida y pueda ser actualizada.
echo  Tambien verifique que DISM este funcionando correctamente.
echo.
pause
goto cambio_edicion

:: =============================================
::  Seccion de Herramientas de Limpieza
:: =============================================
:limpieza
cls
if "%IMAGE_MOUNTED%"=="0" (
    echo Necesita montar una imagen primero desde el menu 'Gestionar Imagen'.
    pause
    goto main_menu
)
echo.
echo ================================================================
echo.
echo   Herramientas de Limpieza de Imagen
echo.
echo ================================================================
echo.
echo  En este menu puedes ejecutar diversas tareas para limpiar,
echo  verificar y reparar la imagen de Windows.
echo.
echo ================================================================
echo.
echo  1. Verificar Salud de Imagen
echo.
echo  2. Escaneo Avanzado de Salud de Imagen
echo.
echo  3. Reparar Imagen
echo.
echo  4. Escaneo y Reparacion SFC
echo.
echo  5. Analizar Almacen de Componentes de la Imagen
echo.
echo  6. Limpieza de Componentes
echo.
echo  7. Ejecutar Todas las Opciones
echo.
echo ----------------------------------------------------------------
echo.
echo  0. Volver al Menu Principal
echo.
set /p opcionL="Ingrese el numero de la opcion: "

if "%opcionL%"=="1" (
    echo.
    echo Verificando la salud de la imagen...
    DISM /Image:%MOUNT_DIR% /Cleanup-Image /CheckHealth
    pause
    goto limpieza
)
if "%opcionL%"=="2" (
    echo.
    echo Escaneando la imagen en busca de corrupcion...
    DISM /Image:%MOUNT_DIR% /Cleanup-Image /ScanHealth
    pause
    goto limpieza
)
if "%opcionL%"=="3" (
    echo.
    echo Reparando la imagen si es necesario... 
    DISM /Image:%MOUNT_DIR% /Cleanup-Image /RestoreHealth
    pause
    goto limpieza
)
if "%opcionL%"=="4" (
    echo.
    echo Verificando y reparando archivos del sistema...
    SFC /scannow /offbootdir=%MOUNT_DIR% /offwindir=%MOUNT_DIR%\Windows
    pause
    goto limpieza
)
if "%opcionL%"=="5" (
    echo.
    echo Analizando Almacen de componentes...
    DISM /Image:%MOUNT_DIR% /Cleanup-Image /AnalyzeComponentStore
    pause
    goto limpieza
)
if "%opcionL%"=="6" (
    echo.
    echo Limpiando Almacen de componentes...
    DISM /Cleanup-Image /Image:%MOUNT_DIR% /StartComponentCleanup /ResetBase /ScratchDir:%Scratch_DIR%
    pause
    goto limpieza
)
if "%opcionL%"=="7" (
    echo.
    echo [PASO 1 de 5] Verificando la salud de la imagen...
    DISM /Image:%MOUNT_DIR% /Cleanup-Image /CheckHealth
    echo.
    echo [PASO 2 de 5] Escaneando la imagen en busca de corrupcion...
    DISM /Image:%MOUNT_DIR% /Cleanup-Image /ScanHealth
    echo.
    echo [PASO 3 de 5] Reparando la imagen si es necesario...
    DISM /Image:%MOUNT_DIR% /Cleanup-Image /RestoreHealth
    echo.
    echo [PASO 4 de 5] Verificando y reparando archivos del sistema...
    SFC /scannow /offbootdir=%MOUNT_DIR% /offwindir=%MOUNT_DIR%\Windows
    echo.
    echo [PASO 5 de 5] Analizando y ejecutando limpieza de componentes...
    set "cleanupRecommended=No"
    for /f "tokens=2 delims=:" %%a in ('DISM /Image:%MOUNT_DIR% /Cleanup-Image /AnalyzeComponentStore ^| findstr /I /C:"Component Store Cleanup Recommended"') do (
        set "result=%%a"
        call :trim_leading_spaces result
        if /I "!result!"=="Yes" set "cleanupRecommended=Yes"
    )
    if "!cleanupRecommended!"=="Yes" (
        echo Se recomienda la limpieza del almacen de componentes. Procediendo...
        DISM /Cleanup-Image /Image:%MOUNT_DIR% /StartComponentCleanup /ResetBase /ScratchDir:%Scratch_DIR%
    ) else (
        echo La limpieza del almacen de componentes no es necesaria en este momento.
    )
    pause
    goto limpieza
)
if "%opcionL%"=="0" goto main_menu
echo Opcion no valida. Intente nuevamente.
pause
goto limpieza

:: Subrutina para eliminar espacios al inicio de una variable
:trim_leading_spaces
set "temp_var=!%1!"
:loop_trim
if defined temp_var if "%temp_var:~0,1%"==" " (
    set "temp_var=!temp_var:~1!"
    goto loop_trim
)
set "%1=%temp_var%"
goto :eof
