@echo off
title Administrador de Imagen offline by SOFTMAXTER
color 0A
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

:menu
cls
echo.
echo =========================================================================
echo.
echo  Administrador de Imagen offline by SOFTMAXTER
echo.
echo =========================================================================
echo.
echo  Este script permite cambiar la edicion de una imagen offline de Windows
echo  y ejecutar tareas de limpieza para mantenerla en optimas condiciones.
echo.
echo =========================================================================
echo.
echo  1. Cambiar Edicion de Windows
echo    (Muestra las ediciones disponibles para la imagen actual y permite cambiarla)
echo.
echo  2. Herramientas de Limpieza
echo    (Ejecuta tareas de mantenimiento, verificacion y reparacion de la imagen)
echo.
echo ----------------------------------------------------------------
echo.
echo  0. Salir
echo.
set /p opcionM="Ingrese el numero de la opcion: "

if "%opcionM%"=="1" goto cambio_edicion
if "%opcionM%"=="2" goto limpieza
if "%opcionM%"=="0" (
    echo Saliendo...
    exit /b
)
echo Opcion no valida.
Intente nuevamente.
pause
goto menu

:: =============================================
::  Seccion para cambiar la edicion de Windows (Dinámico)
:: =============================================
:cambio_edicion
cls
echo.
echo Obteniendo informacion de la version y edicion de Windows de la imagen...
set "WIN_PRODUCT_NAME="
set "WIN_CURRENT_BUILD="
set "WIN_VERSION_FRIENDLY=Desconocida"
set "CURRENT_EDITION_DETECTED=Desconocida"
set "REG_LOAD_ERROR="

REM Intentar cargar el hive del registro de la imagen offline para obtener detalles
reg load HKLM\OfflineImage C:\TEMP\Windows\System32\config\SOFTWARE >nul 2>&1
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
    ) else if !WIN_CURRENT_BUILD! LSS 22000 (  REM Es anterior a Windows 11
        if !WIN_CURRENT_BUILD! GEQ 17763 (     REM Builds de Windows 10 (ej. 1809 en adelante hasta antes de Win11)
            set "WIN_VERSION_FRIENDLY=Windows 10"
        ) else if !WIN_CURRENT_BUILD! GEQ 10240 ( REM Builds anteriores de Windows 10 (ej. 1507 hasta antes de 1809)
            set "WIN_VERSION_FRIENDLY=Windows 10"
        ) else if !WIN_CURRENT_BUILD! EQU 9255 (  REM Build de Windows 8.1 (9600)
            set "WIN_VERSION_FRIENDLY=Windows 8.1"
        ) else if !WIN_CURRENT_BUILD! EQU 7601 (  REM Build de Windows 7 SP1 (7601)
            set "WIN_VERSION_FRIENDLY=Windows 7"
        ) else if !WIN_CURRENT_BUILD! EQU 7600 (  REM Build de Windows 7 RTM (7600)
            set "WIN_VERSION_FRIENDLY=Windows 7"
        )
        REM Si WIN_VERSION_FRIENDLY sigue siendo "Desconocida" aquí, el build no coincide
        REM o es de un sistema operativo aún más antiguo no contemplado (Vista, XP).
    )
)

REM Si no se pudo determinar por el build, intentar con ProductName (menos preciso para la distincion 10/11 sin el build, pero útil como fallback)
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
            if not errorlevel 1 set "WIN_VERSION_FRIENDLY=Windows 8.1" REM Windows Server 2012 R2 comparte kernel con 8.1
        )
        if "!WIN_VERSION_FRIENDLY!"=="Desconocida" (
            echo !WIN_PRODUCT_NAME! | findstr /I /C:"Windows 7" >nul
            if not errorlevel 1 set "WIN_VERSION_FRIENDLY=Windows 7"
        )
        if "!WIN_VERSION_FRIENDLY!"=="Desconocida" (
            echo !WIN_PRODUCT_NAME! | findstr /I /C:"Windows Server 2008 R2" >nul
            if not errorlevel 1 set "WIN_VERSION_FRIENDLY=Windows 7" REM Windows Server 2008 R2 comparte kernel con Win7
        )
    )
)

REM Obtener la edicion actual usando DISM
for /f "tokens=*" %%i in ('dism /Image:C:\TEMP /Get-CurrentEdition 2^>nul ^| findstr /R /C:"Current Edition :"') do (
    set "line=%%i"
    set "line=!line:*Current Edition :=!"
    call :trim_leading_spaces line
    if defined line set "CURRENT_EDITION_DETECTED=!line!"
)

REM Traducir "Core" a "Home" para la visualizacion
set "DISPLAY_EDITION=!CURRENT_EDITION_DETECTED!"
if /I "!CURRENT_EDITION_DETECTED!"=="Core" (
    set "DISPLAY_EDITION=Home"
)

if /I "!CURRENT_EDITION_DETECTED!"=="CoreSingleLanguage" (
    set "DISPLAY_EDITION=Home Single Language"
)

if /I "!CURRENT_EDITION_DETECTED!"=="ProfessionalCountrySpecific" (
    set "DISPLAY_EDITION=Professional Country Specific"
)

if /I "!CURRENT_EDITION_DETECTED!"=="ProfessionalEducation" (
    set "DISPLAY_EDITION=Professional Education"
)

if /I "!CURRENT_EDITION_DETECTED!"=="ProfessionalSingleLanguage" (
    set "DISPLAY_EDITION=Professional ingle Language"
)
if /I "!CURRENT_EDITION_DETECTED!"=="ProfessionalWorkstation" (
    set "DISPLAY_EDITION=Professional Workstation"
)

if /I "!CURRENT_EDITION_DETECTED!"=="IoTEnterprise" (
    set "DISPLAY_EDITION=IoT Enterprise"
)

if /I "!CURRENT_EDITION_DETECTED!"=="IoTEnterpriseK" (
    set "DISPLAY_EDITION=IoT Enterprise K"
)

if /I "!CURRENT_EDITION_DETECTED!"=="IoTEnterpriseS" (
    set "DISPLAY_EDITION=IoT Enterprise LTSC"
)

if /I "!CURRENT_EDITION_DETECTED!"=="EnterpriseS" (
    set "DISPLAY_EDITION=Enterprise LTSC"
)

if /I "!CURRENT_EDITION_DETECTED!"=="ServerRdsh" (
    set "DISPLAY_EDITION=Server Rdsh"
)

cls
echo.
echo ================================================================
echo.
echo  Informacion de la Imagen en C:\TEMP:
echo    Sistema Operativo: !WIN_VERSION_FRIENDLY!
echo    Edicion Actual: !DISPLAY_EDITION!
echo.
echo ================================================================
echo.

set "edition_count=0"
REM Limpiar variables de ediciones anteriores por si se vuelve a ejecutar
for /L %%i in (1,1,30) do set "targetEdition_%%i="

set "column_output_buffer="
set "items_in_buffer=0"
set "column_width=40" REM Ajuste este ancho según sea necesario para su pantalla

REM Comando para obtener las ediciones y procesarlas
for /f "tokens=1,* delims=:" %%a in ('dism /Image:C:\TEMP /Get-TargetEditions 2^>nul ^| findstr /R /C:"Target Edition :"') do (
    set "line=%%b"
    call :trim_leading_spaces line
    
    if defined line (
        set /a edition_count+=1
        REM Almacenar el nombre de la edición original de DISM para el comando Set-Edition
        set "targetEdition_!edition_count!=!line!" 
        
        REM Traducir los nombres de las ediciones para fines de visualización
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
            REM First item in a pair, store it
            set "column_output_buffer=!item_display_text!"
            set /a items_in_buffer=1
        ) else (
            REM Segundo artículo del par. Rellene el primero y luego imprima ambos.
            set "temp_padding_buffer=!column_output_buffer!                                                                      " REM Ensure enough spaces for padding
            set "padded_first_item=!temp_padding_buffer:~0,%column_width%!"
            echo !padded_first_item!!item_display_text!
            set "column_output_buffer="
            set /a items_in_buffer=0
        )
    )
)

REM If Hubo un número impar de ediciones; la última aún está en el buffer. Imprímela.
if !items_in_buffer! == 1 (
    echo !column_output_buffer!
)

echo.

REM Nueva estructura para el chequeo de edition_count usando goto
if !edition_count! LSS 1 goto no_editions_found

REM Si llegamos aqui, edition_count es 1 o mas.
echo ---------------------------------------------------------------------
echo.
echo  0. Volver al Menu Principal
echo.
set /p opcionEdicion="Seleccione la edicion a la que desea cambiar (0-!edition_count!): "

if "%opcionEdicion%"=="0" goto menu

REM Validar que la opcionEdicion sea un número válido dentro del rango de ediciones encontradas
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
    echo  Opcion no valida: "%opcionEdicion%".
    echo  Por favor, ingrese un numero entre 1 y !edition_count!, o 0 para volver.
    echo.
    pause
    goto cambio_edicion
)

REM Si llegamos aquí, opcionEdicion es un número válido entre 1 y edition_count
set "selectedEdition=!targetEdition_%opcionEdicion%!"
if not defined selectedEdition (
    echo.
    echo  ERROR CRITICO: No se pudo determinar la edicion seleccionada para el numero "%opcionEdicion%".
    echo  Verifique las variables targetEdition_N.
    echo.
    pause
    goto cambio_edicion
)
if "%selectedEdition%"=="" (
    echo.
    echo  ERROR CRITICO: La edicion seleccionada esta vacia para el numero "%opcionEdicion%".
    echo.
    pause
    goto cambio_edicion
)

echo.
echo  Cambiando la edicion de la imagen de !WIN_VERSION_FRIENDLY! !DISPLAY_EDITION! a: !selectedEdition!
echo. 
echo  Esta operacion puede tardar varios minutos. Por favor, espere...
echo.
dism /Image:C:\TEMP /Set-Edition:!selectedEdition!
echo.
pause
goto cambio_edicion

:no_editions_found
echo.
echo  No se encontraron ediciones de destino validas para la imagen en C:\TEMP.
echo  Asegurese de que la imagen en C:\TEMP sea valida, este montada (si es un .WIM)
echo  y que pueda ser actualizada a otras ediciones.
echo  Tambien verifique que DISM este funcionando correctamente.
echo.
pause
goto cambio_edicion

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

:: =============================================
::  Seccion de Herramientas de Limpieza
:: =============================================
:limpieza
cls
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
echo     (Revisa el estado de la imagen sin modificarla)
echo.
echo  2. Escaneo Avanzado de Salud de Imagen
echo     (Realiza un escaneo más exhaustivo de la imagen para detectar corrupcion en
echo      el almacen de componentes. No realiza reparaciones.)
echo.
echo  3. Reparar Imagen
echo     (Restaura la imagen a un estado saludable)
echo.
echo  4. Escaneo y Reparacion SFC
echo     (Ejecuta la verificacion y reparacion de archivos del sistema)
echo.
echo  5. Analizar Almacen de Componentes de la Imagen
echo     (Genera un informe sobre el tamano del almacen de componentes y
echo     si se recomienda una limpieza. No modifica la imagen.)
echo.
echo  6. Limpieza de Componentes
echo     (Elimina componentes innecesarios para liberar espacio)
echo.
echo  7. Ejecutar Todas las Opciones
echo     (Realiza todas las tareas de mantenimiento en secuencia)
echo.
echo ----------------------------------------------------------------
echo.
echo  0. Volver al Menu Principal
echo.
set /p opcionL="Ingrese el numero de la opcion: "

if "%opcionL%"=="1" (
    echo.
    echo  Verificando salud de la imagen...
    DISM /Image:C:\TEMP /Cleanup-Image /CheckHealth
    pause
    goto limpieza
)

if "%opcionL%"=="2" (
    echo.
    echo  Escaneando imagen en busca de corrupcion...
    DISM /Image:C:\TEMP /Cleanup-Image /ScanHealth
    pause
    goto limpieza
)

if "%opcionL%"=="3" (
    echo.
    echo  Reparando imagen...
    DISM /Image:C:\TEMP /Cleanup-Image /RestoreHealth
    pause
    goto limpieza
)

if "%opcionL%"=="4" (
    echo.
    echo  Ejecutando escaneo y reparacion del sistema...
    SFC /scannow /offbootdir=C:\TEMP /offwindir=C:\TEMP\Windows
    pause
    goto limpieza
)

if "%opcionL%"=="5" (
    echo.
    echo  Analizando el almacen de componentes...
    DISM /Image:C:\TEMP /Cleanup-Image /AnalyzeComponentStore
    pause
    goto limpieza
)

if "%opcionL%"=="6" (
    echo.
    echo  Limpiando componentes...
    DISM /Cleanup-Image /Image:C:\TEMP /StartComponentCleanup /ResetBase /ScratchDir:C:\TEMP1
    pause
    goto limpieza
)

if "%opcionL%"=="7" (
    echo.
    echo  Ejecutando todas las opciones de limpieza...
    DISM /Image:C:\TEMP /Cleanup-Image /CheckHealth
    DISM /Image:C:\TEMP /Cleanup-Image /ScanHealth
    DISM /Image:C:\TEMP /Cleanup-Image /RestoreHealth
    SFC /scannow /offbootdir=C:\TEMP /offwindir=C:\TEMP\Windows
    DISM /Cleanup-Image /Image:C:\TEMP /StartComponentCleanup /ResetBase /ScratchDir:C:\TEMP1
    pause
    goto limpieza
)

if "%opcionL%"=="0" goto menu

echo  Opcion no valida.
Intente nuevamente.
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