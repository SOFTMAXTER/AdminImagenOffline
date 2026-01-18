# --- CATALOGO CENTRAL DE AJUSTES (OPTIMIZADO PARA OFFLINE / WIM) ---
# Contiene solo ajustes basados en REGISTRO que pueden aplicarse a una imagen montada.

$script:SystemTweaks = @(

    # =========================================================
    # NUEVO: BLOQUEO DE REINSTALACION (Consumer Features)
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
    # RENDIMIENTO DEL SISTEMA (Reg)
    # =========================================================
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
        Name           = "Reducir Latencia del Sistema (SystemResponsiveness)"
        Category       = "Rendimiento del Sistema"
        Description    = "Libera recursos de CPU reservados para servicios en segundo plano, mejorando juegos y multimedia."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
        RegistryKey    = "SystemResponsiveness"
        EnabledValue   = 10
        DefaultValue   = 20
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

    # =========================================================
    # RENDIMIENTO UI (Interfaz)
    # =========================================================
    [PSCustomObject]@{
        Name           = "Eliminar Retraso de Menus (MenuShowDelay)"
        Category       = "Rendimiento UI"
        Description    = "Hace que los menus contextuales aparezcan instantaneamente (0ms)."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_CURRENT_USER\Control Panel\Desktop"
        RegistryKey    = "MenuShowDelay"
        EnabledValue   = "0"
        DefaultValue   = "400"
        RegistryType   = "String"
    },
    [PSCustomObject]@{
        Name           = "Deshabilitar Retraso de Inicio (StartupDelay)"
        Category       = "Rendimiento UI"
        Description    = "Elimina la demora artificial al cargar programas de inicio."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize"
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
    # WINDOWS 11 / BARRA DE TAREAS
    # =========================================================
    [PSCustomObject]@{
        Name           = "Deshabilitar Windows Copilot"
        Category       = "Windows 11 UI"
        Description    = "Elimina el asistente de IA de la barra de tareas."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows\WindowsCopilot"
        RegistryKey    = "TurnOffWindowsCopilot"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Alineacion Izquierda (Barra Tareas)"
        Category       = "Windows 11 UI"
        Description    = "Mueve el boton de Inicio a la izquierda (Estilo Win10)."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        RegistryKey    = "TaskbarAl"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Ocultar Icono Chat/Teams"
        Category       = "Windows 11 UI"
        Description    = "Elimina el icono de Chat personal de la barra de tareas."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        RegistryKey    = "TaskbarMn"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
	[PSCustomObject]@{
        Name           = "Bloquear Widgets y Noticias (Directiva GPO)"
        Category       = "Windows 11 UI"
        Description    = "Desactiva el panel de Widgets (Tiempo/Noticias) para ahorrar RAM."
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
        Description    = "Quita los iconos animados del cuadro de busqueda."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
        RegistryKey    = "EnableSearchHighlights"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },

    # =========================================================
    # PRIVACIDAD Y TELEMETRÍA
    # =========================================================
    [PSCustomObject]@{
        Name           = "Desactivar ID de Publicidad"
        Category       = "Privacidad"
        Description    = "Impide el rastreo para anuncios personalizados."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
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
        Description    = "Desactiva Cortana por directiva."
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
        Description    = "Impide que las apps de la tienda se ejecuten sin abrirse."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"
        RegistryKey    = "LetAppsRunInBackground"
        EnabledValue   = 2
        DefaultValue   = 0
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
    # COMPORTAMIENTO Y EXTRAS
    # =========================================================
    [PSCustomObject]@{
        Name           = "Mostrar Extensiones de Archivo"
        Category       = "Extras"
        Description    = "Muestra siempre .exe, .bat, etc. por seguridad."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        RegistryKey    = "HideFileExt"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Abrir Explorador en 'Este Equipo'"
        Category       = "Extras"
        Description    = "Evita abrir en 'Acceso Rapido' o 'Recientes'."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        RegistryKey    = "LaunchTo"
        EnabledValue   = 1
        DefaultValue   = 2
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Modo Oscuro (Aplicaciones)"
        Category       = "Visual"
        Description    = "Fuerza el tema oscuro en las apps."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        RegistryKey    = "AppsUseLightTheme"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Modo Oscuro (Sistema)"
        Category       = "Visual"
        Description    = "Fuerza el tema oscuro en barra de tareas y menu inicio."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        RegistryKey    = "SystemUsesLightTheme"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = "Restaurar Menu Contextual Clasico (Win11)"
        Category       = "Visual"
        Description    = "Elimina el 'Mostrar mas opciones' y muestra el menu completo."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
        RegistryKey    = "(Default)"
        EnabledValue   = ""
        DefaultValue   = "DeleteKey"
        RegistryType   = "String"
    },
    [PSCustomObject]@{
        Name           = "Desactivar Sticky Keys (5 veces Shift)"
        Category       = "Extras"
        Description    = "Evita que aparezca el dialogo al pulsar Shift repetidamente."
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_CURRENT_USER\Control Panel\Accessibility\StickyKeys"
        RegistryKey    = "Flags"
        EnabledValue   = "506"
        DefaultValue   = "510"
        RegistryType   = "String"
    }
)
