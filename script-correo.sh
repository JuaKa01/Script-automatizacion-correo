#!/bin/bash

# Comprobar si se está ejecutando como root
if [ "$EUID" -ne 0 ]; then
  echo "Por favor, ejecuta este script como root."
  exit 1
fi

# Variables globales
HOSTNAME_REAL=$(hostname)
# Intentar obtener la IP y máscara de la interfaz enp0s3. Si no existe, usa la primera interfaz no-lo.
NETWORK_IP=$(ip -o -f inet addr show enp0s3 2>/dev/null | awk '{print $4}' | cut -d'/' -f1)
NETWORK_MASK=$(ip -o -f inet addr show enp0s3 2>/dev/null | awk '{print $4}')

# Fallback si enp0s3 no existe (por si es una VM con otro nombre de interfaz)
if [ -z "$NETWORK_MASK" ]; then
    NETWORK_MASK=$(ip -o -f inet addr show | grep -v "127.0.0.1" | head -n 1 | awk '{print $4}')
fi


# --- FASE 1: Instalación Automática Inicial ---
echo "--- Iniciando configuración automática del servidor de correo ---"

# 1. Actualizar repositorios
echo "[INFO] Actualizando repositorios..."
apt-get update -qq

# 2. Instalación de Postfix (Sitio de Internet)
echo "[INFO] Instalando Postfix..."
# Preconfigurar debconf para evitar interacción
debconf-set-selections <<< "postfix postfix/main_mailer_type select Internet Site"
debconf-set-selections <<< "postfix postfix/mailname string $HOSTNAME_REAL"
DEBIAN_FRONTEND=noninteractive apt-get install -y postfix

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
# Buscamos la línea mynetworks y añadimos la red al final si no está ya
if [ -n "$NETWORK_MASK" ]; then
    if grep -q "^mynetworks =" "$POSTFIX_CONF"; then
        # Solo añadir si no está ya presente para evitar duplicados infinitos
        if ! grep -q "$NETWORK_MASK" "$POSTFIX_CONF"; then
             sed -i "/^mynetworks =/ s/$/ $NETWORK_MASK/" "$POSTFIX_CONF" # Escape de barras diagonales en sed puede ser complicado, usamos espacio como separador simple si es necesario o comillas diferentes
             # Alternativa más segura para sed con caracteres especiales como /
             sed -i "\|^mynetworks =| s|$| $NETWORK_MASK|" "$POSTFIX_CONF"
        fi
    fi
fi

# 4. Reiniciar Postfix
echo "[INFO] Reiniciando Postfix..."
systemctl restart postfix
echo "[OK] Postfix reiniciado y funcionando correctamente."

# 5. Instalar mailutils
echo "[INFO] Instalando mailutils..."
DEBIAN_FRONTEND=noninteractive apt-get install -y mailutils
echo "[OK] Mailutils instalado correctamente."


# --- Funciones del Menú ---

crear_usuario() {
    echo "--- Crear Nuevo Usuario ---"
    read -p "Introduce el nombre del nuevo usuario: " username
    
    if id "$username" &>/dev/null; then
        echo "[AVISO] El usuario '$username' ya existe. Por favor, intenta con otro nombre."
    else
        # Crear usuario
        # Usamos useradd en lugar de adduser para mayor control y passwd para forzar la interactividad
        useradd -m -s /bin/bash "$username"
        if [ $? -eq 0 ]; then
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
    DEBIAN_FRONTEND=noninteractive apt-get install -y dovecot-core dovecot-imapd dovecot-pop3d
    echo "[OK] Dovecot instalado correctamente."
    
    # Instalación Apache2
    echo "[INFO] Instalando Apache2..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y apache2
    echo "[OK] Apache2 instalado correctamente."
    
    # Firewall UFW
    echo "[INFO] Configurando Firewall..."
    if ! command -v ufw &> /dev/null; then
        apt-get install -y ufw
    fi
    ufw allow 143/tcp
    ufw allow 25/tcp
    # Asegurarnos de no bloquearnos a nosotros mismos con SSH si estamos en remoto
    ufw allow ssh 
    echo "[INFO] Reglas de firewall aplicadas (puertos 25, 143, ssh)."
    ufw enable
    
    # Configuración Dovecot (/etc/dovecot/conf.d/10-auth.conf)
    DOVECOT_AUTH_CONF="/etc/dovecot/conf.d/10-auth.conf"
    
    if [ -f "$DOVECOT_AUTH_CONF" ]; then
        echo "[INFO] Modificando configuración de Dovecot..."
        # Descomentar disable_plaintext_auth y poner a no
        sed -i 's/^#disable_plaintext_auth =.*/disable_plaintext_auth = no/' "$DOVECOT_AUTH_CONF"
        sed -i 's/^disable_plaintext_auth =.*/disable_plaintext_auth = no/' "$DOVECOT_AUTH_CONF"
        
        # Añadir login a auth_mechanisms
        # Buscamos la línea y añadimos 'login' al final si no existe
        if grep -q "^auth_mechanisms =" "$DOVECOT_AUTH_CONF"; then
             if ! grep -q "login" "$DOVECOT_AUTH_CONF"; then
                sed -i "/^auth_mechanisms =/ s/$/ login/" "$DOVECOT_AUTH_CONF"
             fi
        fi
        
        # Reiniciar Dovecot para aplicar cambios
        systemctl restart dovecot
        echo "[OK] Configuración de Dovecot aplicada y servicio reiniciado."
    else
        echo "[ERROR] No se encontró el archivo $DOVECOT_AUTH_CONF. ¿Se instaló Dovecot correctamente?"
    fi
    
    read -p "Presiona ENTER para volver al menú..."
}

# --- Menú Principal ---

mostrar_menu() {
    clear
    echo "========================================="
    echo "   GESTIÓN DE SERVIDOR DE CORREO"
    echo "========================================="
    echo "1. Crear usuario nuevo"
    echo "2. Listar usuarios"
    echo "3. Instalar Dovecot, Apache y configurar Firewall"
    echo "4. Salir"
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
            echo "Saliendo..."
            exit 0
            ;;
        *)
            echo "Opción no válida."
            sleep 1
            ;;
    esac
done
