#!/bin/bash

# Script de Gestión de Servidor de Correo
# Versión mejorada

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

# --- FASE 1: Instalación Automática Inicial ---
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

# --- Funciones del Menú ---

crear_usuario() {
    echo "--- Crear Nuevo Usuario ---"
    read -p "Introduce el nombre del nuevo usuario: " username
    
    if id "$username" &>/dev/null; then
        echo "[AVISO] El usuario '$username' ya existe."
        read -p "¿Deseas cambiar su contraseña? (s/n): " cambiar_pass
        if [[ "$cambiar_pass" =~ ^[sS]$ ]]; then
            passwd "$username"
        fi
    else
        # Crear usuario
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
    echo "========================================="
    echo "   Usuarios del Sistema (UID >= 1000)"
    echo "========================================="
    awk -F: '$3 >= 1000 && $1 != "nobody" {printf "%-20s (UID: %5d) Home: %s\n", $1, $3, $6}' /etc/passwd
    echo "========================================="
    echo "Total: $(awk -F: '$3 >= 1000 && $1 != "nobody"' /etc/passwd | wc -l) usuarios"
    echo ""
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
    
    ufw --force allow 143/tcp  # IMAP
    ufw --force allow 25/tcp   # SMTP
    ufw --force allow 80/tcp   # HTTP
    ufw --force allow ssh      # SSH
    
    echo "[INFO] Reglas de firewall aplicadas (puertos 25, 80, 143, ssh)."
    echo "y" | ufw enable
    
    # Configuración Dovecot
    DOVECOT_AUTH_CONF="/etc/dovecot/conf.d/10-auth.conf"
    
    if [ -f "$DOVECOT_AUTH_CONF" ]; then
        echo "[INFO] Modificando configuración de Dovecot..."
        
        # Descomentar y configurar disable_plaintext_auth
        sed -i 's/^#\s*disable_plaintext_auth =.*/disable_plaintext_auth = no/' "$DOVECOT_AUTH_CONF"
        sed -i 's/^disable_plaintext_auth = yes/disable_plaintext_auth = no/' "$DOVECOT_AUTH_CONF"
        
        # Añadir login a auth_mechanisms
        if grep -q "^auth_mechanisms =" "$DOVECOT_AUTH_CONF"; then
            if ! grep "^auth_mechanisms =" "$DOVECOT_AUTH_CONF" | grep -q "login"; then
                sed -i "/^auth_mechanisms =/ s/$/ login/" "$DOVECOT_AUTH_CONF"
            fi
        fi
        
        # Reiniciar Dovecot
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

ver_estado_servicios() {
    echo "========================================="
    echo "   Estado de Servicios"
    echo "========================================="
    
    servicios=("postfix" "dovecot" "apache2")
    
    for servicio in "${servicios[@]}"; do
        if systemctl is-active --quiet "$servicio"; then
            echo "✓ $servicio: ACTIVO"
        else
            echo "✗ $servicio: INACTIVO"
        fi
    done
    
    echo "========================================="
    read -p "Presiona ENTER para volver al menú..."
}

# --- Menú Principal ---

mostrar_menu() {
    clear
    echo "========================================="
    echo "   GESTIÓN DE SERVIDOR DE CORREO"
    echo "========================================="
    echo "Hostname: $HOSTNAME_REAL"
    echo "Red: $NETWORK_MASK"
    echo "========================================="
    echo "1. Crear usuario nuevo"
    echo "2. Listar usuarios"
    echo "3. Instalar Dovecot, Apache y configurar Firewall"
    echo "4. Ver estado de servicios"
    echo "5. Salir"
    echo "========================================="
}

# Bucle principal
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
            ver_estado_servicios
            ;;
        5)
            echo "Saliendo..."
            exit 0
            ;;
        *)
            echo "Opción no válida."
            sleep 1
            ;;
    esac
done
