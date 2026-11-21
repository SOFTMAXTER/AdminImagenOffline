$script:SystemTweaks = @(

    # =========================================================
    # ANTI-BLOATWARE
    # =========================================================
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t01')
        Category       = (Get-AIOString 'catalog.tweaks.cat.antibloat')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t01')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
        RegistryKey    = "DisableWindowsConsumerFeatures"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t02')
        Category       = (Get-AIOString 'catalog.tweaks.cat.antibloat')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t02')
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
        Name           = (Get-AIOString 'catalog.tweaks.name.t03')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t03')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
        RegistryKey    = "SystemResponsiveness"
        EnabledValue   = 0
        DefaultValue   = 20
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t04')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t04')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"
        RegistryKey    = "GPU Priority"
        EnabledValue   = 8
        DefaultValue   = 2
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t05')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t05')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"
        RegistryKey    = "Priority"
        EnabledValue   = 6
        DefaultValue   = 2
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t06')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t06')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PolicyManager\default\ApplicationManagement\AllowGameDVR"
        RegistryKey    = "value"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t07')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t07')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
        RegistryKey    = "HwSchMode"
        EnabledValue   = 2
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t08')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t08')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\PriorityControl"
        RegistryKey    = "Win32PrioritySeparation"
        EnabledValue   = 26
        DefaultValue   = 2
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t09')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t09')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FileSystem"
        RegistryKey    = "NtfsMemoryUsage"
        EnabledValue   = 2
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t10')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t10')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control"
        RegistryKey    = "WaitToKillServiceTimeout"
        EnabledValue   = "2000"
        DefaultValue   = "5000"
        RegistryType   = "String"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t11')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t11')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Search"
        RegistryKey    = "EnableEnhancedSearchMode"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t12')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t12')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SysMain"
        RegistryKey    = "Start"
        EnabledValue   = 4
        DefaultValue   = 2
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t13')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t13')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
        RegistryKey    = "HibernateEnabled"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t14')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t14')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
        RegistryKey    = "Enabled"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t15')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t15')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\MapsBroker"
        RegistryKey    = "Start"
        EnabledValue   = 4
        DefaultValue   = 2
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t16')
        Category       = (Get-AIOString 'catalog.tweaks.cat.sysperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t16')
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
        Name           = (Get-AIOString 'catalog.tweaks.name.t17')
        Category       = (Get-AIOString 'catalog.tweaks.cat.uiperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t17')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize"
        RegistryKey    = "StartupDelayInMSec"
        EnabledValue   = 0
        DefaultValue   = 1000
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t18')
        Category       = (Get-AIOString 'catalog.tweaks.cat.uiperf')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t18')
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
        Name           = (Get-AIOString 'catalog.tweaks.name.t19')
        Category       = (Get-AIOString 'catalog.tweaks.cat.win11ui')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t19')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
        RegistryKey    = "TurnOffWindowsCopilot"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t20')
        Category       = (Get-AIOString 'catalog.tweaks.cat.win11ui')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t20')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
        RegistryKey    = "EnableSearchHighlights"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t21')
        Category       = (Get-AIOString 'catalog.tweaks.cat.win11ui')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t21')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer"
        RegistryKey    = "HideTaskViewButton"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t22')
        Category       = (Get-AIOString 'catalog.tweaks.cat.win11ui')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t22')
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
        Name           = (Get-AIOString 'catalog.tweaks.name.t23')
        Category       = (Get-AIOString 'catalog.tweaks.cat.privacy')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t23')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
        RegistryKey    = "Enabled"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t24')
        Category       = (Get-AIOString 'catalog.tweaks.cat.privacy')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t24')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
        RegistryKey    = "AllowTelemetry"
        EnabledValue   = 0
        DefaultValue   = 3
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t25')
        Category       = (Get-AIOString 'catalog.tweaks.cat.privacy')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t25')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"
        RegistryKey    = "DisableAIDataAnalysis"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t26')
        Category       = (Get-AIOString 'catalog.tweaks.cat.privacy')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t26')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
        RegistryKey    = "AllowCortana"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t27')
        Category       = (Get-AIOString 'catalog.tweaks.cat.privacy')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t27')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
        RegistryKey    = "DisableWebSearch"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t28')
        Category       = (Get-AIOString 'catalog.tweaks.cat.privacy')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t28')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"
        RegistryKey    = "LetAppsRunInBackground"
        EnabledValue   = 2
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t29')
        Category       = (Get-AIOString 'catalog.tweaks.cat.privacy')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t29')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"
        RegistryKey    = "Disabled"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t30')
        Category       = (Get-AIOString 'catalog.tweaks.cat.privacy')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t30')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\EdgeUI"
        RegistryKey    = "DisableMFUTracking"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t31')
        Category       = (Get-AIOString 'catalog.tweaks.cat.privacy')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t31')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\DiagTrack"
        RegistryKey    = "Start"
        EnabledValue   = 4
        DefaultValue   = 2
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t32')
        Category       = (Get-AIOString 'catalog.tweaks.cat.privacy')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t32')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\dmwappushservice"
        RegistryKey    = "Start"
        EnabledValue   = 4
        DefaultValue   = 3
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t33')
        Category       = (Get-AIOString 'catalog.tweaks.cat.privacy')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t33')
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
        Name           = (Get-AIOString 'catalog.tweaks.name.t34')
        Category       = (Get-AIOString 'catalog.tweaks.cat.network')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t34')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
        RegistryKey    = "NetworkThrottlingIndex"
        EnabledValue   = "4294967295"
        DefaultValue   = "10"
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t35')
        Category       = (Get-AIOString 'catalog.tweaks.cat.network')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t35')
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
        Name           = (Get-AIOString 'catalog.tweaks.name.t36')
        Category       = (Get-AIOString 'catalog.tweaks.cat.extras')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t36')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
        RegistryKey    = "(Default)"
        EnabledValue   = ""
        DefaultValue   = "DeleteKey"
        RegistryType   = "String"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t37')
        Category       = (Get-AIOString 'catalog.tweaks.cat.extras')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t37')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\CrashControl"
        RegistryKey    = "AutoReboot"
        EnabledValue   = 0
        DefaultValue   = 1
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t38')
        Category       = (Get-AIOString 'catalog.tweaks.cat.extras')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t38')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FileSystem"
        RegistryKey    = "LongPathsEnabled"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    },
    [PSCustomObject]@{
        Name           = (Get-AIOString 'catalog.tweaks.name.t39')
        Category       = (Get-AIOString 'catalog.tweaks.cat.extras')
        Description    = (Get-AIOString 'catalog.tweaks.desc.t39')
        Method         = "Registry"
        RegistryPath   = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer"
        RegistryKey    = "DisableNotificationCenter"
        EnabledValue   = 1
        DefaultValue   = 0
        RegistryType   = "DWord"
    }
)