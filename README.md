# AdminImagenOffline V1.5.4 by SOFTMAXTER

<p align="center">
  <img width="320" height="250" alt="AdminImagenOffline Logo" src="https://github.com/user-attachments/assets/806cdf93-5a4d-41f1-9d0d-372882c4afcc" />
</p>

**AdminImagenOffline** es un completo script orquestador en PowerShell, diseñado para simplificar la administración y el mantenimiento de imágenes de instalación de Windows (`.wim`, `.esd`, `.vhd`, `.vhdx`). El script encapsula complejas operaciones del sistema en una suite de menús interactivos y GUIs fáciles de usar.

Fue creado para administradores de TI, técnicos de soporte y entusiastas de la personalización de Windows que necesitan modificar, limpiar, reparar, optimizar o convertir imágenes del sistema operativo de manera eficiente, segura y sin conexión.

## 🆕 Novedades en la Versión 1.5.4 (Changelog)

* **Integración de Actualizaciones Offline (Nuevo)**: Motor de servicing que clasifica e integra paquetes CAB/MSU (SSU, LCU, ESU, Enablement, SetupDU) directamente en `install.wim`, `winre.wim` y `boot.wim`, con respaldo *Preflight*, verificaciones y reportes JSON/HTML por operación.
* **Integración de Idiomas / Medios Multilingües (Nuevo)**: Motor de servicing para paquetes de idioma y Language Features on Demand, con detección automática de ADK/WinPE Add-on, validación de compatibilidad y actualización de `winre.wim`/`boot.wim`.
* **Actualizador Inteligente Mejorado**: El sistema ahora lee y muestra el registro de cambios (changelog) directamente en la consola antes de aplicar la actualización.
* **Limpieza Profunda de Bloatware (Appx)**: Nuevo motor de eliminación que purga aplicaciones nativas de forma permanente, limpia residuos físicos, inyecta un Menú de Inicio minimalista y aplica vacunas anti-reinstalación para evitar que regresen al conectar a internet.
* **Autocompletado de Metadatos**: El editor de imágenes WIM ahora incluye plantillas predefinidas para rellenar automáticamente los nombres y descripciones de las ediciones de Windows (Home, Pro, LTSC, Server).
* **OEM Branding Corporativo**: Nueva función para bloquear permanentemente los fondos de pantalla y pantallas de bloqueo aplicados mediante políticas del sistema, junto con un escalado perfecto de las imágenes de perfil para Windows 11.
* **Automatización OOBE Ampliada**: Opciones para configurar contraseñas que nunca expiran y ajustes de la barra de tareas (como ocultar noticias o forzar la búsqueda como icono) directamente desde el generador de `Unattend.xml`.
* **Despliegue a VHD Más Seguro**: Mejoras en el particionado UEFI y ocultamiento perfeccionado de la partición de recuperación (WinRE).

## Características Principales

* **Interfaz Híbrida e Intuitiva**: Combina la fluidez de la consola para la orquestación principal con interfaces gráficas modernas (Windows Forms) para una gestión visual de servicios, aplicaciones, configuraciones y despliegues.
* **Gestión Integral de Imágenes**: Capacidad total para montar, editar y empaquetar formatos WIM y ESD. Soporte nativo para manipulación de discos virtuales (VHD/VHDX) con aplicación de cambios en tiempo real.
* **Centro de Personalización Avanzada**: Plataforma centralizada para la optimización del sistema que incluye la eliminación de aplicaciones preinstaladas (Bloatware), administración de características opcionales y optimización selectiva de servicios del sistema.
* **Sistema de Tweaks y Automatización**: Integra un potente motor para aplicar optimizaciones de rendimiento de forma gráfica, importar archivos `.reg` en lote y generar archivos `Unattend.xml` para instalaciones desatendidas (incluyendo la evasión de los requisitos de hardware de Windows 11).
* **Control de Controladores y OSD**: Gestor visual para inyectar carpetas enteras de drivers o desinstalar controladores OEM específicos. Soporte integrado para editar los metadatos de la imagen (Nombres y Descripciones) y gestionar paquetes de idioma (LP) o características bajo demanda (FOD).
* **Herramientas de Arranque y Despliegue**: Creación automatizada de imágenes ISO booteables, modificación directa de los entornos de recuperación (WinRE) y medios de instalación (`boot.wim`), y despliegue rápido del sistema a unidades de almacenamiento físicas o virtuales.
* **Personalización OEM Branding**: Facilidad para inyectar fondos de escritorio predeterminados, imágenes para la pantalla de bloqueo e integrar la información corporativa o de soporte del ensamblador del equipo.
* **Actualizaciones e Idiomas Offline**: Motores dedicados para integrar actualizaciones acumulativas (SSU/LCU/ESU/SetupDU) y paquetes de idioma/LFOD directamente en `install.wim`, `winre.wim` y `boot.wim`, con respaldo *Preflight*, verificación de integridad y reportes detallados por operación.

---

## Requisitos del Sistema

* Sistema Operativo Windows 10 / 11 Pro / Enterprise (Host).
* PowerShell 5.1 o superior.
* Privilegios de Administrador (Elevación UAC).
* Módulo de Hyper-V habilitado (Obligatorio para operaciones de montaje de VHD/VHDX).
* **Dependencia del Motor de Compilación**: La herramienta requiere el binario `oscdimg.exe`. Si no se detecta en las rutas estándar de instalación, el sistema pedirá al usuario que lo localice manualmente mediante un cuadro de diálogo.

  * ⚠️ **Aclaración sobre oscdimg.exe**: El proyecto incluye una copia de `oscdimg.exe` en la carpeta `Tools/` con fines estrictamente prácticos para que puedas probar la herramienta inmediatamente tras descargarla. Sin embargo, se recomienda encarecidamente eliminar este archivo del directorio y utilizar el motor original descargando e instalando el [Windows Assessment and Deployment Kit (ADK)](https://learn.microsoft.com/es-es/windows-hardware/get-started/adk-install) oficial de Microsoft.
* Conexión a internet (Opcional, exclusivamente para el actualizador integrado).

---

## Modo de Uso y Estructura

1. Descarga el repositorio como un archivo `.zip` y extráelo en una ruta corta (ej. `C:\\AdminImagen`).
2. Asegúrate de mantener la integridad de la estructura de directorios para el correcto funcionamiento de la suite:

   ```text
    TuCarpetaPrincipal/
    │
    ├── AdminImagenOffline.exe    <-- Ejecutable Lanzador Principal
    ├── Tools/
    │   ├── oscdimg.exe
    │   └── SetLockScreen.zip
    └── Script/
        ├── AdminImagenOffline.ps1
        ├── Modulo-Actualizaciones.ps1
        ├── Modulo-Addons.ps1
        ├── Modulo-Appx.ps1
        ├── Modulo-Bloatware.ps1
        ├── Modulo-Conversion.ps1
        ├── Modulo-DeployVHD.ps1
        ├── Modulo-Drivers.ps1
        ├── Modulo-EditIndex.ps1
        ├── Modulo-Environments.ps1
        ├── Modulo-Features.ps1
        ├── Modulo-IsoMaker.ps1
        ├── Modulo-Lenguajes.ps1
        ├── Modulo-Metadata.ps1
        ├── Modulo-Montaje.ps1
        ├── Modulo-OEMBranding.ps1
        ├── Modulo-Save.ps1
        ├── Modulo-ServiciosOffline.ps1
        ├── Modulo-Tweaks.ps1
        ├── Modulo-Unattend.ps1
        └── Catalogos/
            ├── Ajustes.ps1
            ├── Bloatware.ps1
            ├── Ediciones.ps1
            └── Servicios.ps1 
    ```

   > 📖 Documentación dedicada para los módulos avanzados: [README_Modulo-Actualizaciones.md](README_Modulo-Actualizaciones.md) y [README_Modulo-Lenguajes.md](README_Modulo-Lenguajes.md).

3. Haz doble clic en **`AdminImagenOffline.exe`**. El lanzador solicitará permisos de Administrador y preparará el entorno de ejecución de manera automática.

---

## 🚀 Configuración Inicial

Al iniciar el script por primera vez, se te pedirá configurar dos directorios críticos (estas rutas se guardan en `config.json`):

1. **Directorio de Montaje (`MOUNT\_DIR`):** Carpeta vacía (ej. `C:\\TEMP`) donde se desempaquetará la imagen de Windows para su edición.
2. **Directorio Temporal (`Scratch\_DIR`):** Espacio de trabajo para DISM (ej. `C:\\Scratch`). Se recomienda usar rutas cortas para evitar el límite de 260 caracteres de Windows al extraer paquetes profundos.

---

## 📖 Guía Detallada del Menú Principal y Módulos

A continuación se desglosan las principales opciones del entorno y cómo utilizar los módulos integrados en la suite.

### [ 1 ] Gestión de Imagen
Este es el núcleo de la herramienta. Controla el ciclo de vida del montaje de la imagen.

* **Montar Imagen:** Te permite seleccionar un archivo `.wim`, `.esd` (solo lectura/exportación) o disco virtual (`.vhd`/`.vhdx`).

  * *Novedad:* Puedes elegir **"Extraer desde una ISO"**. El script montará la ISO, vaciará de forma segura una carpeta de extracción temporal y volcará el contenido usando `Robocopy` a máxima velocidad.
  * *Discos Virtuales (VHD):* Si seleccionas un VHD, el script hace un escaneo inteligente saltándose las particiones EFI/Recovery, encuentra la partición de Windows, le asigna una letra de unidad dinámica y la monta. **Importante:** Los cambios en un VHD se guardan en tiempo real.
* **Desmontar / Guardar Cambios (Commit):** \* Si usas WIM, la opción *Commit* re-comprimirá los cambios en el archivo.

  * Si hay bloqueos de registro, el script fuerza un `\[GC]::Collect()` (Recolección de basura en .NET) para liberar *handles* huérfanos antes de desmontar, evitando corrupciones.
* **Editar Metadatos:** Cambia el nombre interno y la descripción de la imagen (ej. de "Windows 10 Pro" a "Mi Custom OS").
* **Editar Índices:** Permite Exportar un índice específico para crear una imagen más ligera o Eliminar índices que no necesitas permanentemente.

### [ 2 ] Convertir Formatos
Herramientas de conversión e ingesta de imágenes.

* **Convertir ESD a WIM:** Los archivos `.esd` tienen compresión sólida y no pueden ser modificados directamente. Esta opción extrae un índice del ESD y lo convierte a formato `.wim` estándar para su posterior montaje y edición.
* **Convertir VHD/VHDX a WIM:** Monta un disco virtual silenciosamente, detecta la partición del sistema operativo, le aplica un *Trim* (Optimización) si es posible, y captura todo el volumen hacia un archivo `.wim` usando compresión máxima.

### [ 3 ] Herramientas de Arranque y Medios
Diseñado para preparar la distribución y el despliegue final de tu sistema personalizado:

* **Editar boot.wim:** Accede al entorno de preinstalación para inyectar controladores de almacenamiento y garantizar que equipos modernos (con tecnologías Intel RST o VMD) reconozcan los discos duros durante la instalación.
* **Crear ISO Booteable:** Genera de manera eficiente un archivo ISO listo para ser empleado en herramientas como Rufus o Ventoy, asegurando compatibilidad integral con sistemas UEFI y BIOS Legacy.
* **Despliegue a VHD:** Aplica directamente tu imagen de Windows a una unidad de almacenamiento externa o a un disco virtual, particionando y configurando los sectores de arranque de manera totalmente automatizada.

### [ U ] Integrar Actualizaciones
Motor de servicing offline para medios extraídos (`install.wim`, `winre.wim`, `boot.wim`) que clasifica paquetes CAB/MSU por identidad y contenido interno (sin depender de listas de KB), respeta el orden SSU → Enablement/ESU → LCU, aplica Setup Dynamic Update y reinyecta `winre.wim` ya actualizado. Crea un respaldo *Preflight* antes de tocar el medio y genera reportes JSON/HTML de cada operación. Guía completa en [README_Modulo-Actualizaciones.md](README_Modulo-Actualizaciones.md).

### [ M ] Integrar Idiomas / Crear Medio Multilingüe
Integra Language Packs, Language Features on Demand y recursos MUI en un medio extraído, con detección automática de ADK/WinPE Add-on y validación de idioma/arquitectura/familia de build antes de modificar nada. Igual que el módulo de Actualizaciones, trabaja de forma transaccional con respaldo *Preflight* y verificación SHA-256. Guía completa en [README_Modulo-Lenguajes.md](README_Modulo-Lenguajes.md).

### [ 4 ] Drivers (Inyectar / Eliminar)
Gestión completa de los controladores *offline*.

* **Inyectar Drivers:** Selecciona una carpeta con archivos `.inf`. El motor de DISM inyectará los controladores en el almacén del sistema. Ideal para integrar drivers de red o video antes de instalar.
* **Desinstalar Drivers:** Interfaz gráfica que lista todos los controladores de terceros (OEM) instalados en la imagen montada, permitiendo eliminarlos selectivamente.

### [ 5 ] Centro de Personalización y Ajustes
El ecosistema gráfico más amplio del proyecto, estructurado para adaptar Windows a escenarios corporativos o de alto rendimiento:

1. * **Eliminar Bloatware (Apps):** Interfaz categorizada para purgar aplicaciones preinstaladas indeseadas, salvaguardando los componentes vitales del sistema operativo.
2. * **Características y .NET 3.5:** Activa funciones nativas del sistema como Hyper-V, WSL o añade el soporte clásico de .NET Framework de manera offline.
3. * **Optimización de Servicios:** Interfaz de fácil lectura para deshabilitar procesos innecesarios de diagnóstico o telemetría, con capacidad de restaurar los valores a su estado original de fábrica.
4. * **Tweaks y Registro Offline:** Motor visual que aplica configuraciones predefinidas para mejorar la privacidad y el rendimiento. Facilita la inyección inteligente y masiva de archivos `.reg` al sistema.
5. * **Inyector de Apps y Addons:** Integra paquetes universales UWP (`.appx`) o automatiza la instalación de utilidades estándar, organizándolas por arquitectura.
6. * **Automatización OOBE:** Genera respuestas XML para instalaciones desatendidas, omitiendo pantallas molestas, configurando redes y cuentas de usuario.
7. * **Inyector de Addons (.wim, .tpk, .bpk, .reg):**
   * **Uso:** Integra paquetes de utilidades (7-Zip, Visual C++, etc.).
   * **Lógica Inteligente:** Si incluyes sufijos en el nombre del archivo (ej. `\_x64`, `\_x86`), el motor activa el **Escudo de Arquitectura** y omitirá los paquetes que no coincidan con la arquitectura de la imagen montada. Si usas `\_main`, les dará prioridad de inyección en la cola. Extrae los empaquetados usando firma binaria para evitar fallos.
8. **Gestionar WinRE (Entorno de Recuperación):**
   * **Lógica:** Va a `Windows\\System32\\Recovery`, extrae el `winre.wim`, lo monta en el *Scratch*, permite inyectar DaRT o Drivers, y al guardar, utiliza `/Export-Image /Bootable` para destruir los diccionarios viejos y recomprimir el entorno, ahorrando cientos de megabytes de "peso muerto".
9. * **OEM Branding:** Personaliza fondos de pantalla predeterminados, la pantalla de bloqueo y la información del fabricante (Soporte) en las propiedades del sistema, permite bloquear permanentemente los fondos de pantalla y pantallas de bloqueo aplicados mediante políticas del sistema, junto con un escalado perfecto de las imágenes de perfil para Windows 11.

### [ 6 ] Limpieza y Reparación
Mantenimiento de la integridad de la imagen.

* **CheckHealth / ScanHealth:** Verifica daños en el almacén de componentes.
* **Reparar Imagen (RestoreHealth):** Si la imagen está corrupta, intenta repararla. Si falla, el script despliega un protocolo de emergencia (*Fallback*) que te pedirá un `install.wim` sano para usarlo como fuente de reparación (`/LimitAccess`).
* **SFC Offline:** Ejecuta el comprobador de archivos del sistema apuntando a la unidad montada.
* **Limpiar Componentes (StartComponentCleanup):** Pule el tamaño de la imagen borrando actualizaciones obsoletas. Te preguntará si deseas usar `/ResetBase` (mayor compresión, pero impide desinstalar actualizaciones previas).

### [ 7 ] Cambiar Edición
Permite actualizar la versión de Windows (ej. de `Home` a `Professional` o `Enterprise LTSC`).

* **Nota Técnica:** El script consulta las ediciones de destino viables (`Get-TargetEditions`). Esta operación en archivos WIM es reversible si no se guardan los cambios, pero en un **VHD** es un proceso destructivo e irreversible en tiempo real. El script mostrará una advertencia de seguridad roja si intentas hacer esto sobre un disco virtual.

---

## Notas de Seguridad y Mejores Prácticas

* **ANTIVIRUS / WINDOWS DEFENDER:** Durante las operaciones extensas de guardado o empaquetamiento, las soluciones de seguridad pueden bloquear temporalmente el acceso a los archivos de la imagen. Es recomendable añadir tus carpetas de trabajo a las exclusiones del sistema para prevenir fallos de lectura/escritura.
* **COPIA DE SEGURIDAD:** Es un requisito indispensable mantener un respaldo íntegro de tu archivo original (`.wim` / `.vhdx`) antes de aplicar cambios estructurales, optimizaciones profundas o limpiezas de componentes.
* **DISCOS VIRTUALES (VHD):** Toda modificación efectuada sobre discos virtuales es instantánea e irreversible. A diferencia de las imágenes estáticas, los cambios no se pueden descartar al desmontar el sistema.

---

## ☕ Apoya el Proyecto

AdminImagenOffline es una herramienta concebida para facilitar la ingeniería de sistemas y mejorar los flujos de trabajo en TI. Si esta suite te ha ahorrado horas de configuración, empaquetado y optimización, considera apoyar su desarrollo continuo para asegurar su compatibilidad frente a las constantes actualizaciones de Windows.

* [💳 Donar vía PayPal](https://www.paypal.com/donate/?hosted_button_id=U65G2GXDTUGML)

## Descargo de Responsabilidad

Este software realiza operaciones avanzadas que modifican archivos de imagen base, integran configuraciones y alteran estructuras internas del sistema operativo. El autor, **SOFTMAXTER**, no asume responsabilidad alguna por la pérdida de datos, corrupción de sistemas host o daños colaterales que puedan derivarse del uso inadecuado de la herramienta.

**Utiliza el software bajo tu propio riesgo y evalúa siempre los despliegues en entornos de prueba cerrados antes de su implementación en producción.**

## Autor y Colaboradores

* **Autor Principal**: SOFTMAXTER
* **Colaboradores**: [LatinserverEc](https://github.com/LatinserverEc) (Gracias por el feedback y el testing continuo).
* **Análisis y refinamiento de código**: Realizado en colaboración con inteligencia artificial para garantizar máxima calidad, seguridad SDDL, optimización de algoritmos y transición integral a interfaces gráficas nativas de Windows Forms.

---

### Cómo Contribuir

Si tienes ideas o mejoras para este proyecto:

1. Haz un Fork del repositorio principal.
2. Crea una nueva rama (`git checkout -b feature/nueva-funcionalidad`).
3. Aplica y documenta tus cambios asegurando la compatibilidad con el entorno general.
4. Realiza un Push hacia tu rama (`git push origin feature/nueva-funcionalidad`).
5. Abre un Pull Request en el repositorio.

---

## 📝 Licencia y Modelo de Negocio (Dual Licensing)

Este proyecto está amparado bajo derechos de autor y se distribuye utilizando un modelo de **Doble Licencia (Dual Licensing)**:

### 1. Licencia Comunitaria (Open Source)

Distribuida bajo la **Licencia GNU GPLv3**. Eres libre de estudiar, emplear y modificar esta suite en proyectos personales o entornos académicos. Bajo los términos *Copyleft* de esta licencia, cualquier herramienta o software derivado que incorpore fragmentos o módulos completos de AdminImagenOffline **debe ser íntegramente de código abierto** y compartirse obligatoriamente bajo los mismos términos.

### 2. Licencia Comercial Corporativa

En caso de que requieras integrar el motor orquestador, las interfaces o los módulos de esta suite en una solución comercial cerrada (propietaria), o si tu organización demanda Acuerdos de Nivel de Servicio (SLA) y soporte técnico especializado, **debes adquirir una Licencia Comercial**.

Para mayor información o consultas de licenciamiento empresarial, contactar mediante correo electrónico a: `softmaxter@hotmail.com`
