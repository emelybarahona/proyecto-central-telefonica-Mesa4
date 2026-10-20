#!/usr/bin/env bash
# =============================================================================
# zabbix-admin.sh  -  Mesa 4  -  Módulo 3.8
# Responsable:(PC18)  -  Rol: Monitoreo y Seguridad (Zabbix)
#
# Qué hace
#   Deja listo el monitoreo del mini centro de datos es idempotente: cada paso
#   revisa si ya está hecho y, si lo está, no toca nada. Se puede correr las
#   veces que haga falta (por ejemplo, después de mejorar el script).
#
# Uso (siempre con sudo)
#   ./zabbix-admin.sh hardening          # SSH por llave + fail2ban (cualquier nodo)
#   ./zabbix-admin.sh firewall           # reglas iptables del servidor (política DROP)
#   ./zabbix-admin.sh servidor           # INSTALA Zabbix server + MariaDB + web + agente
#   ./zabbix-admin.sh agente             # Agente Zabbix (los demás nodos)
#   ./zabbix-admin.sh monitor servidor   # script de monitoreo + systemd timer
#   ./zabbix-admin.sh monitor nodo       # igual, pero para un nodo normal
#   ./zabbix-admin.sh estado             # resumen de cómo quedó todo
#
# Orden recomendado en el servidor: hardening, servidor, firewall, monitor servidor.
# Orden recomendado en cada nodo:   hardening, agente, monitor nodo.
#Al usar /usr/bin/env bash, el sistema busca cuál es la versión de Bash activa o #disponible en las rutas del usuario en ese #momento, lo que hace que el script #funcione en una mayor variedad de computadoras y sistemas tipo Unix por esa razón 
# no utilizo #!/bin/bash
# =============================================================================

set -euo pipefail

#Párametros del proyecto
ZBX_VERSION="7.0"                   
ZBX_SERVER_IP="192.168.50.11"        
NODOS="192.168.50.10 192.168.50.12"  
DB_NOMBRE="zabbix"
DB_USUARIO="zabbix"
ARCHIVO_CLAVE_DB="/root/.zabbix-db-pass"   
REDES_ADMIN="192.168.50.0/24 192.168.122.0/24" 
UMBRAL_DISCO=90                      
UMBRAL_MEMORIA=90                   
LOG="/var/log/zabbix-admin.log"
CAMBIOS=0

# Funciones de ayuda
log()   { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
aviso() { echo "[$(date '+%F %T')] AVISO: $*" | tee -a "$LOG" >&2; }
falla() { echo "[$(date '+%F %T')] ERROR: $*" | tee -a "$LOG" >&2; exit 1; }

necesita_root() { [[ $EUID -eq 0 ]] || falla "Corre el script con sudo."; }

# Instala un paquete solo si todavía no está.
asegurar_paquete() {
    if dpkg -s "$1" >/dev/null 2>&1; then
        log "Paquete $1: ya instalado."
    else
        log "Paquete $1: instalando..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" >>"$LOG" 2>&1
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
    dpkg -i "$deb" >>"$LOG" 2>&1
    apt-get update >>"$LOG" 2>&1
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
        falla "No hay llaves en ${home}/.ssh/authorized_keys. Desde tu PC corre primero: ssh-copy-id ${usuario}@IP-DE-ESTA-VM"
    fi

    asegurar_paquete openssh-server
    asegurar_paquete fail2ban

    # Se usa el prefijo 00 porque en Ubuntu 24.04 gana la PRIMERA línea que
    # sshd lee, y archivos como 50-cloud-init.conf podrían reactivar la contraseña.
    escribir_si_cambia /etc/ssh/sshd_config.d/00-hardening.conf 644 <<'EOF'
# Generado por zabbix-setup.sh
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
# Generado por zabbix-setup.sh
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

fase_firewall() {
    log "== Firewall del servidor Zabbix (iptables) =="
    # IMPORTANTE: deja abierta otra sesión SSH mientras corres esto. Primero se
    # agregan las reglas que permiten el acceso y solo al final se pone la
    # política DROP, para no cortarte la conexión.
    asegurar_paquete iptables
    asegurar_paquete iptables-persistent

    regla_iptables -A INPUT -i lo -j ACCEPT
    regla_iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    regla_iptables -A INPUT -p icmp -j ACCEPT

    # SSH y la web de Zabbix solo desde las redes de administración.
    for red in $REDES_ADMIN; do
        regla_iptables -A INPUT -s "$red" -p tcp --dport 22 -j ACCEPT
        regla_iptables -A INPUT -s "$red" -p tcp --dport 80 -j ACCEPT
    done
    # Túnel WireGuard y puerto del servidor Zabbix (agentes activos) desde la VPN.
    regla_iptables -A INPUT -p udp --dport 51820 -j ACCEPT
    regla_iptables -A INPUT -s 192.168.50.0/24 -p tcp --dport 10051 -j ACCEPT

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

# Servidor de Zabbix
fase_servidor() {
    log "== Servidor Zabbix + MariaDB =="
    apt-get update >>"$LOG" 2>&1
    asegurar_paquete wget
    asegurar_paquete mariadb-server
    asegurar_repo_zabbix
    asegurar_paquete zabbix-server-mysql
    asegurar_paquete zabbix-frontend-php
    asegurar_paquete zabbix-apache-conf
    asegurar_paquete zabbix-sql-scripts
    asegurar_paquete zabbix-agent2

    # La clave de la base se genera una sola vez y se guarda con permiso 600.
    if [[ ! -s "$ARCHIVO_CLAVE_DB" ]]; then
        openssl rand -hex 16 > "$ARCHIVO_CLAVE_DB"
        chmod 600 "$ARCHIVO_CLAVE_DB"
        log "Clave de la base generada en $ARCHIVO_CLAVE_DB"
        CAMBIOS=1
    fi
    local clave; clave="$(cat "$ARCHIVO_CLAVE_DB")"

    # Los IF NOT EXISTS hacen que repetir esto no dé error ni duplique nada.
    mariadb -e "CREATE DATABASE IF NOT EXISTS ${DB_NOMBRE} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
    mariadb -e "CREATE USER IF NOT EXISTS '${DB_USUARIO}'@'localhost' IDENTIFIED BY '${clave}';"
    mariadb -e "ALTER USER '${DB_USUARIO}'@'localhost' IDENTIFIED BY '${clave}';"
    mariadb -e "GRANT ALL PRIVILEGES ON ${DB_NOMBRE}.* TO '${DB_USUARIO}'@'localhost'; FLUSH PRIVILEGES;"

    # El esquema se importa solo si la tabla 'users' no existe todavía.
    local existe
    existe="$(mariadb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NOMBRE}' AND table_name='users';")"
    if [[ "$existe" -eq 0 ]]; then
        log "Importando el esquema de Zabbix (tarda un par de minutos)..."
        mariadb -e "SET GLOBAL log_bin_trust_function_creators = 1;"
        zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz \
            | MYSQL_PWD="$clave" mariadb --default-character-set=utf8mb4 -u"$DB_USUARIO" "$DB_NOMBRE"
        mariadb -e "SET GLOBAL log_bin_trust_function_creators = 0;"
        CAMBIOS=1
    else
        log "Esquema de Zabbix: ya importado."
    fi

    local conf="/etc/zabbix/zabbix_server.conf" reiniciar=0
    fijar_param "$conf" DBName "$DB_NOMBRE";        reiniciar=$((reiniciar + PARAM_CAMBIO))
    fijar_param "$conf" DBUser "$DB_USUARIO";       reiniciar=$((reiniciar + PARAM_CAMBIO))
    fijar_param "$conf" DBPassword "$clave";        reiniciar=$((reiniciar + PARAM_CAMBIO))

    # El agente del propio servidor reporta a 127.0.0.1.
    local agconf="/etc/zabbix/zabbix_agent2.conf"
    fijar_param "$agconf" Server "127.0.0.1,${ZBX_SERVER_IP}"; reiniciar=$((reiniciar + PARAM_CAMBIO))
    fijar_param "$agconf" ServerActive "127.0.0.1";            reiniciar=$((reiniciar + PARAM_CAMBIO))
    fijar_param "$agconf" Hostname "$(hostname)";              reiniciar=$((reiniciar + PARAM_CAMBIO))

    systemctl enable zabbix-server zabbix-agent2 apache2 >>"$LOG" 2>&1
    if [[ $reiniciar -gt 0 ]] || ! systemctl is-active --quiet zabbix-server; then
        systemctl restart zabbix-server zabbix-agent2 apache2
        log "Servicios de Zabbix reiniciados."
    fi

    log "Listo. Termina la configuración en el navegador: http://${ZBX_SERVER_IP}/zabbix"
    log "La clave de la base está en $ARCHIVO_CLAVE_DB (el asistente web la pide)."
    log "Usuario web inicial: Admin / zabbix. Cámbiala al entrar."
}

# Agente en los demás nodos
fase_agente() {
    log "== Agente Zabbix =="
    apt-get update >>"$LOG" 2>&1
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
# Generado por zabbix-setup.sh
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

estado() {
    echo "--- Servicios:"
    for s in ssh fail2ban mariadb apache2 zabbix-server zabbix-agent2 zbx-healthcheck.timer; do
        printf '  %-24s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo no-instalado)"
    done
    echo "--- Puertos escuchando (10050 agente, 10051 servidor, 80 web):"
    ss -tln | grep -E ':(10050|10051|80)\b' || echo "  ninguno"
    echo "--- Últimas líneas del monitoreo:"
    tail -n 8 /var/log/zbx-healthcheck.log 2>/dev/null || echo "  todavía no hay registros"
}

# Programa principal
mkdir -p "$(dirname "$LOG")"
case "${1:-}" in
    hardening) necesita_root; fase_hardening ;;
    firewall)  necesita_root; fase_firewall ;;
    servidor)  necesita_root; fase_servidor ;;
    agente)    necesita_root; fase_agente ;;
    monitor)   necesita_root; fase_monitor "${2:-servidor}" ;;
    estado)    estado; exit 0 ;;
    *) echo "Uso: sudo $0 {hardening|firewall|servidor|agente|monitor [servidor|nodo]|estado}"; exit 1 ;;
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
