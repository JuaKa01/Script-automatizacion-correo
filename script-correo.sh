#!/bin/bash

DEFAULT_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
INTERFACE="${DEFAULT_IFACE:-enp0s3}"
DOMAIN_SUFFIX=".org"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "[ERROR] Por favor, ejecuta este script como root."
        exit 1
    fi
}

obtener_datos_red() {
    HOSTNAME_REAL=$(hostname)
    NETWORK_IP=$(ip -o -f inet addr show "$INTERFACE" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1)
    NETWORK_MASK=$(ip -o -f inet addr show "$INTERFACE" 2>/dev/null | awk '{print $4}')

    if [ -z "$NETWORK_MASK" ]; then
        NETWORK_MASK=$(ip -o -f inet addr show | grep -v "127.0.0.1" | head -n 1 | awk '{print $4}')
    fi
}

instalar_postfix() {
    echo "--- Configurando Postfix ---"
    echo "[INFO] Actualizando repositorios..."
    apt-get update -qq

    echo "[INFO] Instalando Postfix..."
    debconf-set-selections <<< "postfix postfix/main_mailer_type select Internet Site"
    debconf-set-selections <<< "postfix postfix/mailname string $HOSTNAME_REAL"
    DEBIAN_FRONTEND=noninteractive apt-get install -y postfix

    echo "[INFO] Configurando main.cf..."
    POSTFIX_CONF="/etc/postfix/main.cf"

    if ! grep -q "^mydomain =" "$POSTFIX_CONF"; then
        echo "mydomain = $HOSTNAME_REAL$DOMAIN_SUFFIX" >> "$POSTFIX_CONF"
    else
        sed -i "s/^mydomain =.*/mydomain = $HOSTNAME_REAL$DOMAIN_SUFFIX/" "$POSTFIX_CONF"
    fi

    if [ -n "$NETWORK_MASK" ]; then
        if grep -q "^mynetworks =" "$POSTFIX_CONF"; then
            if ! grep -q "$NETWORK_MASK" "$POSTFIX_CONF"; then
                 sed -i "\|^mynetworks =| s|$| $NETWORK_MASK|" "$POSTFIX_CONF"
            fi
        fi
    fi

    echo "[INFO] Reiniciando Postfix..."
    systemctl restart postfix
    echo "[OK] Postfix configurado."
}

instalar_mailutils() {
    echo "--- Instalando Mailutils ---"
    DEBIAN_FRONTEND=noninteractive apt-get install -y mailutils
    echo "[OK] Mailutils instalado."
}

crear_usuario() {
    echo "--- Crear Nuevo Usuario ---"
    read -p "Introduce el nombre del nuevo usuario: " username
    
    if id "$username" &>/dev/null; then
        echo "[AVISO] El usuario '$username' ya existe."
    else
        useradd -m -s /bin/bash "$username"
        if [ $? -eq 0 ]; then
            echo "[OK] Usuario '$username' creado."
            echo "Introduce la contraseña:"
            passwd "$username"
        else
            echo "[ERROR] Fallo al crear usuario."
        fi
    fi
    read -p "Presiona ENTER para continuar..."
}

listar_usuarios() {
    echo "--- Usuarios del Sistema (UID >= 1000) ---"
    awk -F: '$3 >= 1000 && $1 != "nobody" {print "Usuario: " $1 " (UID: " $3 ")"}' /etc/passwd
    read -p "Presiona ENTER para continuar..."
}

instalar_extras() {
    echo "--- Instalación de Componentes Adicionales ---"
    
    echo "[INFO] Instalando Dovecot..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y dovecot-core dovecot-imapd dovecot-pop3d
    
    echo "[INFO] Instalando Apache2..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y apache2
    
    echo "[INFO] Configurando Firewall..."
    if ! command -v ufw &> /dev/null; then
        apt-get install -y ufw
    fi
    ufw allow 143/tcp
    ufw allow 25/tcp
    ufw allow ssh 
    echo "[INFO] Reglas UFW aplicadas."
    
    DOVECOT_AUTH_CONF="/etc/dovecot/conf.d/10-auth.conf"
    if [ -f "$DOVECOT_AUTH_CONF" ]; then
        sed -i 's/^#disable_plaintext_auth =.*/disable_plaintext_auth = no/' "$DOVECOT_AUTH_CONF"
        sed -i 's/^disable_plaintext_auth =.*/disable_plaintext_auth = no/' "$DOVECOT_AUTH_CONF"
        
        if grep -q "^auth_mechanisms =" "$DOVECOT_AUTH_CONF"; then
             if ! grep -q "login" "$DOVECOT_AUTH_CONF"; then
                sed -i "/^auth_mechanisms =/ s/$/ login/" "$DOVECOT_AUTH_CONF"
             fi
        fi
        systemctl restart dovecot
        echo "[OK] Dovecot reconfigurado."
    fi
    
    read -p "Presiona ENTER para continuar..."
}

mostrar_menu() {
    clear
    echo "========================================="
    echo "   GESTIÓN DE SERVIDOR DE CORREO (v0.1)"
    echo "========================================="
    echo "1. Crear usuario nuevo"
    echo "2. Listar usuarios"
    echo "3. Instalar Extras (Dovecot, Apache, FW)"
    echo "4. Salir"
    echo "========================================="
}

iniciar_bucle_menu() {
    while true; do
        mostrar_menu
        read -p "Selecciona una opción: " opcion
        
        case $opcion in
            1) crear_usuario ;;
            2) listar_usuarios ;;
            3) instalar_extras ;;
            4) echo "Saliendo..."; exit 0 ;;
            *) echo "Opción no válida."; sleep 1 ;;
        esac
    done
}

main() {
    check_root
    obtener_datos_red
    
    echo "--- Ejecutando configuración base... ---"
    instalar_postfix
    instalar_mailutils
    
    iniciar_bucle_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
