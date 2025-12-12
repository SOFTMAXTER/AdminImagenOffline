# AdminImagenOffline V1.4 by SOFTMAXTER

**AdminImagenOffline** es un completo script en PowerShell, diseñado para simplificar la administración y el mantenimiento de imágenes de instalación de Windows (`.wim`, `.esd`, `.vhd/vhdx`). El script encapsula complejas operaciones de `DISM`, manipulación del Registro y otras herramientas del sistema en una interfaz de menús interactiva y fácil de usar.

Fue creado para administradores de TI, técnicos de soporte y entusiastas de la personalización de Windows que necesitan modificar, limpiar, reparar, optimizar o convertir imágenes del sistema operativo de manera eficiente y sin conexión.

## Características Principales

* **Interfaz Híbrida (Consola + GUI)**: Combina la rapidez de la consola para operaciones básicas con interfaces gráficas (Windows Forms) modernas para la gestión de drivers, servicios, bloatware y registro.
* **Auto-Actualizador**: El script busca automáticamente nuevas versiones en GitHub al iniciar y ofrece al usuario la posibilidad de actualizarse.
* **Configuración Persistente**: Guarda las rutas de trabajo (Directorio de Montaje y Directorio Temporal) en un archivo `config.json` para que las preferencias del usuario sean permanentes.
* **Gestión de Directorios**: Comprueba y gestiona automáticamente la creación de los directorios de trabajo necesarios.
* **Detección Automática**: Verifica al inicio si ya existe una imagen montada en el sistema y carga su información dinámicamente.
* **Autoelevación de Privilegios**: Incluye un lanzador `Run.bat` que asegura la ejecución con permisos de Administrador.
* **Gestión de Imágenes**: Montaje, desmontaje (con descartes), guardado de cambios (commit/append) y recarga rápida.
* **Edición de Índices WIM**: Exportación y eliminación de índices específicos.
* **Conversión de Formatos**: ESD a WIM y VHD/VHDX a WIM.
* **Cambio de Edición de Windows**: Detección y cambio de edición (ej. Home a Pro) offline.
* **Gestión Avanzada de Drivers**:
    * **Inyector Inteligente**: Compara una carpeta local de drivers contra la imagen montada, detectando duplicados y permitiendo la inyección masiva.
    * **Desinstalador de Drivers**: Lista los drivers de terceros (OEM) instalados en la imagen y permite su eliminación selectiva.
* **Eliminación de Bloatware**: Interfaz gráfica con clasificación por colores (Verde=Seguro, Naranja=Recomendado, Blanco=Otros) para eliminar aplicaciones preinstaladas (Appx).
* **Optimización de Servicios**: Permite deshabilitar servicios del sistema innecesarios organizados por categorías mediante una interfaz de pestañas.
* **Tweaks y Registro Offline**:
    * **Gestor Nativo**: Aplica ajustes de rendimiento y privacidad escribiendo directamente en el registro offline (sin depender de `reg.exe` para la escritura), garantizando estabilidad.
    * **Importador .REG Inteligente**: Permite importar archivos `.reg` externos. Incluye una **Vista Previa de Análisis** que traduce automáticamente las rutas (ej. `HKEY_CLASSES_ROOT` o `HKLM\SOFTWARE`) a sus ubicaciones offline correctas y muestra una comparativa de valores antes de aplicar.
* **Suite de Limpieza y Reparación**: `CheckHealth`, `ScanHealth`, `RestoreHealth` (con soporte para fuente WIM alternativa), `SFC` offline y limpieza de componentes (`ResetBase`).

---

## Requisitos

* Sistema Operativo Windows (Host).
* PowerShell 5.1 o superior.
* Privilegios de Administrador para ejecutar el script.
* Conexión a internet (opcional, para el auto-actualizador).

---

## Modo de Uso

1.  Descarga la estructura de carpetas (el archivo `Run.bat` debe estar en el directorio raíz y `AdminImagenOffline.ps1`, `Ajustes.ps1` y `Servicios.ps1` dentro de la carpeta `Script` o `Script\Catalogos`).
2.  Haz clic derecho sobre el archivo `Run.bat` y selecciona **"Ejecutar como administrador"**.
3.  Sigue las instrucciones en pantalla.
4.  Si es la primera ejecución, ve al menú **[8] Configurar Rutas de Trabajo** para definir tus directorios.

---

## Explicación Detallada de los Menús

### Menú Principal

* **1. Gestionar Imagen**: Operaciones base de WIM (Montar, Guardar, Exportar, Convertir).
* **2. Cambiar Edicion de Windows**: Actualización de edición (ej. Home -> Pro).
* **3. Integrar Drivers (Controladores)**: Herramientas GUI para añadir o quitar drivers.
* **4. Eliminar Bloatware (Apps)**: Herramienta GUI para borrar aplicaciones Appx.
* **5. Servicios del Sistema**: Herramienta GUI para deshabilitar servicios.
* **6. Tweaks y Registro**: Herramienta GUI para aplicar optimizaciones e importar archivos .reg.
* **7. Herramientas de Limpieza**: Utilidades de reparación (DISM/SFC).
* **8. Configurar Rutas de Trabajo**: Configuración de directorios de montaje y temporales.

### 3. Integrar Drivers (Controladores)

* **1. Inyectar Drivers (Instalacion Inteligente)**: Abre una ventana que compara los archivos `.inf` de una carpeta local con los drivers ya presentes en la imagen. Marca en amarillo los ya instalados y permite inyectar solo los nuevos.
* **2. Desinstalar Drivers**: Escanea el almacén de drivers de la imagen y lista los controladores de terceros. Permite seleccionar y eliminar drivers problemáticos u obsoletos para reducir el tamaño de la imagen.

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
* Permite marcar servicios para deshabilitarlos masivamente.

### 6. Tweaks y Registro

Un potente gestor de registro en modo nativo.
* **Pestañas de Categorías**: Rendimiento, Privacidad, UI, etc.
* **Estado en Tiempo Real**: Muestra si un ajuste está `ACTIVO` (Cian) o `INACTIVO` (Gris/Blanco) leyendo directamente el hive montado.
* **Aplicación Segura**: Usa comandos nativos de PowerShell para aplicar cambios y verifica la escritura inmediatamente.
* **Importador .REG**:
    * Botón para importar archivos de registro externos.
    * **Analizador de Seguridad**: Antes de importar, muestra una ventana de "Vista Previa" que detalla qué claves se crearán, modificarán o eliminarán.
    * **Traducción de Rutas**: Convierte automáticamente rutas como `HKEY_CLASSES_ROOT` o `HKEY_CURRENT_USER` a sus rutas físicas correspondientes en la imagen montada (`OfflineSoftware\Classes`, `OfflineUser`, etc.).

### 7. Herramientas de Limpieza

Requiere una imagen montada. Ofrece un menú con las siguientes herramientas:

* **1. Verificar Salud de Imagen**: `DISM /... /CheckHealth`.
* **2. Escaneo Avanzado de Salud**: `DISM /... /ScanHealth`.
* **3. Reparar Imagen**: `DISM /... /RestoreHealth`. (Soporta fuente WIM alternativa si falla).
* **4. Reparación SFC (Offline)**: Ejecuta `SFC /scannow` redirigiendo los directorios de boot y windows a la imagen montada.
* **5. Analizar Almacen de Componentes**: `DISM /... /AnalyzeComponentStore`.
* **6. Limpieza de Componentes**: `DISM /... /StartComponentCleanup /ResetBase`.
* **7. Ejecutar TODO**: Secuencia automática de mantenimiento completo.

## Notas Importantes

* **COPIA DE SEGURIDAD:** Es **altamente recomendable** realizar una copia de seguridad de tu imagen de Windows antes de utilizar las funciones de cambio de edición o reparación.
* **COMPATIBILIDAD:** El script traduce automáticamente las claves de registro para edición offline, protegiendo el sistema operativo del técnico.
* **IDIOMA:** El script y sus mensajes en consola están en español.

## Descargo de Responsabilidad

Este script realiza operaciones avanzadas que modifican archivos de imagen de Windows. El autor, **SOFTMAXTER**, no se hace responsable de la pérdida de datos o daños que puedan ocurrir en tus archivos WIM.

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
