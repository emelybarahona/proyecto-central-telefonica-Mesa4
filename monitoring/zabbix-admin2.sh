#!/usr/bin/env bash
# =============================================================================
# zabbix-admin2.sh  -  Mesa 4  -  Módulo 3.8
# Responsable:(PC18)  -  Rol: Monitoreo y Seguridad (Zabbix)
#
# Qué hace
#   Deja listo el monitoreo del mini centro de datos es idempotente: cada paso
#   revisa si ya está hecho y, si lo está, no toca nada. Se puede correr las
#   veces que haga falta (por ejemplo, después de mejorar el script).
#
# Uso (siempre con sudo)
#   ./zabbix-admin2.sh                    # SIN parámetros: abre un MENÚ y pregunta las IP (lo más fácil)
#   ./zabbix-admin2.sh hardening          # SSH por llave + fail2ban (cualquier nodo)
#   ./zabbix-admin2.sh firewall           # reglas iptables del servidor (política DROP)
#   ./zabbix-admin2.sh servidor           # INSTALA Zabbix server + MariaDB + web + agente
#   ./zabbix-admin2.sh agente [IP-DEL-SERVIDOR]   # Agente Zabbix (solo en los OTROS nodos, no en la VM del servidor)
#   ./zabbix-admin2.sh monitor servidor   # script de monitoreo + systemd timer
#   ./zabbix-admin2.sh monitor nodo       # igual, pero para un nodo normal
#   ./zabbix-admin2.sh diagnostico        # muestra por qué no arranca zabbix-server
#   ./zabbix-admin2.sh reparar            # BORRA y vuelve a crear la base de datos de Zabbix
#   ./zabbix-admin2.sh idioma             # instala los idiomas (es_ES, en_US) para la web de Zabbix
#   ./zabbix-admin2.sh respaldo           # respaldo diario de la base (rotación + verificación + envío)
#   ./zabbix-admin2.sh restaurar-prueba   # prueba de restauración del último respaldo
#   ./zabbix-admin2.sh red                # revisa la red: IP, puerta de enlace, internet y nodos
#   ./zabbix-admin2.sh sin-vpn            # quita WireGuard (ya no se usa) y sus llaves
#
# RED: ya no se usa VPN. La VM va en modo puente y todos los equipos están en la red real
# 192.168.14.0/24 (ver la guía del puente). Las IP están en el bloque "Parámetros" de abajo.
#
# PERMISOS: si al correr "./zabbix-admin2.sh" sale "Permission denied", dale permiso de
# ejecución una sola vez con:   chmod +x zabbix-admin.sh
# (o córrelo así sin cambiar permisos:   sudo bash zabbix-admin.sh servidor).
# Si lo bajas de GitHub el permiso se pierde; para que viaje con el repositorio:
#   git update-index --chmod=+x zabbix-admin.sh && git commit -m "script ejecutable"
#
# Orden recomendado en el servidor: hardening, servidor (ya incluye idioma), firewall, respaldo, monitor servidor.
# Orden recomendado en cada nodo:   hardening, agente, monitor nodo.
#Al usar /usr/bin/env bash, el sistema busca cuál es la versión de Bash activa o #disponible en las rutas del usuario en ese #momento, lo que hace que el script #funcione en una mayor variedad de computadoras y sistemas tipo Unix por esa razón 
# no utilizo #!/bin/bash
# =============================================================================

set -euo pipefail

#Párametros del proyecto
ZBX_VERSION="7.0"                   
ZBX_SERVER_IP="${ZBX_SERVER_IP:-192.168.14.51}"   # IP de la VM de Zabbix en el puente (red real)
GATEWAY_IP="192.168.14.252"                    # pasarela Zentyal (salida a internet)
NODOS="192.168.14.50 192.168.14.2"   # VM de la PC17 (Asterisk) y VM de la PC19 (respaldo)
DB_NOMBRE="zabbix"
DB_USUARIO="zabbix"
ARCHIVO_CLAVE_DB="/root/.zabbix-db-pass"   
# Redes desde donde se permite SSH y la web de Zabbix: la red real (puente) y la red libvirt por si la VM aún está en NAT.
REDES_ADMIN="192.168.14.0/24 192.168.122.0/24"
UMBRAL_DISCO=90                      
UMBRAL_MEMORIA=90                   
# Respaldos de la base de datos (esta VM envía al nodo de respaldo: la VM de la PC19)
DIR_RESPALDOS="/var/backups/zabbix"
RETENCION=7                          # cuántos respaldos se conservan en esta VM
DESTINO_RESPALDO="192.168.14.2"
USUARIO_DESTINO="zabbix"             # usuario en el nodo de respaldo (ajústalo si es otro)
RUTA_DESTINO="/var/backups/mesa4/zabbix"
LOG="/var/log/zabbix-admin2.log"
CAMBIOS=0

# Las IP que se escriben en el menú se guardan en este archivo y se leen en cada corrida.
# Si se borra, el script vuelve a usar los valores por defecto de arriba.
CONFIG="/etc/zabbix-admin2.conf"
if [[ -r "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
fi

# Funciones de ayuda
log()   { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
aviso() { echo "[$(date '+%F %T')] AVISO: $*" | tee -a "$LOG" >&2; }
falla() { echo "[$(date '+%F %T')] ERROR: $*" | tee -a "$LOG" >&2; exit 1; }

necesita_root() { [[ $EUID -eq 0 ]] || falla "Corre el script con sudo."; }

# Actualiza la lista de paquetes. Si falla (por ejemplo sin internet) avisa y sigue:
# la instalación siguiente dirá con claridad qué faltó.
actualizar_apt() {
    if ! apt-get update >>"$LOG" 2>&1; then
        aviso "apt update tuvo errores (¿la VM tiene internet?). Se intenta seguir. Detalle: tail -n 20 $LOG"
    fi
}

# Instala un paquete solo si todavía no está.
asegurar_paquete() {
    if dpkg -s "$1" >/dev/null 2>&1; then
        log "Paquete $1: ya instalado."
    else
        log "Paquete $1: instalando..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" >>"$LOG" 2>&1; then
            falla "No se pudo instalar $1. Casi siempre es falta de internet o que otro programa está usando apt. Detalle: tail -n 20 $LOG"
        fi
        CAMBIOS=1
    fi
}

# Escribe un archivo con lo que llega por stdin, pero solo si es distinto del
# que ya existe. Si cambia, guarda una copia .bak con fecha.
# Deja ARCHIVO_CAMBIO en 1 (cambió) o 0 (sin cambios).
escribir_si_cambia() {
    local destino="$1" modo="${2:-644}" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if [[ -f "$destino" ]] && cmp -s "$tmp" "$destino"; then
        log "Archivo $destino: sin cambios."
        ARCHIVO_CAMBIO=0
    else
        [[ -f "$destino" ]] && cp -a "$destino" "${destino}.bak.$(date +%Y%m%d%H%M%S)"
        install -m "$modo" "$tmp" "$destino"
        log "Archivo $destino: actualizado."
        ARCHIVO_CAMBIO=1
        CAMBIOS=1
    fi
    rm -f "$tmp"
}
#.$(date +%Y%m%d%H%M%S) esto significa que es el formato en el que se imprimirá la fecha %Y =Año de 4 dígitos, %m = Mes,l % Día, %H = Hora, %M minutos, %s segundos 


# Deja "Clave=valor" en un archivo de configuración de Zabbix: si la línea
# activa existe la reemplaza, si no existe la agrega al final.
fijar_param() {
    local archivo="$1" clave="$2" valor="$3"
    if grep -qE "^${clave}=${valor}$" "$archivo"; then
        log "$(basename "$archivo"): ${clave} ya estaba bien."
        PARAM_CAMBIO=0
        return 0
    fi
    cp -a "$archivo" "${archivo}.bak.$(date +%Y%m%d%H%M%S)"
    if grep -qE "^${clave}=" "$archivo"; then
        sed -i -E "s|^${clave}=.*|${clave}=${valor}|" "$archivo"
    else
        echo "${clave}=${valor}" >> "$archivo"
    fi
    log "$(basename "$archivo"): ${clave} actualizado."
    PARAM_CAMBIO=1
    CAMBIOS=1
}

# Repositorio de Zabbix
asegurar_repo_zabbix() {
    if dpkg -s zabbix-release >/dev/null 2>&1; then
        log "Repositorio de Zabbix: ya agregado."
        return 0
    fi
    log "Agregando repositorio oficial de Zabbix ${ZBX_VERSION}..."
    local base="https://repo.zabbix.com/zabbix/${ZBX_VERSION}/ubuntu/pool/main/z/zabbix-release"
    local deb="/tmp/zabbix-release.deb"
    # El nombre del paquete cambió entre versiones; se prueba uno y luego el otro.
    # Si ambos fallan, copia la URL exacta desde https://www.zabbix.com/download
    if ! wget -q -O "$deb" "${base}/zabbix-release_latest_${ZBX_VERSION}+ubuntu24.04_all.deb"; then
        wget -q -O "$deb" "${base}/zabbix-release_latest+ubuntu24.04_all.deb" \
            || falla "No se pudo bajar zabbix-release. Revisa internet o la URL en zabbix.com/download"
    fi
    dpkg -i "$deb" >>"$LOG" 2>&1 || falla "No se pudo agregar el repositorio de Zabbix. Detalle: tail -n 20 $LOG"
    actualizar_apt
    CAMBIOS=1
}

# HARDENING
fase_hardening() {
    log "== Hardening: SSH por llave y fail2ban =="
    local usuario="${SUDO_USER:-}"
    [[ -n "$usuario" && "$usuario" != "root" ]] || falla "Entra con tu usuario normal y usa sudo (no como root)."
    local home; home="$(getent passwd "$usuario" | cut -d: -f6)"

    # Freno de seguridad: si todavía no hay llave pública copiada, deshabilitar
    # la contraseña dejaría la VM inaccesible. Mejor parar aquí.
    if [[ ! -s "${home}/.ssh/authorized_keys" ]]; then
        falla "No hay llaves en ${home}/.ssh/authorized_keys (usuario ${usuario}). Primero, desde tu PC (fuera de la VM), corre: ssh-copy-id ${usuario}@IP-DE-LA-VM  (la IP se ve aquí con: ip -br a). Después vuelve a correr este modo."
    fi

    asegurar_paquete openssh-server
    asegurar_paquete fail2ban

    # Se usa el prefijo 00 porque en Ubuntu 24.04 gana la PRIMERA línea que
    # sshd lee, y archivos como 50-cloud-init.conf podrían reactivar la contraseña.
    escribir_si_cambia /etc/ssh/sshd_config.d/00-hardening.conf 644 <<'EOF'
# Generado por zabbix-admin.sh
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
PermitUserEnvironment no
EOF
    if [[ $ARCHIVO_CAMBIO -eq 1 ]]; then
        # sshd -t revisa la sintaxis. Si falla, se quita el archivo y no se recarga.
        if sshd -t; then
            systemctl reload ssh
            log "SSH recargado con la configuración nueva."
        else
            rm -f /etc/ssh/sshd_config.d/00-hardening.conf
            falla "La configuración de SSH tenía errores; se revirtió."
        fi
    fi

    # En vez de editar jail.conf (que se pisa al actualizar) se usa un archivo propio.
    escribir_si_cambia /etc/fail2ban/jail.d/proyecto.local 644 <<'EOF'
# Generado por zabbix-admin.sh
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
backend = systemd
port    = ssh
EOF
    systemctl enable fail2ban >>"$LOG" 2>&1
    if [[ $ARCHIVO_CAMBIO -eq 1 ]] || ! systemctl is-active --quiet fail2ban; then
        systemctl restart fail2ban
        log "fail2ban reiniciado."
    fi
    log "Recuerda: ARPon se instala aparte (ver manual)."
}

# Firewall (iptables)
# Agrega una regla de iptables solo si no existe (-C comprueba, -A agrega).
# Si se usara -A directo, cada corrida duplicaría la regla.
regla_iptables() {
    if iptables "${@/#-A/-C}" 2>/dev/null; then
        log "iptables: ya existe ($*)"
    else
        iptables "$@"
        log "iptables: agregada ($*)"
        CAMBIOS=1
    fi
}

# Borra una regla de INPUT solo si existe (sirve para limpiar reglas de la VPN vieja).
borrar_regla_si_existe() {
    if iptables -C INPUT "$@" 2>/dev/null; then
        iptables -D INPUT "$@"
        log "iptables: regla vieja eliminada ($*)"
        CAMBIOS=1
    fi
}

fase_firewall() {
    log "== Firewall del servidor Zabbix (iptables) =="
    # IMPORTANTE: deja abierta otra sesión SSH mientras corres esto. Primero se
    # agregan las reglas que permiten el acceso y solo al final se pone la
    # política DROP, para no cortarte la conexión.
    # Si ufw está activo, las reglas se aplican con ufw: mezclar los dos firewalls
    # deja reglas que se pisan entre sí y es difícil saber cuál bloquea.
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
        log "ufw está activo: las reglas se aplican con ufw para no mezclar dos firewalls."
        local red_ufw puerto_ufw
        for red_ufw in $REDES_ADMIN; do
            for puerto_ufw in 22 80 10051; do
                ufw allow from "$red_ufw" to any port "$puerto_ufw" proto tcp >>"$LOG" 2>&1
            done
        done
        ufw default deny incoming >>"$LOG" 2>&1
        log "Reglas de ufw aplicadas. Ver con: sudo ufw status verbose"
        return 0
    fi
    asegurar_paquete iptables
    asegurar_paquete iptables-persistent

    regla_iptables -A INPUT -i lo -j ACCEPT
    regla_iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    regla_iptables -A INPUT -p icmp -j ACCEPT

    # SSH, web de Zabbix y puerto 10051 (agentes activos) solo desde las redes permitidas.
    for red in $REDES_ADMIN; do
        regla_iptables -A INPUT -s "$red" -p tcp --dport 22 -j ACCEPT
        regla_iptables -A INPUT -s "$red" -p tcp --dport 80 -j ACCEPT
        regla_iptables -A INPUT -s "$red" -p tcp --dport 10051 -j ACCEPT
    done

    # Limpieza: reglas que dejó la VPN (WireGuard por 51820 o 443) y las redes 192.168.50.x y Wi-Fi.
    borrar_regla_si_existe -p udp --dport 443 -j ACCEPT
    borrar_regla_si_existe -p udp --dport 51820 -j ACCEPT
    local red_vieja puerto
    for red_vieja in 192.168.50.0/24 192.168.13.0/24; do
        for puerto in 22 80 10051; do
            borrar_regla_si_existe -s "$red_vieja" -p tcp --dport "$puerto" -j ACCEPT
        done
    done

    # Todo lo demás que entra se descarta.
    if [[ "$(iptables -S INPUT | head -1)" != "-P INPUT DROP" ]]; then
        iptables -P INPUT DROP
        log "iptables: política de INPUT cambiada a DROP"
        CAMBIOS=1
    else
        log "iptables: la política de INPUT ya era DROP."
    fi
    netfilter-persistent save >>"$LOG" 2>&1
    log "Reglas guardadas. Ver con: sudo iptables -S"
}

# Diagnóstico: reúne lo que hace falta para saber por qué no arranca zabbix-server.
diagnostico() {
    echo "--- Servicios:"
    local sv
    for sv in mariadb zabbix-server zabbix-agent2 apache2; do
        printf '  %-16s %s\n' "$sv" "$(systemctl is-active "$sv" 2>/dev/null || true)"
    done
    echo "--- Últimas líneas del registro de zabbix-server (la causa casi siempre sale aquí):"
    tail -n 15 /var/log/zabbix/zabbix_server.log 2>/dev/null || echo "  (todavía no hay registro)"
    echo "--- journalctl:"
    journalctl -u zabbix-server -n 10 --no-pager 2>/dev/null || true
    echo "--- Conexión a la base con el usuario de Zabbix:"
    if [[ -s "$ARCHIVO_CLAVE_DB" ]] && MYSQL_PWD="$(cat "$ARCHIVO_CLAVE_DB")" \
        mariadb -h127.0.0.1 -u"$DB_USUARIO" "$DB_NOMBRE" \
        -e "SELECT COUNT(*) AS tablas FROM information_schema.tables WHERE table_schema='${DB_NOMBRE}';" 2>/dev/null; then
        :
    else
        echo "  no se pudo conectar como ${DB_USUARIO}"
    fi
    echo "--- Parámetros de conexión en zabbix_server.conf (sin la clave):"
    grep -E '^(DBHost|DBName|DBUser|DBPort|DBSocket)=' /etc/zabbix/zabbix_server.conf || true
}

# Reparar: borra la base y la vuelve a crear. Solo para cuando el esquema quedó a medias.
reparar() {
    aviso "Esto BORRA la base de datos '${DB_NOMBRE}' y la crea de nuevo desde cero."
    read -r -p "Escribe SI para continuar: " respuesta
    [[ "$respuesta" == "SI" ]] || falla "Cancelado."
    systemctl stop zabbix-server >>"$LOG" 2>&1 || true
    mariadb -e "DROP DATABASE IF EXISTS ${DB_NOMBRE};"
    CAMBIOS=1
    fase_servidor
}

# Servidor de Zabbix
fase_servidor() {
    log "== Servidor Zabbix + MariaDB =="
    # La IP que usarán los agentes tiene que ser la de ESTA VM. Si todavía no tiene el puente, avisa.
    if ! hostname -I | tr ' ' '\n' | grep -qx "$ZBX_SERVER_IP"; then
        aviso "Esta VM no tiene la IP ${ZBX_SERVER_IP} (tiene: $(hostname -I)). Si ya hiciste el puente, revisa el netplan; si no, puedes seguir."
    fi
    actualizar_apt
    asegurar_paquete wget
    asegurar_paquete mariadb-server
    asegurar_repo_zabbix
    asegurar_paquete zabbix-server-mysql
    asegurar_paquete zabbix-frontend-php
    asegurar_paquete zabbix-apache-conf
    asegurar_paquete zabbix-sql-scripts
    asegurar_paquete zabbix-agent2
    asegurar_idiomas

    # La clave de la base se genera una sola vez y se guarda con permiso 600.
    if [[ ! -s "$ARCHIVO_CLAVE_DB" ]]; then
        openssl rand -hex 16 > "$ARCHIVO_CLAVE_DB"
        chmod 600 "$ARCHIVO_CLAVE_DB"
        log "Clave de la base generada en $ARCHIVO_CLAVE_DB"
        CAMBIOS=1
    fi
    local clave; clave="$(cat "$ARCHIVO_CLAVE_DB")"

    # MariaDB tiene que estar corriendo antes de crear la base.
    systemctl enable --now mariadb >>"$LOG" 2>&1

    # Los IF NOT EXISTS hacen que repetir esto no dé error ni duplique nada.
    mariadb -e "CREATE DATABASE IF NOT EXISTS ${DB_NOMBRE} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
    # El usuario se crea para 'localhost' y para '127.0.0.1': el servidor se
    # conecta por TCP a 127.0.0.1 y MariaDB los trata como orígenes distintos.
    local origen
    for origen in localhost 127.0.0.1; do
        mariadb -e "CREATE USER IF NOT EXISTS '${DB_USUARIO}'@'${origen}' IDENTIFIED BY '${clave}';"
        mariadb -e "ALTER USER '${DB_USUARIO}'@'${origen}' IDENTIFIED BY '${clave}';"
        mariadb -e "GRANT ALL PRIVILEGES ON ${DB_NOMBRE}.* TO '${DB_USUARIO}'@'${origen}';"
    done
    mariadb -e "FLUSH PRIVILEGES;"

    # Se comprueba que el usuario de Zabbix de verdad puede entrar a la base.
    if ! MYSQL_PWD="$clave" mariadb -h127.0.0.1 -u"$DB_USUARIO" "$DB_NOMBRE" -e "SELECT 1;" >/dev/null 2>&1; then
        falla "El usuario ${DB_USUARIO} no puede entrar a la base por 127.0.0.1. Revisa: systemctl status mariadb"
    fi

    # Estado del esquema: sin tablas se importa; con tablas pero sin 'dbversion'
    # llena, una importación anterior quedó a medias y hay que correr 'reparar'.
    local tablas dbver
    tablas="$(mariadb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NOMBRE}';")"
    dbver="$(mariadb -N -e "SELECT COUNT(*) FROM ${DB_NOMBRE}.dbversion;" 2>/dev/null || echo 0)"
    if [[ "$tablas" -eq 0 ]]; then
        log "Importando el esquema de Zabbix (tarda un par de minutos)..."
        mariadb -e "SET GLOBAL log_bin_trust_function_creators = 1;"
        if ! zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz \
            | MYSQL_PWD="$clave" mariadb --default-character-set=utf8mb4 -u"$DB_USUARIO" "$DB_NOMBRE"; then
            mariadb -e "SET GLOBAL log_bin_trust_function_creators = 0;"
            falla "La importación del esquema falló. Corre: sudo ./zabbix-admin.sh reparar"
        fi
        mariadb -e "SET GLOBAL log_bin_trust_function_creators = 0;"
        CAMBIOS=1
    elif [[ "$dbver" -eq 0 ]]; then
        falla "El esquema de la base está incompleto (importación interrumpida). Corre: sudo ./zabbix-admin.sh reparar"
    else
        log "Esquema de Zabbix: ya importado."
    fi

    local conf="/etc/zabbix/zabbix_server.conf" reiniciar=0
    # DBHost=127.0.0.1 fuerza la conexión por TCP y evita problemas con la ruta del socket.
    fijar_param "$conf" DBHost 127.0.0.1;           reiniciar=$((reiniciar + PARAM_CAMBIO))
    fijar_param "$conf" DBName "$DB_NOMBRE";        reiniciar=$((reiniciar + PARAM_CAMBIO))
    fijar_param "$conf" DBUser "$DB_USUARIO";       reiniciar=$((reiniciar + PARAM_CAMBIO))
    fijar_param "$conf" DBPassword "$clave";        reiniciar=$((reiniciar + PARAM_CAMBIO))

    # El agente del propio servidor reporta a 127.0.0.1.
    local agconf="/etc/zabbix/zabbix_agent2.conf"
    fijar_param "$agconf" Server "127.0.0.1,${ZBX_SERVER_IP}"; reiniciar=$((reiniciar + PARAM_CAMBIO))
    fijar_param "$agconf" ServerActive "127.0.0.1";            reiniciar=$((reiniciar + PARAM_CAMBIO))
    fijar_param "$agconf" Hostname "$(hostname)";              reiniciar=$((reiniciar + PARAM_CAMBIO))

    systemctl enable zabbix-server zabbix-agent2 apache2 >>"$LOG" 2>&1
    # Al instalar, apt intenta arrancar zabbix-server antes de que la base esté
    # lista y lo deja marcado como "failed". Se limpia esa marca antes de arrancar.
    systemctl reset-failed zabbix-server >>"$LOG" 2>&1 || true

    if [[ $reiniciar -gt 0 ]] || ! systemctl is-active --quiet zabbix-server; then
        if ! systemctl restart zabbix-server; then
            diagnostico
            falla "zabbix-server no arrancó. La causa suele estar en el diagnóstico de arriba."
        fi
        sleep 3   # zabbix-server es un servicio "forking": si hay error se cae a los segundos
        if ! systemctl is-active --quiet zabbix-server; then
            diagnostico
            falla "zabbix-server arrancó pero se cayó enseguida. Revisa el diagnóstico de arriba."
        fi
        log "zabbix-server activo."
    fi
    if [[ $reiniciar -gt 0 ]]; then
        systemctl restart zabbix-agent2 apache2
        log "zabbix-agent2 y apache2 reiniciados."
    else
        systemctl start zabbix-agent2 apache2
    fi

    log "Listo. Termina la configuración en el navegador: http://${ZBX_SERVER_IP}/zabbix"
    log "La clave de la base está en $ARCHIVO_CLAVE_DB (el asistente web la pide)."
    log "Usuario web inicial: Admin / zabbix. Cámbiala al entrar."
    log "IMPORTANTE: en la web, el host 'Zabbix server' debe llamarse '$(hostname)' (igual que el"
    log "Hostname del agente). Si no, sale 'Zabbix agent is not available'. Ver Data collection > Hosts."
}

# Agente en los demás nodos
fase_agente() {
    log "== Agente Zabbix =="
    actualizar_apt
    asegurar_paquete wget
    asegurar_repo_zabbix
    asegurar_paquete zabbix-agent2

    local conf="/etc/zabbix/zabbix_agent2.conf" reiniciar=0
    fijar_param "$conf" Server "$ZBX_SERVER_IP";       reiniciar=$((reiniciar + PARAM_CAMBIO))
    fijar_param "$conf" ServerActive "$ZBX_SERVER_IP"; reiniciar=$((reiniciar + PARAM_CAMBIO))
    # Este nombre debe ser IGUAL al que pongas al crear el host en la web de Zabbix.
    fijar_param "$conf" Hostname "$(hostname)";        reiniciar=$((reiniciar + PARAM_CAMBIO))

    systemctl enable zabbix-agent2 >>"$LOG" 2>&1
    if [[ $reiniciar -gt 0 ]] || ! systemctl is-active --quiet zabbix-agent2; then
        systemctl restart zabbix-agent2
        log "zabbix-agent2 reiniciado."
    fi

    # Si usan ufw se abre el puerto 10050 solo para el servidor. Si usan iptables
    # a mano, agreguen esa regla en su script de firewall.
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow from "$ZBX_SERVER_IP" to any port 10050 proto tcp >>"$LOG" 2>&1
        log "ufw: puerto 10050 permitido desde $ZBX_SERVER_IP"
    else
        aviso "ufw no está activo: asegúrate de permitir TCP 10050 desde $ZBX_SERVER_IP en tu firewall."
    fi
    log "Nombre de host para crear en la web de Zabbix: $(hostname)"
}

# Acript de monitoreo + System Timers
fase_monitor() {
    local rol="${1:-servidor}"
    log "== Script de monitoreo ($rol) con systemd timer =="
    asegurar_paquete iputils-ping

    local servicios revisar_agentes nodos
    if [[ "$rol" == "servidor" ]]; then
        servicios="ssh fail2ban mariadb apache2 zabbix-server zabbix-agent2"
        revisar_agentes="si"; nodos="$NODOS"
    else
        servicios="ssh fail2ban zabbix-agent2"
        revisar_agentes="no"; nodos="$ZBX_SERVER_IP"
    fi

    escribir_si_cambia /etc/default/zbx-healthcheck 644 <<EOF
# Generado por zabbix-admin.sh
SERVICIOS="${servicios}"
NODOS="${nodos}"
REVISAR_AGENTES="${revisar_agentes}"
UMBRAL_DISCO=${UMBRAL_DISCO}
UMBRAL_MEMORIA=${UMBRAL_MEMORIA}
ARCHIVO_LOG=/var/log/zbx-healthcheck.log
EOF

    # Este es el script que corre cada 5 minutos. Escribe en el journal (logger)
    # y en su propio archivo. Si encuentra problemas termina con código 1, así
    # systemd marca la ejecución como fallida y se ve con 'systemctl status'.
    escribir_si_cambia /usr/local/bin/zbx-healthcheck.sh 755 <<'EOF'
#!/usr/bin/env bash
# zbx-healthcheck.sh - revisa disco, memoria, servicios y conectividad.
set -uo pipefail
source /etc/default/zbx-healthcheck
TAG="zbx-healthcheck"
PROBLEMAS=0

ok()     { echo "$(date '+%F %T') OK     $*" >> "$ARCHIVO_LOG"; }
alerta() {
    logger -t "$TAG" -p user.err "$*"
    echo "$(date '+%F %T') ALERTA $*" >> "$ARCHIVO_LOG"
    PROBLEMAS=$((PROBLEMAS + 1))
}

# 1) Disco de la raíz
uso_disco=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if (( uso_disco >= UMBRAL_DISCO )); then alerta "Disco al ${uso_disco}%"; else ok "Disco al ${uso_disco}%"; fi

# 2) Memoria usada
uso_mem=$(free | awk '/^Mem:/ {printf "%d", $3 * 100 / $2}')
if (( uso_mem >= UMBRAL_MEMORIA )); then alerta "Memoria al ${uso_mem}%"; else ok "Memoria al ${uso_mem}%"; fi

# 3) Servicios críticos
for svc in $SERVICIOS; do
    if systemctl is-active --quiet "$svc"; then ok "Servicio $svc activo"; else alerta "Servicio $svc inactivo"; fi
done

# 4) Otros nodos: ping y, en el servidor, puerto del agente (10050)
for ip in $NODOS; do
    if ping -c1 -W2 "$ip" >/dev/null 2>&1; then
        ok "Ping a $ip"
        if [[ "$REVISAR_AGENTES" == "si" ]]; then
            if timeout 3 bash -c "exec 3<>/dev/tcp/$ip/10050" 2>/dev/null; then
                ok "Agente Zabbix responde en $ip:10050"
            else
                alerta "Agente Zabbix no responde en $ip:10050"
            fi
        fi
    else
        alerta "Sin respuesta de $ip"
    fi
done

exit $(( PROBLEMAS > 0 ? 1 : 0 ))
EOF

    escribir_si_cambia /etc/logrotate.d/zbx-healthcheck 644 <<'EOF'
/var/log/zbx-healthcheck.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF

    escribir_si_cambia /etc/systemd/system/zbx-healthcheck.service 644 <<'EOF'
[Unit]
Description=Revisión de salud del nodo (disco, memoria, servicios, red)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zbx-healthcheck.sh
EOF
    local cambio_svc=$ARCHIVO_CAMBIO

    escribir_si_cambia /etc/systemd/system/zbx-healthcheck.timer 644 <<'EOF'
[Unit]
Description=Ejecuta zbx-healthcheck cada 5 minutos

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

    if [[ $cambio_svc -eq 1 || $ARCHIVO_CAMBIO -eq 1 ]]; then
        systemctl daemon-reload
    fi
    systemctl enable --now zbx-healthcheck.timer >>"$LOG" 2>&1
    log "Timer activo. Ver: systemctl list-timers zbx-healthcheck.timer"
    log "Ver resultados: tail /var/log/zbx-healthcheck.log  o  journalctl -t zbx-healthcheck"
}

# Idiomas: la web de Zabbix solo ofrece un idioma si el sistema tiene ese "locale"
# generado. Sin esto, elegir español en la web falla o la web no funciona bien.
asegurar_idiomas() {
    log "== Idiomas para la web de Zabbix =="
    asegurar_paquete locales
    local cambio=0 idioma
    for idioma in es_ES.UTF-8 en_US.UTF-8; do
        if locale -a | grep -qix "${idioma/UTF-8/utf8}"; then
            log "Idioma $idioma: ya generado."
        else
            locale-gen "$idioma" >>"$LOG" 2>&1
            log "Idioma $idioma: generado."
            cambio=1
            CAMBIOS=1
        fi
    done
    # Apache tiene que reiniciarse para que PHP vea los idiomas nuevos.
    if [[ $cambio -eq 1 ]] && systemctl is-active --quiet apache2; then
        systemctl restart apache2
        log "apache2 reiniciado para cargar los idiomas."
    fi
}

# Respaldo: instala el script que vuelca la base, la comprime, verifica, rota y
# envía al nodo de respaldo; y lo programa cada día con un systemd timer.
fase_respaldo() {
    log "== Respaldo automático de la base de datos =="
    asegurar_paquete rsync
    mkdir -p "$DIR_RESPALDOS" && chmod 700 "$DIR_RESPALDOS"

    escribir_si_cambia /etc/default/zbx-backup 644 <<EOF
# Generado por zabbix-admin.sh
DIR_RESPALDOS=${DIR_RESPALDOS}
RETENCION=${RETENCION}
DB_NOMBRE=${DB_NOMBRE}
DB_USUARIO=${DB_USUARIO}
ARCHIVO_CLAVE_DB=${ARCHIVO_CLAVE_DB}
DESTINO=${DESTINO_RESPALDO}
USUARIO_DESTINO=${USUARIO_DESTINO}
RUTA_DESTINO=${RUTA_DESTINO}
ARCHIVO_LOG=/var/log/zbx-backup.log
EOF

    escribir_si_cambia /usr/local/bin/zbx-backup.sh 755 <<'EOF'
#!/usr/bin/env bash
# zbx-backup.sh - respaldo de la base de Zabbix: extraer, comprimir, verificar, rotar, enviar.
set -euo pipefail
source /etc/default/zbx-backup
umask 077
TAG="zbx-backup"
fecha="$(date +%Y%m%d-%H%M%S)"
archivo="${DIR_RESPALDOS}/zabbix-${fecha}.sql.gz"
trap 'rm -f "${archivo}.tmp"' EXIT

log() { logger -t "$TAG" "$*"; echo "$(date '+%F %T') $*" >> "$ARCHIVO_LOG"; }

mkdir -p "$DIR_RESPALDOS"
DUMP="$(command -v mariadb-dump || command -v mysqldump)"

# 1) Extraer y comprimir (la clave va en una variable de entorno, no en la línea de comandos)
MYSQL_PWD="$(cat "$ARCHIVO_CLAVE_DB")" "$DUMP" -h127.0.0.1 -u"$DB_USUARIO" \
    --single-transaction --routines --triggers "$DB_NOMBRE" | gzip > "${archivo}.tmp"
mv "${archivo}.tmp" "$archivo"

# 2) Verificar integridad del comprimido y guardar su suma de control
if gzip -t "$archivo"; then
    sha256sum "$archivo" > "${archivo}.sha256"
    log "Respaldo creado y verificado: $archivo ($(du -h "$archivo" | cut -f1))"
else
    rm -f "$archivo"
    log "ERROR: el respaldo salió dañado y se descartó"
    exit 1
fi

# 3) Rotación: se conservan solo los últimos RETENCION respaldos
ls -1t "$DIR_RESPALDOS"/zabbix-*.sql.gz 2>/dev/null | tail -n +$((RETENCION + 1)) | while read -r viejo; do
    rm -f "$viejo" "${viejo}.sha256"
    log "Rotación: eliminado $viejo"
done

# 4) Envío al nodo de respaldo (si no hay conexión queda la copia local y se avisa)
if ping -c1 -W2 "$DESTINO" >/dev/null 2>&1; then
    if rsync -a -e "ssh -o BatchMode=yes -o ConnectTimeout=10" \
        "$archivo" "${archivo}.sha256" "${USUARIO_DESTINO}@${DESTINO}:${RUTA_DESTINO}/"; then
        log "Respaldo enviado a ${DESTINO}:${RUTA_DESTINO}"
    else
        log "AVISO: no se pudo enviar a ${DESTINO} (revisa la llave SSH y la carpeta destino)"
        exit 2
    fi
else
    log "AVISO: ${DESTINO} no responde; el respaldo queda solo en esta VM"
    exit 2
fi
EOF

    escribir_si_cambia /etc/logrotate.d/zbx-backup 644 <<'EOF'
/var/log/zbx-backup.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF

    escribir_si_cambia /etc/systemd/system/zbx-backup.service 644 <<'EOF'
[Unit]
Description=Respaldo de la base de datos de Zabbix

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zbx-backup.sh
EOF
    local cambio_svc=$ARCHIVO_CAMBIO

    escribir_si_cambia /etc/systemd/system/zbx-backup.timer 644 <<'EOF'
[Unit]
Description=Respaldo diario de Zabbix (02:00)

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    if [[ $cambio_svc -eq 1 || $ARCHIVO_CAMBIO -eq 1 ]]; then
        systemctl daemon-reload
    fi
    systemctl enable --now zbx-backup.timer >>"$LOG" 2>&1
    log "Timer activo. Probar ya: sudo systemctl start zbx-backup.service  y luego  tail /var/log/zbx-backup.log"
    log "Para enviar al nodo de respaldo hace falta copiar la llave de root: sudo ssh-copy-id ${USUARIO_DESTINO}@${DESTINO_RESPALDO}"
}

# Prueba de restauración: carga el último respaldo en una base temporal, cuenta
# las tablas y la borra. Así queda demostrado que el respaldo sirve de verdad.
restaurar_prueba() {
    local ultimo tablas
    ultimo="$(ls -1t "$DIR_RESPALDOS"/zabbix-*.sql.gz 2>/dev/null | head -1 || true)"
    [[ -n "$ultimo" ]] || falla "No hay respaldos en $DIR_RESPALDOS. Crea uno con: sudo systemctl start zbx-backup.service"
    (cd "$DIR_RESPALDOS" && sha256sum -c "$(basename "$ultimo").sha256") \
        || falla "La suma de control no coincide: el respaldo está dañado."
    mariadb -e "DROP DATABASE IF EXISTS zabbix_restore_test; CREATE DATABASE zabbix_restore_test CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
    if ! zcat "$ultimo" | mariadb --default-character-set=utf8mb4 zabbix_restore_test; then
        mariadb -e "DROP DATABASE IF EXISTS zabbix_restore_test;"
        falla "La restauración de prueba falló."
    fi
    tablas="$(mariadb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='zabbix_restore_test';")"
    mariadb -e "DROP DATABASE zabbix_restore_test;"
    log "Prueba de restauración correcta con $(basename "$ultimo"): ${tablas} tablas recuperadas."
}

# Revisa la red paso a paso: ayuda a saber si el problema es la IP, la pasarela, internet o un nodo.
revisar_red() {
    echo "--- Direcciones IP de esta máquina:"
    ip -4 -br addr show | grep -v '^lo' || true
    echo "--- Ruta por defecto (debe salir por ${GATEWAY_IP}):"
    ip route show default || true
    echo "--- Pruebas (ping):"
    local entrada destino nombre n
    local lista=("${GATEWAY_IP}|pasarela Zentyal" "8.8.8.8|internet")
    for n in $NODOS; do lista+=("${n}|nodo"); done
    for entrada in "${lista[@]}"; do
        destino="${entrada%%|*}"; nombre="${entrada#*|}"
        if ping -c1 -W2 "$destino" >/dev/null 2>&1; then
            printf '  %-16s %-16s responde\n' "$destino" "($nombre)"
        else
            printf '  %-16s %-16s NO responde\n' "$destino" "($nombre)"
        fi
    done
    echo "--- Puerto 10050 (agente) de cada nodo:"
    for destino in $NODOS; do
        if timeout 3 bash -c "exec 3<>/dev/tcp/${destino}/10050" 2>/dev/null; then
            printf '  %-16s agente responde\n' "$destino"
        else
            printf '  %-16s agente NO responde (¿instalado? ¿firewall?)\n' "$destino"
        fi
    done
}

# Quita WireGuard: el equipo decidió no usar VPN, así que se apaga, se desinstala y se borran sus llaves.
quitar_vpn() {
    log "== Quitar WireGuard (ya no se usa) =="
    if systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null || systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        systemctl disable --now wg-quick@wg0 >>"$LOG" 2>&1 || true
        log "Servicio wg-quick@wg0 detenido y deshabilitado."
        CAMBIOS=1
    else
        log "wg-quick@wg0: ya estaba apagado."
    fi
    if ip link show wg0 >/dev/null 2>&1; then
        ip link delete wg0 >>"$LOG" 2>&1 || true
        log "Interfaz wg0 eliminada."
        CAMBIOS=1
    fi
    if dpkg -s wireguard >/dev/null 2>&1 || dpkg -s wireguard-tools >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y wireguard wireguard-tools >>"$LOG" 2>&1 || true
        log "WireGuard desinstalado."
        CAMBIOS=1
    else
        log "WireGuard: ya estaba desinstalado."
    fi
    if [[ -d /etc/wireguard ]]; then
        rm -rf /etc/wireguard
        log "Carpeta /etc/wireguard (con las llaves) eliminada."
        CAMBIOS=1
    fi
    log "Para limpiar también las reglas de firewall de la VPN: sudo ./zabbix-admin.sh firewall"
}

estado() {
    echo "--- Servicios:"
    local s estado_servicio
    for s in ssh fail2ban mariadb apache2 zabbix-server zabbix-agent2 zbx-healthcheck.timer zbx-backup.timer; do
        estado_servicio="$(systemctl is-active "$s" 2>/dev/null || true)"
        printf '  %-24s %s\n' "$s" "${estado_servicio:-desconocido}"
    done
    echo "--- Puertos escuchando (10050 agente, 10051 servidor, 80 web):"
    ss -tln | grep -E ':(10050|10051|80)\b' || echo "  ninguno"
    echo "--- Últimas líneas del monitoreo:"
    tail -n 8 /var/log/zbx-healthcheck.log 2>/dev/null || echo "  todavía no hay registros"
}

# ---------------------------------------------------------------------------
# MENÚ INTERACTIVO: se abre al correr el script sin parámetros. Pregunta las IP,
# las valida (que tengan formato de IP) y las guarda en /etc/zabbix-admin.conf.
# ---------------------------------------------------------------------------

# Comprueba que un texto sea una IP válida, por ejemplo 192.168.14.51
es_ip() {
    local ip="$1" octeto
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octeto in "${BASH_REMATCH[@]:1}"; do
        (( 10#$octeto <= 255 )) || return 1
    done
    return 0
}

# Comprueba una red con máscara, por ejemplo 192.168.14.0/24
es_red() {
    local red="$1" ip mascara
    [[ "$red" =~ ^([0-9.]+)/([0-9]{1,2})$ ]] || return 1
    ip="${BASH_REMATCH[1]}"; mascara="${BASH_REMATCH[2]}"
    es_ip "$ip" && (( 10#$mascara <= 32 ))
}

# preguntar_ip "Texto" NOMBRE_DE_LA_VARIABLE
# Muestra el valor actual entre corchetes; si solo se presiona Enter, se deja ese valor.
preguntar_ip() {
    local texto="$1" var="$2" actual respuesta
    actual="${!var}"
    while true; do
        read -r -p "$texto [$actual]: " respuesta || exit 1
        respuesta="${respuesta:-$actual}"
        if es_ip "$respuesta"; then
            printf -v "$var" '%s' "$respuesta"
            return 0
        fi
        echo "  Eso no parece una IP válida (ejemplo: 192.168.14.51). Intenta otra vez."
    done
}

# Igual, pero para varias IP separadas por espacio.
preguntar_lista_ips() {
    local texto="$1" var="$2" actual respuesta ip valido
    actual="${!var}"
    while true; do
        read -r -p "$texto [$actual]: " respuesta || exit 1
        respuesta="${respuesta:-$actual}"
        valido=1
        for ip in $respuesta; do es_ip "$ip" || valido=0; done
        if [[ $valido -eq 1 && -n "$respuesta" ]]; then
            printf -v "$var" '%s' "$respuesta"
            return 0
        fi
        echo "  Escribe una o más IP válidas separadas por espacio (ejemplo: 192.168.14.50 192.168.14.2)."
    done
}

# Igual, pero para redes con máscara (192.168.14.0/24).
preguntar_redes() {
    local texto="$1" var="$2" actual respuesta red valido
    actual="${!var}"
    while true; do
        read -r -p "$texto [$actual]: " respuesta || exit 1
        respuesta="${respuesta:-$actual}"
        valido=1
        for red in $respuesta; do es_red "$red" || valido=0; done
        if [[ $valido -eq 1 && -n "$respuesta" ]]; then
            printf -v "$var" '%s' "$respuesta"
            return 0
        fi
        echo "  Escribe redes con máscara separadas por espacio (ejemplo: 192.168.14.0/24)."
    done
}

# Para el nombre de usuario: solo letras minúsculas, números, guion y guion bajo.
preguntar_usuario() {
    local texto="$1" var="$2" actual respuesta
    actual="${!var}"
    while true; do
        read -r -p "$texto [$actual]: " respuesta || exit 1
        respuesta="${respuesta:-$actual}"
        if [[ "$respuesta" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            printf -v "$var" '%s' "$respuesta"
            return 0
        fi
        echo "  Usa solo letras minúsculas, números, guion o guion bajo."
    done
}

# Pregunta sí o no. Devuelve 0 si la respuesta es s/S/si/SI.
confirmar() {
    local respuesta
    read -r -p "$1 (s/n): " respuesta || exit 1
    [[ "$respuesta" =~ ^([sS]|[sS][iíIÍ])$ ]]
}

pausa() { read -r -p "Presiona Enter para volver al menú... " _ || true; }

# Guarda las IP en el archivo de configuración (solo si cambiaron).
guardar_config() {
    escribir_si_cambia "$CONFIG" 600 <<EOF
# Generado por zabbix-admin.sh (menú). Se puede borrar para volver a los valores por defecto.
ZBX_SERVER_IP="${ZBX_SERVER_IP}"
GATEWAY_IP="${GATEWAY_IP}"
NODOS="${NODOS}"
DESTINO_RESPALDO="${DESTINO_RESPALDO}"
USUARIO_DESTINO="${USUARIO_DESTINO}"
REDES_ADMIN="${REDES_ADMIN}"
EOF
    echo "Datos guardados en $CONFIG"
}

# Pregunta todas las IP del proyecto y las guarda.
configurar_ips() {
    local propia
    propia="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    echo
    echo "== Configurar las IP del proyecto =="
    echo "Escribe cada IP y presiona Enter. Si solo presionas Enter, se deja la que aparece entre corchetes."
    [[ -n "$propia" ]] && echo "La IP de ESTA máquina es: $propia"
    echo
    preguntar_ip "IP de la VM de Zabbix (el servidor)" ZBX_SERVER_IP
    preguntar_ip "IP de la pasarela Zentyal" GATEWAY_IP
    preguntar_lista_ips "IP de los nodos que se van a vigilar (separadas por espacio)" NODOS
    preguntar_ip "IP del nodo de respaldo" DESTINO_RESPALDO
    preguntar_usuario "Usuario en el nodo de respaldo" USUARIO_DESTINO
    preguntar_redes "Redes con permiso de SSH y web de Zabbix (con máscara)" REDES_ADMIN
    echo
    echo "Resumen: servidor ${ZBX_SERVER_IP} | pasarela ${GATEWAY_IP} | nodos ${NODOS} | respaldo ${USUARIO_DESTINO}@${DESTINO_RESPALDO}"
    guardar_config
}

# Corre una acción en un subproceso: si falla, el menú no se cierra.
ejecutar() {
    local codigo
    set +e
    ( set -e; "$@" )
    codigo=$?
    set -e
    if [[ $codigo -ne 0 ]]; then
        echo
        echo "La acción terminó con un error (código $codigo). Lee el mensaje de arriba o el registro: $LOG"
    fi
    pausa
}

# Esta máquina tiene la IP que se le pasa? (para no instalar el agente en el servidor por error)
esta_maquina_tiene() { hostname -I | tr ' ' '\n' | grep -qx "$1"; }

menu_agente() {
    echo
    echo "== Instalar el agente en ESTE nodo =="
    echo "El agente reporta al servidor Zabbix: dime su IP."
    preguntar_ip "IP del servidor Zabbix" ZBX_SERVER_IP
    if esta_maquina_tiene "$ZBX_SERVER_IP"; then
        echo
        echo "OJO: esta máquina ES el servidor (tiene la IP $ZBX_SERVER_IP)."
        echo "El servidor ya trae su propio agente. Instalar el modo agente aquí lo deja mal configurado."
        confirmar "¿Seguro que quieres seguir?" || { pausa; return 0; }
    fi
    guardar_config
    ejecutar fase_agente
}

menu_monitor() {
    local op
    echo
    echo "== Script de monitoreo con systemd timer =="
    echo "  1) Esta máquina es el SERVIDOR de Zabbix"
    echo "  2) Esta máquina es un NODO normal"
    read -r -p "Elige 1 o 2: " op || exit 1
    case "$op" in
        1) ejecutar fase_monitor servidor ;;
        2) preguntar_ip "IP del servidor Zabbix" ZBX_SERVER_IP; guardar_config; ejecutar fase_monitor nodo ;;
        *) echo "Opción no válida."; pausa ;;
    esac
}

menu_principal() {
    # El menú necesita permisos de administrador: si no los tiene, se vuelve a abrir con sudo.
    if [[ $EUID -ne 0 ]]; then
        echo "El menú necesita permisos de administrador. Se abrirá con sudo..."
        exec sudo bash "$0"
    fi
    if [[ ! -f "$CONFIG" ]]; then
        echo "Es la primera vez que se abre el menú, así que primero hay que decir cuáles son las IP."
        configurar_ips
        pausa
    fi
    local opcion
    while true; do
        clear 2>/dev/null || true
        cat <<EOF
==============================================================
  Zabbix y monitoreo  -  Mesa 4  -  Módulo 3.8
  Servidor Zabbix: ${ZBX_SERVER_IP}      Pasarela: ${GATEWAY_IP}
  Esta máquina: $(hostname)  ($(hostname -I | awk '{print $1}'))
==============================================================
   1) Configurar las IP (cambiar las que ya están guardadas)
   2) Comprobar la red (IP, pasarela, internet y nodos)
   3) Quitar WireGuard (ya no se usa)
   4) Hardening: SSH por llave y fail2ban
   5) Firewall (iptables)
   6) INSTALAR el servidor Zabbix   (solo en la VM de Zabbix)
   7) INSTALAR el agente            (solo en los otros nodos)
   8) Script de monitoreo con systemd timer
   9) Respaldo automático de la base de datos
  10) Prueba de restauración del respaldo
  11) Ver el estado de los servicios
  12) Diagnóstico si Zabbix no arranca
  13) Reparar la base de datos (BORRA todos los datos)
   0) Salir
==============================================================
EOF
        read -r -p "Elige una opción: " opcion || exit 0
        case "$opcion" in
            1)  configurar_ips; pausa ;;
            2)  ejecutar revisar_red ;;
            3)  ejecutar quitar_vpn ;;
            4)  echo "Antes de seguir: desde la PC (fuera de la VM) hay que haber copiado la llave con ssh-copy-id."
                if confirmar "¿Ya copiaste tu llave?"; then ejecutar fase_hardening; else echo "Hazlo primero (ver la guía) y vuelve."; pausa; fi ;;
            5)  echo "Deja otra ventana ssh abierta mientras se aplica, por si algo sale mal."
                if confirmar "¿Aplicar el firewall ahora?"; then ejecutar fase_firewall; else pausa; fi ;;
            6)  echo "Se instalará Zabbix en esta máquina con la IP ${ZBX_SERVER_IP}. Necesita internet y tarda varios minutos."
                if confirmar "¿Continuar?"; then ejecutar fase_servidor; else pausa; fi ;;
            7)  menu_agente ;;
            8)  menu_monitor ;;
            9)  ejecutar fase_respaldo ;;
            10) ejecutar restaurar_prueba ;;
            11) ejecutar estado ;;
            12) ejecutar diagnostico ;;
            13) ejecutar reparar ;;
            0)  echo "Hasta luego."; exit 0 ;;
            *)  echo "Esa opción no existe."; pausa ;;
        esac
    done
}

# Programa principal
mkdir -p "$(dirname "$LOG")"
case "${1:-}" in
    menu|"")   menu_principal; exit 0 ;;
    hardening) necesita_root; fase_hardening ;;
    firewall)  necesita_root; fase_firewall ;;
    servidor)  necesita_root; fase_servidor ;;
    agente)    necesita_root
               if [[ -n "${2:-}" ]]; then es_ip "$2" || falla "'$2' no es una IP válida."; ZBX_SERVER_IP="$2"; fi
               fase_agente ;;
    monitor)   necesita_root
               if [[ -n "${3:-}" ]]; then es_ip "$3" || falla "'$3' no es una IP válida."; ZBX_SERVER_IP="$3"; fi
               fase_monitor "${2:-servidor}" ;;
    red)       revisar_red; exit 0 ;;
    sin-vpn)   necesita_root; quitar_vpn ;;
    idioma)    necesita_root; asegurar_idiomas ;;
    respaldo)  necesita_root; fase_respaldo ;;
    restaurar-prueba) necesita_root; restaurar_prueba ;;
    diagnostico) diagnostico; exit 0 ;;
    reparar)   necesita_root; reparar ;;
    estado)    estado; exit 0 ;;
    *) echo "Uso: sudo $0 [menu|hardening|firewall|servidor|agente|monitor [servidor|nodo]|estado|diagnostico|reparar|idioma|respaldo|restaurar-prueba|red|sin-vpn]"; exit 1 ;;
esac
if [[ $CAMBIOS -eq 0 ]]; then
    log "Todo estaba ya aplicado: esta corrida no cambió nada."
fi

##########################################################################################################################
# Para poder seguir con este script debe haber internet en la VM
#-Descarga el repositorio de oficial de Zabbix 7.0 LTS
#-Tarda varios minutos porque importa el esquema de la base
#-La se gunda corrida debe decir ya instalado y sin cambios
#-El tercer comando es la clave de la base generada: se usa solo en el asistentente web
##########################################################################################################################
