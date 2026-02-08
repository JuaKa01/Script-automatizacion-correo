                _                        _   _                _   __              _      _ 
     /\        | |                      | | (_)              (_) /_/             | |    | |
    /  \  _   _| |_ ___  _ __ ___   __ _| |_ _  ___ __ _  ___ _  ___  _ __     __| | ___| |
   / /\ \| | | | __/ _ \| '_ ` _ \ / _` | __| |/ __/ _` |/ __| |/ _ \| '_ \   / _` |/ _ \ |
  / ____ \ |_| | || (_) | | | | | | (_| | |_| | (_| (_| | (__| | (_) | | | | | (_| |  __/ |
 /_/    \_\__,_|\__\___/|_| |_| |_|\__,_|\__|_|\___\__,_|\___|_|\___/|_| |_|  \__,_|\___|_|
                     (_)    (_)           | |                                              
  ___  ___ _ ____   ___  ___ _  ___     __| | ___    ___ ___  _ __ _ __ ___  ___           
 / __|/ _ \ '__\ \ / / |/ __| |/ _ \   / _` |/ _ \  / __/ _ \| '__| '__/ _ \/ _ \          
 \__ \  __/ |   \ V /| | (__| | (_) | | (_| |  __/ | (_| (_) | |  | | |  __/ (_) |         
 |___/\___|_|    \_/ |_|\___|_|\___/   \__,_|\___|  \___\___/|_|  |_|  \___|\___/          
                                                                                           


# Script de servidor de correo - Rubén, Juan Cruz y Marta.

Este script Bash sirve para instalar y gestionar un servidor de correo en sistemas Debian/Ubuntu desde un único archivo.
Automatiza la instalación y configuración básica de Postfix y permite administrar el servicio mediante un menú interactivo o usando parámetros por línea de comandos.

## ¿Qué hace?

- Instala y configura Postfix automáticamente
- Detecta la red local y la añade a la configuración
- Permite crear y listar usuarios del sistema
- Instala servicios opcionales:
  - Dovecot (IMAP/POP3)
  - Apache
  - Firewall UFW
- Permite gestionar el servicio:
  - Iniciar / detener Postfix
  - Ver logs
  - Editar configuración
  - Ver estado de los servicios
- Incluye instalación alternativa usando:
  - Ansible
  - Docker (contenedor de prueba en el puerto 2525)

## Requisitos

- Debian / Ubuntu
- Ejecutar como root

## Nota

Script pensado para pruebas, prácticas y entornos de laboratorio.  
No incluye configuración de seguridad avanzada para producción.
