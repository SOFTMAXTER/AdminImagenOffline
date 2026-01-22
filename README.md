# AdminImagenOffline V1.4.3 by SOFTMAXTER

**AdminImagenOffline** es un completo script en PowerShell, diseñado para simplificar la administración y el mantenimiento de imágenes de instalación de Windows (`.wim`, `.esd`, `.vhd/vhdx`). El script encapsula complejas operaciones de `DISM`, manipulación del Registro y otras herramientas del sistema en una interfaz de menús interactiva y fácil de usar.

Fue creado para administradores de TI, técnicos de soporte y entusiastas de la personalización de Windows que necesitan modificar, limpiar, reparar, optimizar o convertir imágenes del sistema operativo de manera eficiente y sin conexión.

## Características Principales

* **Interfaz Híbrida (Consola + GUI)**: Combina la rapidez de la consola para operaciones básicas con interfaces gráficas (Windows Forms) modernas para la gestión de drivers, servicios, bloatware, registro y metadatos.
* **Auto-Actualizador**: El script busca automáticamente nuevas versiones en GitHub al iniciar y ofrece al usuario la posibilidad de actualizarse.
* **Configuración Persistente**: Guarda las rutas de trabajo (Directorio de Montaje y Directorio Temporal) en un archivo `config.json` para que las preferencias del usuario sean permanentes.
* **Robustez y Seguridad**:
    * **Protección de Hives**: Implementa limpieza de memoria (`GC`) y pausas de seguridad para evitar la corrupción del registro al desmontar.
    * **Gestión de Directorios**: Comprueba y gestiona automáticamente la creación de los directorios de trabajo.
    * **Seguridad ESD**: Detecta si se intenta montar una imagen `.esd` (solo lectura/comprimida), advierte al usuario sobre los riesgos de corrupción y recomienda la conversión previa o el guardado como nuevo archivo WIM.
* **Detección Automática**: Verifica al inicio si ya existe una imagen montada en el sistema y carga su información dinámicamente.
* **Autoelevación de Privilegios**: Incluye un lanzador `Run.bat` que asegura la ejecución con permisos de Administrador.
* **Gestión de Imágenes**:
    * Montaje, desmontaje (con descartes) y recarga rápida.
    * Guardado de cambios: Commit (sobreescribir), Append (nuevo índice) y **Save As New WIM** (captura como archivo nuevo).
* **Editor de Metadatos WIM**: Nueva interfaz gráfica para visualizar y editar propiedades de la imagen (Nombre, Descripción, DisplayName) y ver datos de solo lectura (Arquitectura, Versión, Tamaño).
* **Edición de Índices WIM**: Exportación y eliminación de índices específicos.
* **Conversión de Formatos**: ESD a WIM y VHD/VHDX a WIM.
* **Cambio de Edición de Windows**: Detección y cambio de edición (ej. Home a Pro) offline.
* **Gestión Avanzada de Drivers**:
    * **Inyector Flexible (v5.1)**: Interfaz que permite cargar carpetas recursivamente o agregar archivos `.inf` individuales "al vuelo". Incluye detección precisa por **Versión** y **Clase** para evitar duplicados.
    * **Desinstalador de Drivers**: Lista los drivers de terceros (OEM) instalados en la imagen y permite su eliminación selectiva.
* **Eliminación de Bloatware**: Interfaz gráfica con clasificación por colores (Verde=Seguro, Naranja=Recomendado, Blanco=Otros) para eliminar aplicaciones preinstaladas (Appx).
* **Optimización de Servicios**: Permite deshabilitar servicios del sistema innecesarios organizados por categorías mediante una interfaz de pestañas.
* **Tweaks y Registro Offline**:
    * **Gestor Nativo**: Aplica ajustes de rendimiento y privacidad escribiendo directamente en el registro offline.
    * **Importador .REG Inteligente**: Permite importar archivos `.reg` externos.
    * **Traducción de Rutas**: Convierte automáticamente rutas como `HKEY_CLASSES_ROOT` (a `OfflineSoftware\Classes`) o `HKLM\SOFTWARE` a sus ubicaciones offline correctas.
    * **Vista Previa**: Muestra una comparativa de valores antes de aplicar los cambios.
* **Suite de Limpieza y Reparación**: `CheckHealth`, `ScanHealth`, `RestoreHealth` (con soporte para fuente WIM alternativa), `SFC` offline y limpieza de componentes (`ResetBase`).

---

## Requisitos

* Sistema Operativo Windows (Host).
* PowerShell 5.1 o superior.
* Privilegios de Administrador para ejecutar el script.
* Conexión a internet (opcional, para el auto-actualizador).

---

## Modo de Uso

1.  Descarga la estructura de carpetas (el archivo `Run.bat` debe estar en el directorio raíz y `AdminImagenOffline.ps1` dentro de la carpeta `Script`. Los catálogos deben estar en `Script\Catalogos` o en la raíz de `Script`).
2.  Haz clic derecho sobre el archivo `Run.bat` y selecciona **"Ejecutar como administrador"**.
3.  Sigue las instrucciones en pantalla.
4.  Si es la primera ejecución, ve al menú **[8] Configurar Rutas de Trabajo** para definir tus directorios.

---

## Explicación Detallada de los Menús

### Menú Principal

* **1. Gestionar Imagen**: Operaciones base de WIM (Montar, Guardar, Exportar, Convertir) y **Editor de Metadatos**.
* **2. Cambiar Edicion de Windows**: Actualización de edición (ej. Home -> Pro).
* **3. Integrar Drivers (Controladores)**: Herramientas GUI para añadir o quitar drivers.
* **4. Eliminar Bloatware (Apps)**: Herramienta GUI para borrar aplicaciones Appx.
* **5. Servicios del Sistema**: Herramienta GUI para deshabilitar servicios.
* **6. Tweaks y Registro**: Herramienta GUI para aplicar optimizaciones e importar archivos .reg.
* **7. Herramientas de Limpieza**: Utilidades de reparación (DISM/SFC).
* **8. Configurar Rutas de Trabajo**: Configuración de directorios de montaje y temporales.

### 1. Gestionar Imagen (Submenú)

Además de las funciones estándar, incluye:
* **Editar Info/Metadatos**: Abre una ventana para cambiar el nombre y descripción que aparecen durante la instalación de Windows.
* **Guardar Cambios**: Ofrece la opción crítica de "Guardar en un NUEVO archivo WIM", vital si se trabaja con orígenes ESD o VHD.

### 3. Integrar Drivers (Controladores)

* **1. Inyectar Drivers (Instalacion Inteligente)**:
    * **Carga Flexible**: Usa el botón `[CARPETA] Cargar...` para escanear directorios completos o `+ Agregar Archivo .INF` para archivos sueltos.
    * **Análisis Profundo**: Lee la versión interna (`DriverVer`) de cada archivo `.inf` y la compara con los drivers ya instalados en la imagen.
    * **Visualización**: Muestra una tabla detallada con Estado, Nombre, Clase y **Versión**. Marca en amarillo los drivers ya existentes para evitar redundancia.
* **2. Desinstalalar Drivers**: Escanea el almacén de drivers de la imagen y lista los controladores de terceros (renombrados como `oemXX.inf`). Permite seleccionar y eliminar drivers problemáticos u obsoletos.

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
* **Estado en Tiempo Real**: Muestra si un ajuste está `ACTIVO` (Cian) o `INACTIVO` (Blanco) leyendo directamente el hive montado.
* **Importador .REG**:
    * Analiza y traduce rutas complejas (incluyendo `HKCR`) para que funcionen en una imagen offline.
    * Muestra una vista previa de los cambios (Crear clave, Modificar valor, Eliminar) antes de tocar el registro real.

### 7. Herramientas de Limpieza

Requiere una imagen montada. Ofrece un menú con las siguientes herramientas:

* **1. Verificar Salud de Imagen**: `DISM /... /CheckHealth`.
* **2. Escaneo Avanzado de Salud**: `DISM /... /ScanHealth`.
* **3. Reparar Imagen**: `DISM /... /RestoreHealth`. (Soporta fuente WIM alternativa interactiva si falla la reparación automática).
* **4. Reparación SFC (Offline)**: Ejecuta `SFC /scannow` redirigiendo los directorios de boot y windows a la imagen montada.
* **5. Analizar Almacen de Componentes**: `DISM /... /AnalyzeComponentStore`.
* **6. Limpieza de Componentes**: `DISM /... /StartComponentCleanup /ResetBase`.
* **7. Ejecutar TODO**: Secuencia automática de mantenimiento completo con lógica de decisión inteligente (salta pasos si la imagen está saludable).

## Notas Importantes

* **IMÁGENES ESD:** El script detecta archivos `.esd` y advierte sobre su naturaleza de solo lectura/comprimida. Se recomienda convertirlos a WIM o usar la función "Guardar como Nuevo WIM" para evitar corrupción.
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
