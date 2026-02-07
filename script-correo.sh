#!/bin/bash

# ============================================
# SERVIDOR DE CORREO - SCRIPT UNIFICADO
# ============================================

# Comprobar si se está ejecutando como root
if [ "$EUID" -ne 0 ]; then
  echo "Por favor, ejecuta este script como root."
  exit 1
fi

# Variables globales
HOSTNAME_REAL=$(hostname)
NETWORK_IP=$(ip -o -f inet addr show enp0s3 2>/dev/null | awk '{print $4}' | cut -d'/' -f1)
NETWORK_MASK=$(ip -o -f inet addr show enp0s3 2>/dev/null | awk '{print $4}')

# Fallback si enp0s3 no existe
if [ -z "$NETWORK_MASK" ]; then
    NETWORK_MASK=$(ip -o -f inet addr show | grep -v "127.0.0.1" | head -n 1 | awk '{print $4}')
fi

# ============================================
# CREAR ARCHIVOS NECESARIOS
# ============================================

crear_playbook_ansible() {
    cat > /tmp/install_mail.yml << 'EOF'
---
- name: Instalar servidor de correo
  hosts: localhost
  become: yes

  tasks:
    - name: Actualizar repositorios
      apt:
        update_cache: yes

    - name: Instalar Postfix
      apt:
        name: postfix
        state: present

    - name: Asegurar que Postfix está activo
      service:
        name: postfix
        state: started
        enabled: yes
EOF
}

crear_dockerfile() {
    cat > /tmp/Dockerfile << 'EOF'
FROM ubuntu:22.04

RUN apt update && apt install -y netcat-openbsd

EXPOSE 2525

CMD ["nc", "-lk", "-p", "2525"]
EOF
}

# ============================================
# INSTALACIÓN INICIAL DE IMAGEN DOCKER
# ============================================

echo "========================================="
echo "   SERVIDOR DE CORREO - INICIO"
echo "========================================="
echo "Hostname: $HOSTNAME_REAL"
echo "Red: $NETWORK_MASK"
echo "Estado Postfix: $(systemctl is-active postfix 2>/dev/null || echo 'no instalado')"
echo "========================================="
echo ""

# Verificar si Docker está instalado
if command -v docker &> /dev/null; then
    echo "[INFO] Docker detectado. Verificando imagen mail-server..."
    
    # Verificar si la imagen ya existe
    if ! docker images | grep -q "mail-server"; then
        echo "[INFO] Creando imagen Docker mail-server..."
        crear_dockerfile
        
        if docker build -t mail-server /tmp/; then
            echo "[OK] Imagen Docker 'mail-server' creada correctamente."
        else
            echo "[AVISO] No se pudo crear la imagen Docker. Continuando..."
        fi
    else
        echo "[OK] Imagen Docker 'mail-server' ya existe."
    fi
else
    echo "[INFO] Docker no está instalado. Se instalará cuando lo requieras."
fi

echo ""

# ============================================
# INSTALACIÓN AUTOMÁTICA INICIAL DE POSTFIX
# ============================================

# Solo ejecutar instalación automática si no hay parámetros
if [ $# -eq 0 ]; then
    echo "--- Iniciando configuración automática del servidor de correo ---"

    # 1. Actualizar repositorios
    echo "[INFO] Actualizando repositorios..."
    if apt-get update -qq; then
        echo "[OK] Repositorios actualizados correctamente."
    else
        echo "[ERROR] Fallo al actualizar repositorios."
        exit 1
    fi

    # 2. Instalación de Postfix (Sitio de Internet)
    echo "[INFO] Instalando Postfix..."
    debconf-set-selections <<< "postfix postfix/main_mailer_type select Internet Site"
    debconf-set-selections <<< "postfix postfix/mailname string $HOSTNAME_REAL"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y postfix; then
        echo "[OK] Postfix instalado correctamente."
    else
        echo "[ERROR] Fallo al instalar Postfix."
        exit 1
    fi

    # 3. Configuración de Postfix (main.cf)
    echo "[INFO] Configurando Postfix..."
    POSTFIX_CONF="/etc/postfix/main.cf"

    # Agregar mydomain
    if ! grep -q "^mydomain =" "$POSTFIX_CONF"; then
        echo "mydomain = $HOSTNAME_REAL.org" >> "$POSTFIX_CONF"
    else
        sed -i "s/^mydomain =.*/mydomain = $HOSTNAME_REAL.org/" "$POSTFIX_CONF"
    fi

    # Agregar red a mynetworks
    if [ -n "$NETWORK_MASK" ]; then
        if grep -q "^mynetworks =" "$POSTFIX_CONF"; then
            if ! grep -q "$NETWORK_MASK" "$POSTFIX_CONF"; then
                 sed -i "\|^mynetworks =| s|$| $NETWORK_MASK|" "$POSTFIX_CONF"
            fi
        fi
    fi

    # 4. Reiniciar Postfix
    echo "[INFO] Reiniciando Postfix..."
    if systemctl restart postfix; then
        echo "[OK] Postfix reiniciado y funcionando correctamente."
    else
        echo "[ERROR] Fallo al reiniciar Postfix."
        exit 1
    fi

    # 5. Instalar mailutils
    echo "[INFO] Instalando mailutils..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y mailutils; then
        echo "[OK] Mailutils instalado correctamente."
    else
        echo "[ERROR] Fallo al instalar mailutils."
    fi
fi

# ============================================
# FUNCIONES DEL MENÚ
# ============================================

crear_usuario() {
    echo "--- Crear Nuevo Usuario ---"
    read -p "Introduce el nombre del nuevo usuario: " username
    
    if id "$username" &>/dev/null; then
        echo "[AVISO] El usuario '$username' ya existe. Por favor, intenta con otro nombre."
    else
        if useradd -m -s /bin/bash "$username"; then
            echo "[OK] Usuario '$username' creado correctamente."
            echo "Por favor, introduce la contraseña para el nuevo usuario:"
            passwd "$username"
        else
            echo "[ERROR] No se pudo crear el usuario. Verifica los logs."
        fi
    fi
    read -p "Presiona ENTER para volver al menú..."
}

listar_usuarios() {
    echo "--- Usuarios del Sistema (UID >= 1000) ---"
    awk -F: '$3 >= 1000 && $1 != "nobody" {print "Usuario: " $1 " (UID: " $3 ")"}' /etc/passwd
    read -p "Presiona ENTER para volver al menú..."
}

instalar_extras() {
    echo "--- Instalación de Dovecot, Apache y Firewall ---"
    
    # Instalación Dovecot
    echo "[INFO] Instalando Dovecot..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y dovecot-core dovecot-imapd dovecot-pop3d; then
        echo "[OK] Dovecot instalado correctamente."
    else
        echo "[ERROR] Fallo al instalar Dovecot."
        read -p "Presiona ENTER para volver al menú..."
        return 1
    fi
    
    # Instalación Apache2
    echo "[INFO] Instalando Apache2..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y apache2; then
        echo "[OK] Apache2 instalado correctamente."
    else
        echo "[ERROR] Fallo al instalar Apache2."
    fi
    
    # Firewall UFW
    echo "[INFO] Configurando Firewall..."
    if ! command -v ufw &> /dev/null; then
        apt-get install -y ufw
    fi
    ufw allow 143/tcp
    ufw allow 25/tcp
    ufw allow ssh 
    echo "[INFO] Reglas de firewall aplicadas (puertos 25, 143, ssh)."
    ufw enable
    
    # Configuración Dovecot
    DOVECOT_AUTH_CONF="/etc/dovecot/conf.d/10-auth.conf"
    
    if [ -f "$DOVECOT_AUTH_CONF" ]; then
        echo "[INFO] Modificando configuración de Dovecot..."
        sed -i 's/^#disable_plaintext_auth =.*/disable_plaintext_auth = no/' "$DOVECOT_AUTH_CONF"
        sed -i 's/^disable_plaintext_auth =.*/disable_plaintext_auth = no/' "$DOVECOT_AUTH_CONF"
        
        if grep -q "^auth_mechanisms =" "$DOVECOT_AUTH_CONF"; then
             if ! grep -q "login" "$DOVECOT_AUTH_CONF"; then
                sed -i "/^auth_mechanisms =/ s/$/ login/" "$DOVECOT_AUTH_CONF"
             fi
        fi
        
        if systemctl restart dovecot; then
            echo "[OK] Configuración de Dovecot aplicada y servicio reiniciado."
        else
            echo "[ERROR] Fallo al reiniciar Dovecot."
        fi
    else
        echo "[ERROR] No se encontró el archivo $DOVECOT_AUTH_CONF."
    fi
    
    read -p "Presiona ENTER para volver al menú..."
}

instalar_con_ansible() {
    echo "--- Instalación con Ansible ---"
    
    # Verificar si Ansible está instalado
    if ! command -v ansible-playbook &> /dev/null; then
        echo "[INFO] Ansible no está instalado. Instalando..."
        if apt-get install -y ansible; then
            echo "[OK] Ansible instalado correctamente."
        else
            echo "[ERROR] Fallo al instalar Ansible."
            read -p "Presiona ENTER para volver al menú..."
            return 1
        fi
    fi
    
    # Crear playbook
    crear_playbook_ansible
    
    echo "[INFO] Ejecutando playbook de Ansible..."
    if ansible-playbook /tmp/install_mail.yml; then
        echo "[OK] Instalación con Ansible completada."
    else
        echo "[ERROR] Fallo en la ejecución del playbook."
    fi
    
    read -p "Presiona ENTER para volver al menú..."
}

instalar_con_docker() {
    echo "--- Instalación con Docker ---"
    
    # Verificar si Docker está instalado
    if ! command -v docker &> /dev/null; then
        echo "[INFO] Docker no está instalado. Instalando..."
        if apt-get install -y docker.io; then
            systemctl start docker
            systemctl enable docker
            echo "[OK] Docker instalado correctamente."
        else
            echo "[ERROR] Fallo al instalar Docker."
            read -p "Presiona ENTER para volver al menú..."
            return 1
        fi
    fi
    
    # Crear Dockerfile
    crear_dockerfile
    
    echo "[INFO] Construyendo imagen Docker..."
    if docker build -t mail-server /tmp/; then
        echo "[OK] Imagen Docker creada correctamente."
        
        # Detener contenedor existente si hay uno
        docker stop mail-server-container 2>/dev/null
        docker rm mail-server-container 2>/dev/null
        
        echo "[INFO] Ejecutando contenedor..."
        if docker run -d -p 2525:2525 --name mail-server-container mail-server; then
            echo "[OK] Contenedor ejecutándose en puerto 2525"
            echo "[INFO] Puedes probarlo con: telnet localhost 2525"
        else
            echo "[ERROR] Fallo al ejecutar el contenedor."
        fi
    else
        echo "[ERROR] Fallo al construir la imagen Docker."
    fi
    
    read -p "Presiona ENTER para volver al menú..."
}

eliminar_servicio() {
    echo "--- Eliminación del Servicio ---"
    read -p "¿Estás seguro de eliminar Postfix, Dovecot y Apache? (s/n): " confirmar
    
    if [[ "$confirmar" =~ ^[sS]$ ]]; then
        echo "[INFO] Eliminando servicios..."
        apt purge -y postfix dovecot-core dovecot-imapd dovecot-pop3d apache2
        apt autoremove -y
        echo "[OK] Servicios eliminados correctamente."
    else
        echo "[INFO] Operación cancelada."
    fi
    
    read -p "Presiona ENTER para volver al menú..."
}

iniciar_servicio() {
    echo "--- Iniciar Servicio ---"
    if systemctl start postfix; then
        echo "[OK] Postfix iniciado correctamente."
    else
        echo "[ERROR] Fallo al iniciar Postfix."
    fi
    read -p "Presiona ENTER para volver al menú..."
}

detener_servicio() {
    echo "--- Detener Servicio ---"
    if systemctl stop postfix; then
        echo "[OK] Postfix detenido correctamente."
    else
        echo "[ERROR] Fallo al detener Postfix."
    fi
    read -p "Presiona ENTER para volver al menú..."
}

ver_logs() {
    echo "========================================="
    echo "   LOGS DE POSTFIX (últimas 20 líneas)"
    echo "========================================="
    journalctl -u postfix --no-pager | tail -20
    echo "========================================="
    read -p "Presiona ENTER para volver al menú..."
}

editar_config() {
    echo "--- Editar Configuración ---"
    POSTFIX_CONF="/etc/postfix/main.cf"
    
    if [ -f "$POSTFIX_CONF" ]; then
        ${EDITOR:-nano} "$POSTFIX_CONF"
        read -p "¿Deseas reiniciar Postfix para aplicar cambios? (s/n): " reiniciar
        if [[ "$reiniciar" =~ ^[sS]$ ]]; then
            systemctl restart postfix
            echo "[OK] Postfix reiniciado."
        fi
    else
        echo "[ERROR] No se encontró el archivo de configuración."
    fi
    
    read -p "Presiona ENTER para volver al menú..."
}

ver_estado_servicios() {
    echo "========================================="
    echo "   ESTADO DE SERVICIOS"
    echo "========================================="
    
    servicios=("postfix" "dovecot" "apache2")
    
    for servicio in "${servicios[@]}"; do
        if systemctl is-active --quiet "$servicio"; then
            echo "✓ $servicio: ACTIVO"
        else
            echo "✗ $servicio: INACTIVO"
        fi
    done
    
    # Estado de Docker
    if command -v docker &> /dev/null; then
        echo ""
        echo "--- CONTENEDORES DOCKER ---"
        if docker ps --filter "name=mail-server-container" --format "table {{.Names}}\t{{.Status}}" | grep -q mail-server-container; then
            echo "✓ mail-server-container: ACTIVO"
        else
            echo "✗ mail-server-container: INACTIVO"
        fi
    fi
    
    echo "========================================="
    read -p "Presiona ENTER para volver al menú..."
}

# ============================================
# MENÚ PRINCIPAL
# ============================================

mostrar_menu() {
    clear
    echo "========================================="
    echo "   GESTIÓN DE SERVIDOR DE CORREO"
    echo "========================================="
    echo "1.  Crear usuario nuevo"
    echo "2.  Listar usuarios"
    echo "3.  Instalar extras (Dovecot, Apache, Firewall)"
    echo "4.  Instalar con Ansible"
    echo "5.  Instalar con Docker"
    echo "6.  Eliminar servicio"
    echo "7.  Iniciar servicio (Postfix)"
    echo "8.  Detener servicio (Postfix)"
    echo "9.  Ver logs"
    echo "10. Editar configuración"
    echo "11. Ver estado de servicios"
    echo "12. Salir"
    echo "========================================="
}

# ============================================
# EJECUCIÓN POR PARÁMETROS
# ============================================

case "$1" in
    instalar-comandos)
        instalar_extras
        exit 0
        ;;
    instalar-ansible)
        instalar_con_ansible
        exit 0
        ;;
    instalar-docker)
        instalar_con_docker
        exit 0
        ;;
    estado)
        ver_estado_servicios
        exit 0
        ;;
    logs)
        ver_logs
        exit 0
        ;;
    start)
        systemctl start postfix
        echo "[OK] Postfix iniciado."
        exit 0
        ;;
    stop)
        systemctl stop postfix
        echo "[OK] Postfix detenido."
        exit 0
        ;;
    eliminar)
        eliminar_servicio
        exit 0
        ;;
    *)
        # Si no hay parámetros o es inválido, mostrar menú
        ;;
esac

# ============================================
# BUCLE PRINCIPAL DEL MENÚ
# ============================================

while true; do
    mostrar_menu
    read -p "Selecciona una opción: " opcion
    
    case $opcion in
        1)
            crear_usuario
            ;;
        2)
            listar_usuarios
            ;;
        3)
            instalar_extras
            ;;
        4)
            instalar_con_ansible
            ;;
        5)
            instalar_con_docker
            ;;
        6)
            eliminar_servicio
            ;;
        7)
            iniciar_servicio
            ;;
        8)
            detener_servicio
            ;;
        9)
            ver_logs
            ;;
        10)
            editar_config
            ;;
        11)
            ver_estado_servicios
            ;;
        12)
            echo "Saliendo..."
            exit 0
            ;;
        *)
            echo "Opción no válida."
            sleep 1
            ;;
    esac
done
