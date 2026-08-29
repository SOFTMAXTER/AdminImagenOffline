# =================================================================
#  CATÁLOGO CENTRAL DE EDICIONES DE WINDOWS 10 / 11 / SERVER
#  Útil para inyectar metadatos (Nombre y Descripción) durante 
#  operaciones de captura (Convert-VHD, Save-NewWim, Export-Image).
# =================================================================

$script:EditionCatalog = @(

    # =========================================================
    # RAMA DOMÉSTICA (HOME)
    # =========================================================
    [PSCustomObject]@{
        EditionID   = "Core"
        Name        = "Windows Home"
        Description = "Es la versión básica del gigante Microsoft. Está diseñada para la mayoría de los usuarios y ofrece todas las funciones esperadas. Es más económica y no carga módulos empresariales innecesarios. Puedes jugar y hacer todas las tareas domésticas que quieras sin problema."
    },
    [PSCustomObject]@{
        EditionID   = "CoreN"
        Name        = "Windows Home N"
        Description = "Versión básica diseñada para el mercado europeo (Normativa 'N'). Incluye todas las funciones de la edición Home estándar, pero no trae preinstaladas las tecnologías multimedia como Windows Media Player, Skype ni la grabadora de voz."
    },
    [PSCustomObject]@{
        EditionID   = "CoreK"
        Name        = "Windows Home K / KN"
        Description = "Versiones diseñadas para el mercado de Corea del Sur (Normativa 'K/KN'). Incluyen enlaces a software multimedia y de mensajería de terceros para cumplir con las regulaciones antimonopolio coreanas."
    },
    [PSCustomObject]@{
        EditionID   = "CoreSingleLanguage"
        Name        = "Windows Home Single Language"
        Description = "Diseñada para usuarios domésticos y dispositivos OEM de bajo costo. Como su nombre lo indica, solo admite un idioma de visualización base. Es una opción ideal para quienes no necesitan cambiar el idioma del sistema y buscan una experiencia simplificada."
    },
    [PSCustomObject]@{
        EditionID   = "CoreCountrySpecific"
        Name        = "Windows Home Country Specific"
        Description = "Edición restringida geográficamente, distribuida habitualmente en mercados emergentes o específicos (como China). Es funcionalmente idéntica a Home, pero bloqueada a una región específica para combatir la piratería."
    },

    # =========================================================
    # RAMA PROFESIONAL (PRO)
    # =========================================================
    [PSCustomObject]@{
        EditionID   = "Professional"
        Name        = "Windows Pro"
        Description = "Es una edición avanzada de Microsoft. Está diseñada para satisfacer las necesidades de profesionales, empresas y organizaciones. Incluye BitLocker, Hyper-V, Escritorio Remoto y unión a dominios. Ideal para quienes necesitan un sistema robusto para tareas empresariales."
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalN"
        Name        = "Windows Pro N"
        Description = "Edición profesional para el mercado europeo. Contiene todas las características de seguridad y administración de Windows Pro (Hyper-V, BitLocker), pero sin las aplicaciones multimedia preinstaladas."
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalSingleLanguage"
        Name        = "Windows Pro Single Language"
        Description = "Variante de la edición Pro licenciada comúnmente para OEM, restringida a un único idioma de visualización, pero conservando las capacidades empresariales."
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalCountrySpecific"
        Name        = "Windows Pro Country Specific"
        Description = "Variante de la edición Pro restringida a una región o país específico por motivos de licenciamiento."
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalWorkstation"
        Name        = "Windows Pro for Workstations"
        Description = "Diseñada para usuarios con necesidades de altísimo rendimiento, como científicos de datos, animadores 3D y diseñadores gráficos. Soporta hardware de grado servidor (procesadores Xeon/Epyc, hasta 6TB de RAM) y el sistema de archivos Resilient File System (ReFS)."
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalWorkstationN"
        Name        = "Windows Pro for Workstations N"
        Description = "Versión de altísimo rendimiento para estaciones de trabajo en el mercado europeo. Soporte masivo de hardware y ReFS, sin componentes multimedia preinstalados."
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalEducation"
        Name        = "Windows Pro Education"
        Description = "Una variante de la edición Pro que se basa en la misma arquitectura, pero proporciona controles predeterminados específicos para la educación. Elimina sugerencias de Cortana y publicidad para evitar distracciones en el aula."
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalEducationN"
        Name        = "Windows Pro Education N"
        Description = "Variante educativa de la edición Pro orientada a Europa. Controles específicos para el aula, sin publicidad y sin software multimedia preinstalado."
    },

    # =========================================================
    # RAMA EMPRESARIAL (ENTERPRISE)
    # =========================================================
    [PSCustomObject]@{
        EditionID   = "Enterprise"
        Name        = "Windows Enterprise"
        Description = "Forma parte de Microsoft 365 Enterprise. Proporciona administración avanzada de dispositivos, controles de telemetría profundos y servicios de seguridad como Credential Guard. Es ideal para grandes organizaciones que requieren un control absoluto de su infraestructura IT."
    },
    [PSCustomObject]@{
        EditionID   = "EnterpriseN"
        Name        = "Windows Enterprise N"
        Description = "Edición corporativa para el mercado europeo. Ofrece la misma administración avanzada y telemetría reducida que la edición Enterprise normal, sin los reproductores ni códecs multimedia integrados."
    },
    [PSCustomObject]@{
        EditionID   = "EnterpriseS"
        Name        = "Windows Enterprise LTSC"
        Description = "Diseñada para entornos críticos que requieren máxima estabilidad (Long-Term Servicing Channel). Ofrece un ciclo de vida de soporte a largo plazo, actualizaciones de calidad exclusivas, y elimina por completo Cortana, Edge y la Tienda UWP."
    },
    [PSCustomObject]@{
        EditionID   = "EnterpriseSN"
        Name        = "Windows Enterprise LTSC N"
        Description = "La versión más limpia y estable posible para Europa. Mantenimiento a largo plazo (LTSC), sin tienda, sin Cortana, sin Edge y sin componentes multimedia."
    },
    [PSCustomObject]@{
        EditionID   = "EnterpriseG"
        Name        = "Windows Enterprise G"
        Description = "Edición gubernamental especializada. Creada originalmente bajo requisitos estrictos de seguridad y soberanía de datos para el gobierno de China (Zhuangongban). Telemetría severamente restringida y cifrado personalizado."
    },
    [PSCustomObject]@{
        EditionID   = "EnterpriseGN"
        Name        = "Windows Enterprise G (N)"
        Description = "Variante de la edición gubernamental especializada sin componentes multimedia preinstalados."
    },
    [PSCustomObject]@{
        EditionID   = "ServerRdsh"
        Name        = "Windows Enterprise Multi-Session"
        Description = "Una edición única diseñada específicamente para Azure Virtual Desktop. Permite que múltiples usuarios interactivos inicien sesión simultáneamente en la misma máquina virtual, combinando la experiencia de cliente con la escalabilidad de un servidor."
    },

    # =========================================================
    # RAMA EDUCATIVA Y CLOUD
    # =========================================================
    [PSCustomObject]@{
        EditionID   = "Education"
        Name        = "Windows Education"
        Description = "Creada para instituciones educativas, basada en la edición Enterprise. Ofrece la misma seguridad y capacidad de gestión corporativa de alto nivel, pero licenciada y optimizada para estudiantes, profesores y personal escolar."
    },
    [PSCustomObject]@{
        EditionID   = "EducationN"
        Name        = "Windows Education N"
        Description = "Edición basada en Enterprise para escuelas en el mercado europeo. Incluye toda la seguridad corporativa escolar, pero carece del ecosistema multimedia nativo de Microsoft."
    },
    [PSCustomObject]@{
        EditionID   = "Cloud"
        Name        = "Windows 10 S"
        Description = "Versión orientada a la educación o dispositivos de gama baja. Extremadamente segura y cerrada, solo permite ejecutar software de la Microsoft Store y Edge."
    },
    [PSCustomObject]@{
        EditionID   = "CloudN"
        Name        = "Windows 10 S (N)"
        Description = "Variante de Windows 10 S para Europa, desprovista de capacidades multimedia nativas."
    },
    [PSCustomObject]@{
        EditionID   = "CloudEdition"
        Name        = "Windows 11 SE"
        Description = "Una versión altamente simplificada y restrictiva, optimizada para rendimiento y seguridad en aulas. Diseñada para dispositivos de bajo coste educativos (K-8) priorizando aplicaciones web."
    },
    [PSCustomObject]@{
        EditionID   = "CloudEditionN"
        Name        = "Windows 11 SE (N)"
        Description = "Variante europea de Windows 11 SE, sin Windows Media Player ni complementos multimedia integrados."
    },

    # =========================================================
    # RAMA INTERNET DE LAS COSAS (IoT)
    # =========================================================
    [PSCustomObject]@{
        EditionID   = "IoTEnterprise"
        Name        = "Windows IoT Enterprise"
        Description = "Edición empresarial completa diseñada para sistemas embebidos, quioscos, cajeros automáticos (ATM) y puntos de venta (POS). Incluye bloqueos especiales (Assigned Access / Kiosk Mode) para restringir el dispositivo a una sola aplicación comercial."
    },
    [PSCustomObject]@{
        EditionID   = "IoTEnterpriseK"
        Name        = "Windows IoT Enterprise K"
        Description = "Versión de Windows IoT Enterprise destinada al mercado surcoreano, cumpliendo con regulaciones antimonopolio al no incluir o enlazar software multimedia predeterminado, manteniendo el enfoque en cajeros y sistemas embebidos."
    },
    [PSCustomObject]@{
        EditionID   = "IoTEnterpriseS"
        Name        = "Windows IoT Enterprise LTSC"
        Description = "La edición definitiva para hardware de misión crítica (equipos médicos, maquinaria industrial, cajeros). Combina los bloqueos de quiosco de la versión IoT con los 10 años de soporte y la nula intervención funcional del canal LTSC."
    },
    [PSCustomObject]@{
        EditionID   = "IoTEnterpriseSK"
        Name        = "Windows IoT Enterprise LTSC K"
        Description = "Variante de soporte a largo plazo (LTSC) para Internet de las Cosas, diseñada específicamente para el mercado de Corea del Sur (sin componentes multimedia)."
    },

    # =========================================================
    # RAMA SERVIDORES (WINDOWS SERVER)
    # =========================================================
    [PSCustomObject]@{
        EditionID   = "ServerStandard"
        Name        = "Windows Server Standard"
        Description = "Edición de Windows Server con Experiencia de Escritorio (GUI). Diseñada para entornos físicos o mínimamente virtualizados. Ideal para pequeñas y medianas empresas."
    },
    [PSCustomObject]@{
        EditionID   = "ServerStandardCore"
        Name        = "Windows Server Standard (Server Core)"
        Description = "Edición Standard instalada en modo Server Core (sin interfaz gráfica). Reduce drásticamente la superficie de ataque y el uso de recursos del sistema, ideal para administración remota y servicios de infraestructura."
    },
    [PSCustomObject]@{
        EditionID   = "ServerDatacenter"
        Name        = "Windows Server Datacenter"
        Description = "Edición premium de Windows Server con Experiencia de Escritorio. Creada para centros de datos altamente virtualizados y entornos en la nube definidos por software. Incluye Storage Spaces Direct y Shielded VMs."
    },
    [PSCustomObject]@{
        EditionID   = "ServerDatacenterCore"
        Name        = "Windows Server Datacenter (Server Core)"
        Description = "Edición Datacenter en modo Server Core. Máxima seguridad y eficiencia para hipervisores masivos y centros de datos definidos por software, sin la carga de la interfaz gráfica."
    },
    [PSCustomObject]@{
        EditionID   = "ServerAzureCor"
        Name        = "Windows Server Datacenter: Azure Edition (Core)"
        Description = "Edición exclusiva para la nube de Azure y Azure Stack HCI. Soporta Hotpatching (aplicación de actualizaciones de seguridad sin reiniciar la máquina) y protocolo SMB sobre QUIC."
    }
)

# =================================================================
# FUNCIÓN AUXILIAR DE BÚSQUEDA
# Retorna el objeto completo basado en el EditionID o el Nombre.
# =================================================================
function Get-WindowsEditionMetadata {
    param(
        [string]$QueryString
    )
    
    $match = $script:EditionCatalog | Where-Object { 
        $_.EditionID -eq $QueryString -or 
        $_.Name -match [regex]::Escape($QueryString) 
    } | Select-Object -First 1

    if ($match) {
        return $match
    } else {
        # Fallback genérico si se encuentra una edición muy rara
        return [PSCustomObject]@{
            EditionID   = $QueryString
            Name        = "Windows $QueryString"
            Description = "Imagen de Windows personalizada ($QueryString). Creada/Capturada a través de AdminImagenOffline."
        }
    }
}