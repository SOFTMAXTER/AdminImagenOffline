
# AdminImagenOffline V1.5.12 by SOFTMAXTER

<p align="center">
  <img width="320" height="250" alt="AdminImagenOffline Logo" src="https://github.com/user-attachments/assets/806cdf93-5a4d-41f1-9d0d-372882c4afcc" />
</p>

**AdminImagenOffline** es un completo script orquestador en PowerShell, diseñado para simplificar la administración y el mantenimiento de imágenes de instalación de Windows (`.wim`, `.esd`, `.vhd`, `.vhdx`). El script encapsula complejas operaciones del sistema en una suite de menús interactivos y GUIs fáciles de usar.

Fue creado para administradores de TI, técnicos de soporte y entusiastas de la personalización de Windows que necesitan modificar, limpiar, reparar, optimizar o convertir imágenes del sistema operativo de manera eficiente, segura y sin conexión.

## 🆕 Novedades en la Versión 1.5.12 (Changelog)

* **Integrar y ordenar índices**: Nueva opción dentro de *Editar Índices* (módulo `Modulo-IntegrarIndices.ps1`). Combina índices de varias fuentes WIM/ESD (no cifradas) en un único WIM nuevo. Los índices se agrupan automáticamente por arquitectura (x86, x64, ARM64, con separadores visuales) y *Subir/Bajar* ordena solo dentro de cada grupo; el orden de la tabla *Orden final* es la numeración resultante (1, 2, 3...). Los duplicados reciben un sufijo numérico, se puede marcar un índice como arranque WinPE y elegir la compresión (LZX, XPRESS o sin compresión).
* **Editor de metadatos por índice**: Doble clic (o Enter / F2) sobre un índice del orden final abre un editor con nombre, descripción, nombre mostrado, descripción mostrada e ID de edición. Ofrece plantillas de edición según la familia de la imagen (Windows 10/11, LTSC o Server), sin convertir ni activar Windows, y valida el nombre y los caracteres XML antes de aplicar. Los cambios se escriben en el WIM de salida con `wimlib` y se comprueban en la verificación final; la imagen de origen no se modifica.
* **Integración segura**: Las fuentes se abren solo para lectura y nunca se modifican; se rechazan las que estén montadas o hayan cambiado desde que se leyeron. El WIM se crea con `wimlib-imagex` en un temporal, se verifica por completo (`verify`) y se comprueba que orden, nombres y metadatos coincidan con el plan antes de publicarlo. Nunca sobrescribe un archivo existente, permite cancelar y deja un registro `.log` junto al destino. Muestra avisos de compatibilidad al mezclar arquitecturas, combinar x86 con Windows 11 o incluir ARM64. Requiere `wimlib-imagex.exe` en `Tools\wimlib` o en `PATH`.
* **Editar Info/Metadatos con lógica compartida**: El editor de metadatos de la imagen comparte con el integrador (nuevo archivo `Metadata-Comun.ps1`) el reconocimiento de la familia de Windows (10/11, LTSC, Server, WinPE y versiones anteriores) y las plantillas de edición. Corrige el prefijo duplicado en las ediciones Cloud (por ejemplo "Windows 11 11 SE"), valida el nombre y los caracteres XML antes de guardar y evita que las tablas se reordenen por columna.
* **Despliegue a VHD / Disco Físico con cancelación y cronómetro**: Nuevo botón **CANCELAR** que detiene el despliegue entre operaciones (nunca interrumpe a Storage, DISM ni BCDBOOT mientras escriben en el destino) y limpia lo creado: retira solo los accesos temporales del disco de destino y elimina el VHD de esa ejecución si no sigue montado. En disco físico los cambios ya realizados no se revierten. El progreso muestra el tiempo transcurrido (HH:MM:SS) y el tiempo total aparece al terminar, en el mensaje final y en el log; si algo de la limpieza queda pendiente, se informa.
* **Gestionar WinRE y Editar boot.wim con interfaz renovada**: Ambos flujos muestran ahora los pasos numerados (`[1/5]`... y `[1/4]`...), un resumen de la sesión (origen, tamaño, montaje y destino) y, en WinRE, el tamaño original frente al final. Al elegir copia de WinRE o índice de `boot.wim` se puede cancelar con `V` o Enter, el índice se identifica con su versión y rol (Windows PE o Instalador), y los errores de las ventanas de Addons y Drivers se registran sin cerrar el gestor.
* **Nueva interfaz de SFC Offline con progreso en vivo y resumen detallado**: En lugar de mostrar solo la salida cruda de `sfc.exe`, la herramienta lee el log de SFC mientras se ejecuta y muestra un indicador de actividad con cronómetro y componentes verificados. Los eventos relevantes (reparaciones `[SR]`, archivos con hash distinto y componentes que no se pueden reparar) aparecen una sola vez, traducidos y compactados. Al terminar presenta un resumen con la versión del motor CSI (`wcp.dll`), el tiempo, los componentes verificados, los archivos dañados por hash, las acciones de reparación, los ajustes de metadatos CSI y la ruta del log completo (`SFC_Offline_<fecha>.log`), y registra todo en el log de la herramienta.

## Características Principales

* **Interfaz Híbrida e Intuitiva**: Combina la fluidez de la consola para la orquestación principal con interfaces gráficas modernas (Windows Forms) para una gestión visual de servicios, aplicaciones, configuraciones y despliegues.
* **Gestión Integral de Imágenes**: Capacidad total para montar, editar, convertir y empaquetar formatos WIM, ESD y SWM. Soporte nativo para manipulación de discos virtuales (VHD/VHDX) con aplicación de cambios en tiempo real.
* **Suite de Personalización Modular**: Organizada en menús dedicados —Contenido (Bloatware, Appx, Addons), Sistema y Comportamiento (Features, Servicios, Tweaks) y OOBE y Marca (Unattend, OEM Branding)— para una gestión más clara del sistema.
* **Inyector de Addons con Soporte DeltaPack**: Integra utilidades sueltas (`.tpk`/`.bpk`/`.reg`) o paquetes completos generados por **DeltaPack Dual-Engine**, respetando el orden de despliegue (WIM → Acciones → Eliminaciones → Registro → Acciones) declarado en su manifiesto.
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
    │   ├── SetLockScreen.zip
    │   └── wimlib/                <-- wimlib-imagex.exe (verificación e incorporación de winre.wim, integración de índices y ajuste de CREATIONTIME)
    └── Script/
        ├── AdminImagenOffline.ps1
        ├── Metadata-Comun.ps1
        ├── Modulo-Actualizaciones.ps1
        ├── Modulo-Addons.ps1
        ├── Modulo-Appx.ps1
        ├── Modulo-Bloatware.ps1
        ├── Modulo-BootSetup.ps1
        ├── Modulo-Conversion.ps1
        ├── Modulo-Dashboard.ps1
        ├── Modulo-DeployVHD.ps1
        ├── Modulo-Drivers.ps1
        ├── Modulo-EditIndex.ps1
        ├── Modulo-Environments.ps1
        ├── Modulo-Features.ps1
        ├── Modulo-IntegrarIndices.ps1
        ├── Modulo-IsoMaker.ps1
        ├── Modulo-Lenguajes.ps1
        ├── Modulo-Metadata.ps1
        ├── Modulo-Montaje.ps1
        ├── Modulo-OEMBranding.ps1
        ├── Modulo-Save.ps1
        ├── Modulo-ServiciosOffline.ps1
        ├── Modulo-Tweaks.ps1
        ├── Modulo-UI.ps1
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

* **Montar / Guardar / Desmontar Imagen:** Submenú unificado con el ciclo de vida completo del montaje:

  * **Montar Imagen:** Selecciona un archivo `.wim`, `.esd` (solo lectura/exportación) o disco virtual (`.vhd`/`.vhdx`). Incluye la opción **"Extraer desde una ISO"**, que monta la ISO, vacía de forma segura una carpeta de extracción temporal y vuelca el contenido usando `Robocopy` a máxima velocidad. Con discos virtuales (VHD), el script escanea inteligentemente saltándose las particiones EFI/Recovery, localiza la partición de Windows, le asigna una letra de unidad dinámica y la monta. **Importante:** los cambios en un VHD se guardan en tiempo real.
  * **Recargar Imagen:** Desmonta y vuelve a montar para descartar cambios sin salir del flujo.
  * **Guardar Cambios:** Sobrescribir el índice actual, agregarlos como un nuevo índice (*Append*) o exportarlos a un archivo `.wim` completamente nuevo (*Save As*).
  * **Guardar y Desmontar (Commit) / Desmontar sin Guardar:** Si hay bloqueos de registro, el script fuerza un `[GC]::Collect()` (recolección de basura en .NET) para liberar *handles* huérfanos antes de desmontar, evitando corrupciones.
* **Editar Info/Metadatos:** Cambia el nombre interno y la descripción de la imagen (ej. de "Windows 10 Pro" a "Mi Custom OS").
* **Editar Índices:** Permite Exportar un índice específico para crear una imagen más ligera o Eliminar índices que no necesitas permanentemente. También permite **Integrar y ordenar índices** de varias fuentes WIM/ESD en un nuevo WIM mediante una interfaz gráfica, con orden libre, nombres editables, agrupación automática por arquitectura, edición de metadatos por índice y verificación completa del resultado.

### [ 2 ] Convertir Formatos
Herramientas de conversión e ingesta de imágenes.

* **Convertir WIM a ESD / ESD a WIM:** Los archivos `.esd` tienen compresión sólida y no pueden ser modificados directamente. Estas opciones exportan uno o varios índices (uno, una lista como `1,3,5` o todos) entre WIM y ESD (compresión *recovery* hacia ESD, *max* hacia WIM) para su posterior montaje y edición, verificando nombres, orden e índice de arranque de la salida.
* **Dividir WIM/ESD en SWM:** Divide una imagen en partes del tamaño elegido (3800 MB por defecto) y comprueba el límite de 4 GB por archivo cuando el destino es FAT32. Los ESD y las selecciones parciales pasan por un WIM intermedio.
* **Reunir SWM en WIM / ESD:** Valida que el conjunto SWM esté completo y exporta los índices elegidos a un único WIM o ESD.
* **Convertir VHD/VHDX a WIM:** Monta un disco virtual silenciosamente, detecta la partición del sistema operativo, le aplica un *Trim* (Optimización) si es posible, y captura todo el volumen hacia un archivo `.wim` usando compresión máxima. Si el VHD contiene `winre.wim` (dentro de Windows o en sus particiones de recuperación), lo verifica con *wimlib*, lo incorpora a `Windows\System32\Recovery` sin montar el WIM capturado y confirma por SHA-256 que coincide con el origen.

### [ 3 ] Herramientas de Arranque y Medios (Boot Tools)
Diseñado para preparar la distribución y el despliegue final de tu sistema personalizado:

* **Editar boot.wim:** Pregunta qué índice editar (detecta el de instalación por su nombre) y permite inyectar controladores de almacenamiento para que equipos modernos (con tecnologías Intel RST o VMD) reconozcan los discos duros durante la instalación, o inyectar DaRT. En el índice de instalación (Setup) abre además una **GUI de Setup y fondos** con Setup Legacy (`/legacy` en `winpeshl.ini`), estilo Windows 10 (renombra `setupprep.exe` en el índice y en el medio completo), bypass de TPM, Secure Boot y RAM (`LabConfig` offline) y fondo de instalación personalizado con vista previa. Cada cambio conserva un respaldo reversible y se verifica antes del *Commit*: al volver, `T` y `S` guardan y `T` y `N` descartan todo, incluidos los cambios externos al `boot.wim`.
* **Gestionar WinRE (Entorno de Recuperación):** Localiza `winre.wim` en Windows (y en las particiones *Recovery* si la imagen es un VHD/VHDX), lo copia a una sesión aislada en el *Scratch* verificada por SHA-256, lo monta, permite inyectar Addons o Drivers y, al guardar, hace *Commit*, reexporta con `/Export-Image /Bootable` (recompresión máxima, ahorrando cientos de megabytes de "peso muerto"), verifica la imagen final en solo lectura y la publica en `Windows\System32\Recovery` con respaldo, comprobando contenido, ACL, propietario y atributos, con reversión automática si algo falla.
* **Crear ISO Booteable:** Genera de manera eficiente un archivo ISO listo para ser empleado en herramientas como Rufus o Ventoy, asegurando compatibilidad integral con sistemas UEFI y BIOS Legacy.
* **Despliegue a VHD / Disco Físico:** Aplica directamente tu imagen de Windows (WIM, ESD o conjunto SWM, seleccionando su primera parte) a una unidad de almacenamiento externa o a un disco virtual, particionando y configurando los sectores de arranque de manera totalmente automatizada. Incluye la opción **Compact OS** para reducir el espacio ocupado por Windows 10/11 cliente (a costa de más tiempo de despliegue y uso de CPU). Puedes cancelar el proceso en cualquier momento (se limpia el destino creado) y el tiempo total queda registrado.

### [ 4 ] Actualizaciones e Idiomas (Servicing)
Menú unificado para los dos motores de servicing offline:

* **Integrar Actualizaciones:** Motor de servicing para medios extraídos (`install.wim`, `winre.wim`, `boot.wim`) que clasifica paquetes CAB/MSU por identidad y contenido interno (sin depender de listas de KB), respeta el orden SSU → Enablement/ESU → LCU, aplica Setup Dynamic Update y reinyecta `winre.wim` ya actualizado. Crea un respaldo *Preflight* antes de tocar el medio y genera reportes JSON/HTML de cada operación. Incluye verificaciones Pre/Post-Commit opcionales y detiene la integración con un aviso claro si detecta una LCU de la etapa ESU de Windows 10 en una imagen cliente no LTSC (nunca omite comprobaciones de licencia). Guía completa en [README_Modulo-Actualizaciones.md](README_Modulo-Actualizaciones.md).
* **Integrar Idiomas / Crear Medio Multilingüe:** Integra Language Packs, Language Features on Demand y recursos MUI en un medio extraído, con detección automática de ADK/WinPE Add-on y validación de idioma/arquitectura/familia de build antes de modificar nada. Igual que el módulo de Actualizaciones, trabaja de forma transaccional con respaldo *Preflight* y verificación SHA-256. Bloquea ediciones que restringen idiomas adicionales y la mezcla de imágenes Client y Server, y en idiomas de Asia oriental (`ja`, `ko`, `zh`) garantiza las fuentes necesarias en `boot.wim`. Guía completa en [README_Modulo-Lenguajes.md](README_Modulo-Lenguajes.md).

### [ 5 ] Drivers (Inyectar / Eliminar)
Gestión completa de los controladores *offline*.

* **Inyectar Drivers:** Selecciona una carpeta con archivos `.inf`. El motor de DISM inyectará los controladores en el almacén del sistema, con barra de progreso y una casilla para forzar la instalación de drivers sin firmar (`/ForceUnsigned`). Ideal para integrar drivers de red o video antes de instalar.
* **Desinstalar Drivers:** Interfaz gráfica que lista todos los controladores de terceros (OEM) instalados en la imagen montada, permitiendo eliminarlos selectivamente con advertencia reforzada al tocar clases de hardware críticas.

### [ 6 ] Contenido de la Imagen (Apps y Paquetes)
Gestión de todo lo que se ejecuta o se preinstala dentro de la imagen:

* **Eliminar Bloatware (Apps):** Interfaz categorizada para purgar aplicaciones preinstaladas indeseadas, salvaguardando los componentes vitales del sistema operativo. La plantilla minimalista del menú Inicio es opcional (casilla desmarcada por defecto).
* **Inyector y Actualizador de Apps Modernas (Appx/MSIX):** Motor heurístico de aprovisionamiento offline que analiza la identidad y versión reales de paquetes y bundles, detecta lo ya instalado en la imagen y marca cada entrada como **INSTALAR**, **ACTUALIZAR**, **REPARAR** u **OMITIR**. Lee dependencias declaradas en los manifiestos, selecciona versiones y arquitecturas compatibles, valida licencias por familia, procesa frameworks antes que las apps y puede limpiar marcas `Deprovisioned` para reparar paquetes previamente eliminados. Incluye actualización opcional de apps existentes, cancelación segura después del paquete actual y conservación de logs DISM cuando una operación falla.
* **Inyector de Addons (.wim, .tpk, .bpk, .reg):**
  * **Uso:** Integra paquetes de utilidades sueltos (7-Zip, Visual C++, etc.).
  * **Lógica Inteligente:** Si incluyes sufijos en el nombre del archivo (ej. `_x64`, `_x86`), el motor activa el **Escudo de Arquitectura** y omitirá los paquetes que no coincidan con la arquitectura de la imagen montada. Si usas `_main`, les dará prioridad de inyección en la cola. Extrae los empaquetados usando firma binaria para evitar fallos.
  * **Paquetes DeltaPack Dual-Engine:** Al seleccionar un `manifest_*.json`, el motor detecta el paquete como una unidad DeltaPack y ejecuta su `deployment.order` (WIM → Acciones → Eliminaciones → Registro → Acciones) en lugar de tratarlo como un addon suelto.

### [ 7 ] Sistema y Comportamiento (Ajustes del OS)

* **Características de Windows y .NET 3.5:** Activa funciones nativas del sistema como Hyper-V, WSL o añade el soporte clásico de .NET Framework de manera offline.
* **Servicios del Sistema:** Interfaz de fácil lectura para deshabilitar procesos innecesarios de diagnóstico o telemetría, con capacidad de restaurar los valores a su estado original de fábrica.
* **Tweaks y Registro Offline:** Motor visual que aplica configuraciones predefinidas para mejorar la privacidad y el rendimiento. Facilita la inyección inteligente y masiva de archivos `.reg` al sistema.

### [ 8 ] OOBE y Marca (Branding)

* **Automatización OOBE (Unattend.xml):** Genera respuestas XML para instalaciones desatendidas, omitiendo pantallas molestas, configurando redes, cuentas de usuario, contraseñas que nunca expiran y ajustes de la barra de tareas.
* **OEM Branding:** Personaliza fondos de pantalla predeterminados, la pantalla de bloqueo y la información del fabricante (Soporte) en las propiedades del sistema, permite bloquear permanentemente los fondos de pantalla y pantallas de bloqueo aplicados mediante políticas del sistema, junto con un escalado perfecto de las imágenes de perfil para Windows 11.

### [ 9 ] Limpieza y Reparación
Mantenimiento de la integridad de la imagen.

* **CheckHealth / ScanHealth:** Verifica daños en el almacén de componentes.
* **Reparar Imagen (RestoreHealth):** Si la imagen está corrupta, intenta repararla. Si falla, el script despliega un protocolo de emergencia (*Fallback*) que te pedirá un `install.wim` sano para usarlo como fuente de reparación (`/LimitAccess`).
* **SFC Offline:** Ejecuta el comprobador de archivos del sistema apuntando a la unidad montada. Muestra el progreso en vivo, traduce los eventos de reparación y finaliza con un resumen del resultado y la ruta del log detallado.
* **Limpiar Componentes (StartComponentCleanup):** Pule el tamaño de la imagen borrando actualizaciones obsoletas. Te preguntará si deseas usar `/ResetBase` (mayor compresión, pero impide desinstalar actualizaciones previas).

### [ 10 ] Cambiar Edición
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
