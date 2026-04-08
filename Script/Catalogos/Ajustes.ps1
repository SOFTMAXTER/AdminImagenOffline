# --- CATALOGO CENTRAL DE AJUSTES (OPTIMIZADO PARA OFFLINE / WIM) ---
# Contiene solo ajustes basados en REGISTRO que pueden aplicarse a una imagen montada.

$script:SystemTweaks = @(

    # =========================================================
    # ANTI-BLOATWARE
    # =========================================================
    [PSCustomObject]@{
        Name           = "Bloquear Reinstalacion de Apps Basura (Consumer Features)"
        Category       = "Anti-Bloatware"
        Description    = "Impide que Windows descargue automaticamente Candy Crush, Spotify y otras apps patrocinadas al conectar a internet."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
        RegistryKey    = "DisableWindowsConsumerFeatures"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Bloquear Sugerencias en el Inicio (Soft Landing)"
        Category       = "Anti-Bloatware"
        Description    = "Evita que Windows muestre sugerencias y consejos de 'Bienvenida' que a menudo instalan software no deseado."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
        RegistryKey    = "DisableSoftLanding"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },

    # =========================================================
    # RENDIMIENTO DEL SISTEMA (JUEGOS Y GENERAL)
    # =========================================================
    [PSCustomObject]@{
        Name           = "Maximo Rendimiento Multimedia (SystemResponsiveness 0)"
        Category       = "Rendimiento del Sistema"
        Description    = "Asigna el 100% de la CPU a juegos y multimedia, eliminando la reserva del 20% para procesos en segundo plano."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
        RegistryKey    = "SystemResponsiveness"
        EnabledValue   = 0
        DefaultValue   = 20
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Prioridad de GPU Extrema para Juegos"
        Category       = "Rendimiento del Sistema"
        Description    = "Fuerza al planificador multimedia a dar maxima prioridad grafica a las aplicaciones de pantalla completa."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"
        RegistryKey    = "GPU Priority"
        EnabledValue   = 8
        DefaultValue   = 2
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Prioridad de CPU Extrema para Juegos"
        Category       = "Rendimiento del Sistema"
        Description    = "Fuerza al planificador multimedia a dar prioridad alta de CPU a los juegos."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"
        RegistryKey    = "Priority"
        EnabledValue   = 6
        DefaultValue   = 2
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Desactivar Grabacion en Segundo Plano (GameDVR)"
        Category       = "Rendimiento del Sistema"
        Description    = "Deshabilita la funcion de Xbox Game DVR a nivel de directiva de maquina para evitar tirones de FPS."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PolicyManager\default\ApplicationManagement\AllowGameDVR"
        RegistryKey    = "value"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Habilitar Programacion de GPU (HAGS)"
        Category       = "Rendimiento del Sistema"
        Description    = "Hardware Accelerated GPU Scheduling. Reduce latencia en juegos (requiere hardware compatible)."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
        RegistryKey    = "HwSchMode"
        EnabledValue   = 2
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Priorizar Aplicacion en Primer Plano (CPU Boost)"
        Category       = "Rendimiento del Sistema"
        Description    = "Modifica el planificador para dar mas prioridad de CPU a la ventana activa."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\PriorityControl"
        RegistryKey    = "Win32PrioritySeparation"
        EnabledValue   = 26
        DefaultValue   = 2
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Optimizar Uso de Memoria NTFS"
        Category       = "Rendimiento del Sistema"
        Description    = "Aumenta la cache del sistema de archivos. Recomendado para equipos con mas de 8GB de RAM."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FileSystem"
        RegistryKey    = "NtfsMemoryUsage"
        EnabledValue   = 2
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Acelerar Apagado (WaitToKillService)"
        Category       = "Rendimiento del Sistema"
        Description    = "Reduce el tiempo de espera para cerrar servicios al apagar (2000ms)."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control"
        RegistryKey    = "WaitToKillServiceTimeout"
        EnabledValue   = "2000"
        DefaultValue   = "5000"
        RegistryType   = "String"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Indexacion 'Mejorada' (Forzar Clasico)"
        Category       = "Rendimiento del Sistema"
        Description    = "Evita que Windows indexe todo el disco duro, limitandolo a bibliotecas y escritorio para ahorrar CPU/Disco."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Search"
        RegistryKey    = "EnableEnhancedSearchMode"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Limitar CPU de Windows Defender (25%)"
        Category       = "Rendimiento del Sistema"
        Description    = "Evita que los escaneos de Defender acaparen toda la CPU."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender\Scan"
        RegistryKey    = "AvgCPULoadFactor"
        EnabledValue   = 25
        DefaultValue   = 50
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Superfetch / SysMain"
        Category       = "Rendimiento del Sistema"
        Description    = "Recomendado para discos SSD. Evita la pre-carga constante en memoria y ahorra desgaste de escritura."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SysMain"
        RegistryKey    = "Start"
        EnabledValue   = 4
        DefaultValue   = 2
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Desactivar Hibernacion (Hiberfil.sys)"
        Category       = "Rendimiento del Sistema"
        Description    = "Libera gigabytes de espacio en el disco C: desactivando el archivo de hibernacion de Windows."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
        RegistryKey    = "HibernateEnabled"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Aislamiento del Nucleo (VBS / Memory Integrity)"
        Category       = "Rendimiento del Sistema"
        Description    = "Mejora el rendimiento en juegos (hasta un 15%) apagando la virtualizacion de seguridad. (Reduce seguridad)."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
        RegistryKey    = "Enabled"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Mapas Descargados (MapsBroker)"
        Category       = "Rendimiento del Sistema"
        Description    = "Apaga el administrador de mapas offline. Excelente para ahorrar RAM si no usas la app Mapas de Windows."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\MapsBroker"
        RegistryKey    = "Start"
        EnabledValue   = 4
        DefaultValue   = 2
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Cola de Impresion (Print Spooler)"
        Category       = "Rendimiento del Sistema"
        Description    = "ATENCION: Activa esto SOLO si jamas vas a usar una impresora fisica o imprimir en PDF. Ahorra RAM y cierra brechas de seguridad."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Spooler"
        RegistryKey    = "Start"
        EnabledValue   = 4
        DefaultValue   = 2
        RegistryType   = "DWord"
    },

    # =========================================================
    # RENDIMIENTO UI E INTERFAZ
    # =========================================================
    [PSCustomObject]@{
        Name           = "Deshabilitar Retraso de Inicio (StartupDelay)"
        Category       = "Rendimiento UI"
        Description    = "Elimina la demora artificial al cargar programas de inicio a nivel de maquina."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize"
        RegistryKey    = "StartupDelayInMSec"
        EnabledValue   = 0
        DefaultValue   = 1000
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Aumentar Cache de Iconos (4MB)"
        Category       = "Rendimiento UI"
        Description    = "Evita que los iconos se recarguen o parpadeen en el Explorador."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"
        RegistryKey    = "MaxCachedIcons"
        EnabledValue   = "4096"
        DefaultValue   = "500"
        RegistryType   = "String"
    },

    # =========================================================
    # WINDOWS 11 UI
    # =========================================================
    [PSCustomObject]@{
        Name           = "Deshabilitar Windows Copilot"
        Category       = "Windows 11 UI"
        Description    = "Elimina el asistente de IA de la barra de tareas mediante directiva de maquina."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
        RegistryKey    = "TurnOffWindowsCopilot"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Bloquear Widgets y Noticias (Directiva GPO)"
        Category       = "Windows 11 UI"
        Description    = "Desactiva el panel de Widgets (Tiempo/Noticias) para ahorrar RAM en todo el sistema."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Dsh"
        RegistryKey    = "AllowNewsAndInterests"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Search Highlights (Dibujos)"
        Category       = "Windows 11 UI"
        Description    = "Quita los iconos animados del cuadro de busqueda a nivel de maquina."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
        RegistryKey    = "EnableSearchHighlights"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Ocultar Boton de Vista de Tareas (Global)"
        Category       = "Windows 11 UI"
        Description    = "Elimina el icono de multiples escritorios de la barra de tareas para todos los usuarios."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer"
        RegistryKey    = "HideTaskViewButton"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Desenfoque (Blur) en Pantalla de Bloqueo"
        Category       = "Windows 11 UI"
        Description    = "Muestra el fondo de la pantalla de inicio de sesion nitido, sin el efecto acrilico borroso que consume GPU."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\System"
        RegistryKey    = "DisableAcrylicBackgroundOnLogon"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },

    # =========================================================
    # PRIVACIDAD Y TELEMETRIA
    # =========================================================
    [PSCustomObject]@{
        Name           = "Desactivar ID de Publicidad (Global)"
        Category       = "Privacidad"
        Description    = "Impide el rastreo para anuncios personalizados a nivel de maquina."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
        RegistryKey    = "Enabled"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Desactivar Telemetria (AllowTelemetry)"
        Category       = "Privacidad"
        Description    = "Reduce el envio de datos a Microsoft al minimo (Security Only)."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
        RegistryKey    = "AllowTelemetry"
        EnabledValue   = 0
        DefaultValue   = 3
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Windows Recall (IA Snapshots)"
        Category       = "Privacidad"
        Description    = "Evita que la IA saque capturas de tu actividad."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"
        RegistryKey    = "DisableAIDataAnalysis"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Cortana"
        Category       = "Privacidad"
        Description    = "Desactiva Cortana por directiva global."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
        RegistryKey    = "AllowCortana"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Busqueda Web (Bing) en Inicio"
        Category       = "Privacidad"
        Description    = "Evita que lo que escribes en el menu inicio se envie a internet."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
        RegistryKey    = "DisableWebSearch"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Apps en Segundo Plano (Global)"
        Category       = "Privacidad"
        Description    = "Impide que las apps de la tienda se ejecuten sin abrirse para todos los usuarios."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"
        RegistryKey    = "LetAppsRunInBackground"
        EnabledValue   = 2
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Desactivar Windows Error Reporting (WER)"
        Category       = "Privacidad"
        Description    = "Evita que Windows envie reportes de bloqueos y fallos de aplicaciones a los servidores de Microsoft."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"
        RegistryKey    = "Disabled"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Seguimiento de Lanzamiento de Apps (Global)"
        Category       = "Privacidad"
        Description    = "Impide que Windows rastree que programas abres para personalizar el menu de inicio de los usuarios."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\EdgeUI"
        RegistryKey    = "DisableMFUTracking"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Desactivar Diagnostico de Experiencia del Usuario (DiagTrack)"
        Category       = "Privacidad"
        Description    = "Apaga el servicio 'Connected User Experiences and Telemetry' a nivel de kernel."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\DiagTrack"
        RegistryKey    = "Start"
        EnabledValue   = 4
        DefaultValue   = 2
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Servicio de Rastreo WAP (dmwappushservice)"
        Category       = "Privacidad"
        Description    = "Apaga el servicio de enrutamiento de mensajes push que Microsoft usa para recopilar telemetria."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\dmwappushservice"
        RegistryKey    = "Start"
        EnabledValue   = 4
        DefaultValue   = 3
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Servicio de Politica de Diagnostico (DPS)"
        Category       = "Privacidad"
        Description    = "Desactiva el diagnostico de problemas del sistema, reduciendo el uso del disco y CPU en segundo plano."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\DPS"
        RegistryKey    = "Start"
        EnabledValue   = 4
        DefaultValue   = 2
        RegistryType   = "DWord"
    },

    # =========================================================
    # RED / NETWORK
    # =========================================================
    [PSCustomObject]@{
        Name           = "Liberar Ancho de Banda (NetworkThrottling)"
        Category       = "Red"
        Description    = "Desactiva el limite de red para multimedia, liberando la conexion."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
        RegistryKey    = "NetworkThrottlingIndex"
        EnabledValue   = "4294967295"
        DefaultValue   = "10"
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Servicio NDU (Fugas de RAM)"
        Category       = "Red"
        Description    = "Desactiva el monitor de uso de datos de red, que a menudo causa fugas de memoria no paginada."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Ndu"
        RegistryKey    = "Start"
        EnabledValue   = 4
        DefaultValue   = 2
        RegistryType   = "DWord"
    },

    # =========================================================
    # EXTRAS / COMPORTAMIENTO
    # =========================================================
    [PSCustomObject]@{
        Name           = "Restaurar Menu Contextual Clasico (Win11 Global)"
        Category       = "Extras"
        Description    = "Elimina el 'Mostrar mas opciones' y muestra el menu completo a nivel de maquina."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
        RegistryKey    = "(Default)"
        EnabledValue   = ""
        DefaultValue   = "DeleteKey"
        RegistryType   = "String"
    },
    [PSCustomObject]@{
        Name           = "Desactivar Reinicio Automatico en Pantalla Azul (BSOD)"
        Category       = "Extras"
        Description    = "Permite leer el codigo de error de una pantalla azul de la muerte sin que el PC se reinicie inmediatamente."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\CrashControl"
        RegistryKey    = "AutoReboot"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Aumentar Limite de Ruta Larga (LongPathsEnabled)"
        Category       = "Extras"
        Description    = "Permite que Windows maneje rutas de archivos que exceden los clasicos 260 caracteres en todo el sistema."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FileSystem"
        RegistryKey    = "LongPathsEnabled"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Notificaciones y Centro de Accion (Global)"
        Category       = "Extras"
        Description    = "Oculta los avisos emergentes y desactiva completamente el centro de notificaciones para todos."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer"
        RegistryKey    = "DisableNotificationCenter"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    }
)
