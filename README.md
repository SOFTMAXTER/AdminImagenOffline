# AdminImagenOffline V1.4.5 by SOFTMAXTER

**AdminImagenOffline** es un completo script en PowerShell, diseñado para simplificar la administración y el mantenimiento de imágenes de instalación de Windows (`.wim`, `.esd`, `.vhd/vhdx`). El script encapsula complejas operaciones de `DISM`, manipulación del Registro y otras herramientas del sistema en una interfaz de menús interactiva y fácil de usar.

Fue creado para administradores de TI, técnicos de soporte y entusiastas de la personalización de Windows que necesitan modificar, limpiar, reparar, optimizar o convertir imágenes del sistema operativo de manera eficiente y sin conexión.

## Características Principales

* **Interfaz Híbrida (Consola + GUI)**: Combina la rapidez de la consola para operaciones básicas con interfaces gráficas (Windows Forms) modernas para la gestión de drivers, servicios, bloatware, despliegue y registro.
* **Auto-Actualizador**: El script busca automáticamente nuevas versiones en GitHub al iniciar y ofrece al usuario la posibilidad de actualizarse.
* **Configuración Persistente**: Guarda las rutas de trabajo (Directorio de Montaje y Directorio Temporal) en un archivo `config.json` para que las preferencias del usuario sean permanentes.
* **Robustez y Seguridad**:
    * **Protección de Hives**: Implementa limpieza de memoria (`GC`) y pausas de seguridad para evitar la corrupción del registro al desmontar.
    * **Logging Detallado**: Sistema de reporte de errores con "Stack Trace" completo para facilitar el diagnóstico de fallos críticos.
    * **Saneamiento Automático**: Limpieza proactiva del directorio temporal (`Scratch`) al inicio para evitar errores de espacio o archivos corruptos.
    * **Tooltips Informativos**: Ayuda contextual visual al pasar el cursor sobre opciones complejas en las interfaces gráficas.
* **Detección Automática**: Verifica al inicio si ya existe una imagen montada en el sistema (WIM o VHD) y carga su información dinámicamente.
* **Gestión de Imágenes**: Montaje, desmontaje (con descartes), guardado de cambios (commit/append) y recarga rápida. Soporte completo para montar y editar archivos **VHD/VHDX** directamente.
* **Despliegue a VHD (Native Boot)**: Nueva herramienta para crear discos virtuales arrancables desde un WIM, configurando particiones (GPT/UEFI o MBR/BIOS) automáticamente.
* **Edición de Índices WIM**: Exportación y eliminación de índices específicos.
* **Conversión de Formatos**: ESD a WIM y VHD/VHDX a WIM.
* **Cambio de Edición de Windows**: Detección y cambio de edición (ej. Home a Pro) offline.
* **Gestión Avanzada de Drivers**:
    * **Inyector Flexible**: Interfaz que permite cargar carpetas recursivamente o agregar archivos `.inf` individuales. Incluye detección precisa por **Versión** y **Clase** para evitar duplicados. Actualiza la caché interna tras la inyección.
    * **Desinstalador de Drivers**: Lista los drivers de terceros (OEM) instalados en la imagen y permite su eliminación selectiva.
* **Eliminación de Bloatware**: Interfaz gráfica con clasificación por colores (Verde=Seguro, Naranja=Recomendado, Blanco=Otros) para eliminar aplicaciones preinstaladas (Appx).
* **Optimización de Servicios**: Permite deshabilitar servicios del sistema innecesarios organizados por categorías. Incluye función para **Restaurar** valores originales.
* **Tweaks y Registro Offline**:
    * **Gestor Nativo**: Aplica ajustes de rendimiento y privacidad escribiendo directamente en el registro offline. Permite **Restaurar** valores por defecto.
    * **Importador .REG Inteligente**: Permite importar archivos `.reg` externos con traducción automática de rutas (ej. `HKEY_CLASSES_ROOT` a `OfflineSoftware\Classes`).
    * **Vista Previa**: Muestra una comparativa de valores antes de aplicar los cambios.
* **Suite de Limpieza y Reparación**: `CheckHealth`, `ScanHealth`, `RestoreHealth` (con soporte para fuente WIM alternativa), `SFC` offline y limpieza de componentes (`ResetBase`).

---

## Requisitos

* Sistema Operativo Windows (Host).
* PowerShell 5.1 o superior.
* Privilegios de Administrador para ejecutar el script.
* Módulo de Hyper-V habilitado (Recomendado para operaciones con VHD).
* Conexión a internet (opcional, para el auto-actualizador).

---

## Modo de Uso

1.  Descarga los archivos. El script es flexible con la estructura de carpetas, pero se recomienda mantener `Run.bat` junto a `AdminImagenOffline.ps1` o con el script dentro de una subcarpeta `Script`.
2.  Haz clic derecho sobre el archivo `Run.bat` y selecciona **"Ejecutar como administrador"**.
3.  Sigue las instrucciones en pantalla.
4.  Si es la primera ejecución, ve al menú **[9] Configurar Rutas de Trabajo** para definir tus directorios.

---

## Explicación Detallada de los Menús

### Menú Principal

* **1. Gestionar Imagen**: Operaciones base de WIM (Montar, Guardar, Exportar, Convertir).
* **2. Cambiar Edicion de Windows**: Actualización de edición (ej. Home -> Pro).
* **3. Integrar Drivers (Controladores)**: Herramientas GUI para añadir o quitar drivers.
* **4. Eliminar Bloatware (Apps)**: Herramienta GUI para borrar aplicaciones Appx.
* **5. Servicios del Sistema**: Herramienta GUI para deshabilitar o restaurar servicios.
* **6. Tweaks y Registro**: Herramienta GUI para aplicar optimizaciones e importar archivos .reg.
* **7. Herramientas de Limpieza**: Utilidades de reparación (DISM/SFC).
* **8. Despliegue: WIM a VHD/VHDX**: Herramienta de creación de discos virtuales bootables.
* **9. Configurar Rutas de Trabajo**: Configuración de directorios de montaje y temporales.

### 3. Integrar Drivers (Controladores)

* **1. Inyectar Drivers (Instalacion Inteligente)**:
    * **Carga Flexible**: Usa el botón `[CARPETA] Cargar...` para escanear directorios completos o `+ Agregar Archivo .INF` para archivos sueltos.
    * **Análisis Profundo**: Lee la versión interna (`DriverVer`) de cada archivo `.inf` y la compara con los drivers ya instalados en la imagen.
    * **Visualización**: Muestra una tabla detallada con Estado, Nombre, Clase y **Versión**. Marca en amarillo los drivers ya existentes.
* **2. Desinstalar Drivers**: Escanea el almacén de drivers de la imagen y lista los controladores de terceros (renombrados como `oemXX.inf`). Permite seleccionar y eliminar drivers problemáticos u obsoletos.

### 4. Eliminar Bloatware (Apps)

Abre una interfaz gráfica que lista todas las aplicaciones `AppxProvisionedPackage` detectadas en la imagen.
* **Código de Colores**:
    * **Verde**: Apps del sistema (Calculadora, Fotos, Store). No se recomienda borrar.
    * **Naranja**: Bloatware común recomendado para borrar.
    * **Blanco**: Otras apps.
* Permite selección múltiple y eliminación segura.

### 5. Servicios del Sistema

Carga los hives del registro y muestra una interfaz con pestañas por categorías (Estandar, Avanzado, Telemetría, etc.).
* Lee el estado actual (`Start`) de cada servicio en la imagen offline.
* Permite deshabilitar servicios masivamente o **Restaurar** su configuración original si te has equivocado.

### 6. Tweaks y Registro

Un potente gestor de registro en modo nativo.
* **Pestañas de Categorías**: Rendimiento, Privacidad, UI, etc.
* **Estado en Tiempo Real**: Muestra si un ajuste está `ACTIVO` (Cian) o `INACTIVO` (Blanco) leyendo directamente el hive montado.
* **Botones Globales**: Permite "Aplicar Selección" o "Restaurar Valores" para revertir cambios.
* **Importador .REG**: Analiza, traduce rutas y muestra vista previa antes de importar claves externas.

### 8. Despliegue: WIM a VHD/VHDX (Native Boot)

Interfaz gráfica diseñada para crear entornos "Windows to Go" o discos virtuales para máquinas virtuales.
* **Origen**: Selecciona tu WIM y el índice deseado.
* **Destino**: Crea un archivo `.vhdx` o `.vhd` nuevo.
* **Configuración Automática**:
    * Tamaño del disco y tipo (Dinámico/Fijo).
    * Esquema de particiones: **GPT (UEFI)** o **MBR (Legacy BIOS)**.
    * Creación automática de particiones de sistema (EFI/System Reserved) y formateo.
    * Aplicación de la imagen y configuración del arranque (`BCDBOOT`).
* Incluye **Tooltips** explicativos para cada opción.

### 7. Herramientas de Limpieza

Requiere una imagen montada. Ofrece un menú con las siguientes herramientas:

* **1. Verificar Salud de Imagen**: `DISM /... /CheckHealth`.
* **2. Escaneo Avanzado de Salud**: `DISM /... /ScanHealth`.
* **3. Reparar Imagen**: `DISM /... /RestoreHealth` (con lógica de fallback a fuente WIM).
* **4. Reparación SFC (Offline)**: Ejecuta `SFC /scannow` redirigiendo los directorios.
* **5. Analizar Almacen de Componentes**: `DISM /... /AnalyzeComponentStore`.
* **6. Limpieza de Componentes**: `DISM /... /StartComponentCleanup /ResetBase`.
* **7. Ejecutar TODO**: Secuencia automática de mantenimiento completo con comprobaciones de seguridad.

## Notas Importantes

* **COPIA DE SEGURIDAD:** Es **altamente recomendable** realizar una copia de seguridad de tu imagen de Windows antes de utilizar las funciones de cambio de edición o reparación.
* **COMPATIBILIDAD:** El script traduce automáticamente las claves de registro para edición offline, protegiendo el sistema operativo del técnico.
* **IDIOMA:** El script y sus mensajes en consola están en español.

## Descargo de Responsabilidad

Este script realiza operaciones avanzadas que modifican archivos de imagen de Windows y el registro del sistema. El autor, **SOFTMAXTER**, no se hace responsable de la pérdida de datos o daños que puedan ocurrir.

**Se recomienda encarecidamente crear una copia de seguridad de tus archivos `.wim` antes de utilizar esta herramienta.**

## Autor y Colaboradores

* **Autor Principal**: SOFTMAXTER
* **Análisis y refinamiento de código**: Realizado en colaboración con **Gemini**, para garantizar calidad, seguridad y compatibilidad internacional del script.

---
### Cómo Contribuir

Si deseas contribuir al desarrollo de este script:

1.  Haz un Fork del repositorio.
2.  Crea una nueva rama (`git checkout -b feature/nueva-funcionalidad`).
3.  Realiza tus cambios y haz commit (`git commit -am 'Añade nueva funcionalidad'`).
4.  Haz Push a la rama (`git push origin feature/nueva-funcionalidad`).
5.  Abre un Pull Request.
