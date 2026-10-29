#!/usr/bin/env bash
# =============================================================================
# puente.sh  -  Mesa 4  -  Módulo 3.8
# Configura la red en MODO PUENTE (bridge) para las máquinas virtuales de QEMU/KVM.
# Basado en la guía "Puente DEFINITIVO" (escenario: pasarela 192.168.14.252,
# host 192.168.14.4, VM 192.168.14.51).
#
# Qué hace
#   Pregunta si la máquina donde se corre es la VM o el HOST (la PC real) y escribe
#   el archivo de netplan correspondiente, con los datos que se le den:
#     - HOST: crea el puente br0 con la tarjeta cableada y le pone la IP fija
#             (archivo /etc/netplan/99-netplan.yaml).
#     - VM:   le pone su IP fija a la tarjeta de la VM (edita el único archivo de
#             /etc/netplan, o crea uno si no hay).
#   Luego valida el archivo y lo aplica. La configuración queda guardada en netplan,
#   así que es PERSISTENTE: sigue igual después de reiniciar.
#
# Es idempotente: si el archivo ya tiene exactamente lo que se pidió, no lo toca.
# Antes de cambiar un archivo guarda una copia .bak con fecha.
#
# Uso (siempre con sudo)
#   sudo ./puente.sh              # pregunta VM o Host y los datos de red
#   sudo ./puente.sh estado       # muestra IP, ruta y pruebas de red
#   sudo ./puente.sh restaurar    # vuelve a la configuración anterior (usa las copias .bak)
#
# Después del HOST hay un paso manual en virt-manager (el script lo recuerda al final):
#   VM apagada > detalles > NIC > Fuente de red: Dispositivo de puente > nombre: br0
#
# PERMISOS: si sale "Permission denied":  chmod +x puente.sh   (o:  sudo bash puente.sh)
# =============================================================================

set -euo pipefail

# ---------------------------- Parámetros ------------------------------------
NETPLAN_DIR="${NETPLAN_DIR:-/etc/netplan}"   # carpeta de netplan (se puede cambiar solo para pruebas)
ARCHIVO_HOST="99-netplan.yaml"                # archivo que se crea en el host
PUENTE="br0"                                  # nombre del puente
# Valores que se ofrecen por defecto (los de la guía del puente). Con Enter se aceptan.
GW_DEF="192.168.14.252"
IP_HOST_DEF="192.168.14.4"
IP_VM_DEF="192.168.14.51"
DNS_DEF="8.8.8.8"
MASCARA_DEF="24"
LOG="${LOG:-/var/log/puente.log}"
CAMBIOS=0

# ---------------------------- Funciones de ayuda -----------------------------
log()   { echo "[$(date '+%F %T')] $*" | tee -a "$LOG" 2>/dev/null || echo "[$(date '+%F %T')] $*"; }
aviso() { echo "[$(date '+%F %T')] AVISO: $*" >&2; }
falla() { echo "[$(date '+%F %T')] ERROR: $*" >&2; exit 1; }

necesita_root() { [[ $EUID -eq 0 || "${NETPLAN_DIR}" != "/etc/netplan" ]] || falla "Corre el script con sudo."; }

# Una IP válida son cuatro números de 0 a 255 separados por puntos.
es_ip() {
    local ip="$1" octeto
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octeto in "${BASH_REMATCH[@]:1}"; do
        (( 10#$octeto <= 255 )) || return 1
    done
}

# preguntar_ip "Texto" VARIABLE valor_por_defecto : valida y repite hasta recibir una IP válida.
preguntar_ip() {
    local texto="$1" var="$2" defecto="$3" respuesta
    while true; do
        read -r -p "$texto [$defecto]: " respuesta || exit 1
        respuesta="${respuesta:-$defecto}"
        if es_ip "$respuesta"; then printf -v "$var" '%s' "$respuesta"; return 0; fi
        echo "  Eso no parece una IP válida (ejemplo: 192.168.14.51). Intenta otra vez."
    done
}

# Máscara en bits (por ejemplo 24 = 255.255.255.0).
preguntar_mascara() {
    local respuesta
    while true; do
        read -r -p "Máscara en bits [${MASCARA_DEF}]: " respuesta || exit 1
        respuesta="${respuesta:-$MASCARA_DEF}"
        if [[ "$respuesta" =~ ^[0-9]{1,2}$ ]] && (( 10#$respuesta >= 8 && 10#$respuesta <= 30 )); then
            MASCARA="$((10#$respuesta))"; return 0
        fi
        echo "  Escribe un número entre 8 y 30 (lo normal es 24)."
    done
}

confirmar() {
    local respuesta
    read -r -p "$1 (s/n): " respuesta || exit 1
    [[ "$respuesta" =~ ^([sS]|[sS][iíIÍ])$ ]]
}

# La IP que ya tiene una tarjeta y la puerta de enlace actual (sirven como valor sugerido).
ip_actual()      { ip -4 -br addr show dev "$1" 2>/dev/null | awk '{print $3}' | cut -d/ -f1 | head -1 || true; }
gateway_actual() { ip route show default 2>/dev/null | awk '{print $3; exit}' || true; }

# Tarjetas de red "de verdad": se descartan lo, puentes, virbr, vnet, docker, etc.
listar_interfaces() {
    ip -br link 2>/dev/null | awk '{print $1}' | sed 's/@.*//' \
        | grep -Ev '^(lo|br[0-9]*|virbr|vnet|docker|veth|tun|tap|wg)' || true
}

es_inalambrica() { [[ -d "/sys/class/net/$1/wireless" || "$1" == wl* ]]; }

# Elige la tarjeta: si hay una sola la propone; si hay varias deja elegir.
elegir_interfaz() {
    local lista=() i n=0 respuesta defecto=""
    mapfile -t lista < <(listar_interfaces)
    if [[ ${#lista[@]} -eq 0 ]]; then
        echo "No se encontraron tarjetas de red."
        read -r -p "Escribe el nombre de la tarjeta (mira con: ip -br a): " IFACE
        [[ -n "$IFACE" ]] || falla "Hace falta el nombre de la tarjeta."
        return 0
    fi
    echo "Tarjetas de red encontradas:"
    for i in "${lista[@]}"; do
        n=$((n + 1))
        printf '  %d) %-12s %s %s\n' "$n" "$i" "$(ip_actual "$i")" "$(es_inalambrica "$i" && echo '(Wi-Fi)' || true)"
    done
    # Se propone la primera que no sea Wi-Fi.
    for i in "${lista[@]}"; do
        if ! es_inalambrica "$i"; then defecto="$i"; break; fi
    done
    defecto="${defecto:-${lista[0]}}"
    read -r -p "Nombre de la tarjeta a usar [${defecto}]: " respuesta || exit 1
    IFACE="${respuesta:-$defecto}"
    if [[ "$ROL" == "host" ]] && es_inalambrica "$IFACE"; then
        aviso "${IFACE} es Wi-Fi: un puente NO funciona por Wi-Fi, hace falta la tarjeta con cable."
        confirmar "¿Seguir de todos modos?" || falla "Cancelado. Conecta el cable y vuelve a correr el script."
    fi
}

# Escribe un archivo con lo que llega por stdin solo si es distinto del actual (y guarda copia .bak).
# Deja ARCHIVO_CAMBIO en 1 (cambió) o 0 (sin cambios).
escribir_si_cambia() {
    local destino="$1" modo="${2:-600}" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if [[ -f "$destino" ]] && cmp -s "$tmp" "$destino"; then
        log "Archivo $destino: sin cambios."
        ARCHIVO_CAMBIO=0
    else
        if [[ -f "$destino" ]]; then
            cp -a "$destino" "${destino}.bak.$(date +%Y%m%d%H%M%S)"
            log "Copia de seguridad guardada: ${destino}.bak.*"
        fi
        install -m "$modo" "$tmp" "$destino"
        log "Archivo $destino: actualizado."
        ARCHIVO_CAMBIO=1
        CAMBIOS=1
    fi
    rm -f "$tmp"
}

# ---------------------------- Contenido de los archivos netplan --------------
# Los espacios del inicio son importantes en YAML (cada nivel lleva 2 espacios más).
yaml_host() {
    cat <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: no
  bridges:
    ${PUENTE}:
      interfaces: [${IFACE}]
      dhcp4: no
      addresses: [${IP}/${MASCARA}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS}]
EOF
}

yaml_vm() {
    cat <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: no
      addresses: [${IP}/${MASCARA}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS}]
EOF
}

# ---------------------------- Preguntas --------------------------------------
preguntar_rol() {
    local op
    echo
    echo "=============================================================="
    echo "  Red en modo puente  -  Mesa 4  -  Módulo 3.8"
    echo "=============================================================="
    echo "  ¿Esta máquina es la VM o el Host?"
    echo "    1) VM    (la máquina virtual: se le pone su IP fija)"
    echo "    2) Host  (la PC real que corre QEMU: se crea el puente ${PUENTE})"
    echo
    while true; do
        read -r -p "Elige 1 o 2: " op || exit 1
        case "$op" in
            1) ROL="vm";   return 0 ;;
            2) ROL="host"; return 0 ;;
            *) echo "  Escribe 1 o 2." ;;
        esac
    done
}

preguntar_datos() {
    local ip_sugerida gw_sugerida
    echo
    elegir_interfaz
    echo
    echo "Ahora los datos de red. Presiona Enter para aceptar el valor entre corchetes."
    if [[ "$ROL" == "host" ]]; then ip_sugerida="$IP_HOST_DEF"; else ip_sugerida="$IP_VM_DEF"; fi
    preguntar_ip "¿Cuál es la IP fija de esta máquina?" IP "$ip_sugerida"
    preguntar_mascara
    gw_sugerida="$GW_DEF"
    preguntar_ip "¿Cuál es la puerta de enlace (pasarela)?" GATEWAY "$gw_sugerida"
    preguntar_ip "¿Cuál es el servidor DNS?" DNS "$DNS_DEF"
    if [[ "$IP" == "$GATEWAY" ]]; then
        falla "La IP de la máquina no puede ser igual a la puerta de enlace."
    fi
    echo
    echo "Resumen:"
    echo "  Rol:             $ROL"
    echo "  Tarjeta:         $IFACE$([[ "$ROL" == "host" ]] && echo "  (se crea el puente ${PUENTE})" || true)"
    echo "  IP fija:         ${IP}/${MASCARA}"
    echo "  Puerta de enlace: $GATEWAY"
    echo "  DNS:             $DNS"
    confirmar "¿Está todo correcto?" || falla "Cancelado. Vuelve a correr el script."
    # Aviso si la IP ya la usa otro equipo de la red.
    local mis_ips
    mis_ips="$(hostname -I 2>/dev/null | tr ' ' '\n' || true)"
    if ! grep -qx "$IP" <<<"$mis_ips"; then
        if ping -c1 -W1 "$IP" >/dev/null 2>&1; then
            aviso "La IP ${IP} ya responde en la red: puede estar en uso por otro equipo."
            confirmar "¿Seguir de todos modos?" || falla "Cancelado."
        fi
    fi
}

# ---------------------------- Acciones ---------------------------------------
# Borra puentes viejos de NetworkManager (si existen). Es lo que pide el Paso 1 de la guía.
limpiar_puente_viejo() {
    command -v nmcli >/dev/null 2>&1 || return 0
    local con lista
    lista="$(nmcli -t -f NAME connection show 2>/dev/null || true)"
    for con in "$PUENTE" "${PUENTE}-slave"; do
        if grep -qx "$con" <<<"$lista"; then
            nmcli connection delete "$con" >/dev/null 2>&1 || true
            log "Conexión vieja '$con' de NetworkManager eliminada."
            CAMBIOS=1
        fi
    done
}

# En la VM, cloud-init puede volver a escribir el netplan al reiniciar y deshacer el cambio.
# Se le apaga la configuración de red para que lo escrito sea realmente persistente.
proteger_de_cloud_init() {
    [[ -d /etc/cloud/cloud.cfg.d && "$NETPLAN_DIR" == "/etc/netplan" ]] || return 0
    escribir_si_cambia /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg 644 <<'EOF'
network: {config: disabled}
EOF
}

# Elige qué archivo de netplan se edita en la VM.
elegir_archivo_vm() {
    local archivos=() f n=0 respuesta
    mapfile -t archivos < <(find "$NETPLAN_DIR" -maxdepth 1 -type f -name '*.yaml' 2>/dev/null | sort)
    if [[ ${#archivos[@]} -eq 0 ]]; then
        ARCHIVO="${NETPLAN_DIR}/01-netcfg.yaml"
        log "No había archivos de netplan: se creará ${ARCHIVO}."
    elif [[ ${#archivos[@]} -eq 1 ]]; then
        ARCHIVO="${archivos[0]}"
        log "Se editará el único archivo de netplan: ${ARCHIVO}"
    else
        echo "Hay varios archivos de netplan (debería haber uno solo):"
        for f in "${archivos[@]}"; do n=$((n + 1)); echo "  $n) $f"; done
        while true; do
            read -r -p "¿Cuál se edita? (número): " respuesta || exit 1
            if [[ "$respuesta" =~ ^[0-9]+$ ]] && (( respuesta >= 1 && respuesta <= ${#archivos[@]} )); then
                ARCHIVO="${archivos[$((respuesta - 1))]}"; break
            fi
            echo "  Escribe un número de la lista."
        done
    fi
}

# Valida con netplan generate; si el archivo tiene errores, deja todo como estaba.
validar() {
    local ultimo_bak
    if ! netplan generate >>"$LOG" 2>&1; then
        aviso "netplan encontró errores en el archivo:"
        netplan generate 2>&1 | tail -5 || true
        ultimo_bak="$(ls -1t "${ARCHIVO}".bak.* 2>/dev/null | head -1 || true)"
        if [[ -n "$ultimo_bak" ]]; then
            cp -a "$ultimo_bak" "$ARCHIVO"
            log "Se restauró la copia anterior: $ultimo_bak"
        elif [[ "$ROL" == "host" ]]; then
            rm -f "$ARCHIVO"
            log "Se borró el archivo nuevo con errores."
        fi
        falla "El archivo de netplan no era válido; se dejó como estaba. Revisa los datos y repite."
    fi
    log "netplan generate: el archivo es válido."
}

aplicar() {
    echo
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        aviso "Estás conectado por SSH: al cambiar la IP la conexión se cortará. Vuelve a entrar con la IP nueva (${IP}). Mejor aún: hazlo desde la consola de la máquina."
    fi
    echo "Cómo aplicar los cambios:"
    echo "  1) netplan try  (recomendado: prueba y, si pierdes la conexión, se deshace solo a los 2 minutos)"
    echo "  2) netplan apply (aplica directo)"
    echo "  3) No aplicar ahora (se aplicará al reiniciar o con: sudo netplan apply)"
    local op
    while true; do
        read -r -p "Elige 1, 2 o 3 [1]: " op || exit 1
        op="${op:-1}"
        case "$op" in
            1) log "Aplicando con netplan try (presiona Enter para ACEPTAR cuando lo pida)..."
               netplan try --timeout 120 || aviso "netplan try no se aceptó: los cambios se deshicieron."
               return 0 ;;
            2) log "Aplicando con netplan apply..."
               netplan apply
               return 0 ;;
            3) log "No se aplicó. Cuando quieras: sudo netplan apply"
               return 0 ;;
            *) echo "  Escribe 1, 2 o 3." ;;
        esac
    done
}

# Pruebas de red para comprobar que todo quedó bien.
verificar() {
    local gw
    echo
    echo "--- Direcciones IP:"
    ip -4 -br addr show 2>/dev/null | grep -v '^lo' || true
    echo "--- Ruta por defecto:"
    ip route show default 2>/dev/null || true
    gw="$(gateway_actual)"
    echo "--- Pruebas (ping):"
    local entrada destino nombre
    for entrada in "${gw:-$GW_DEF}|puerta de enlace" "8.8.8.8|internet (por IP)" "google.com|internet (por nombre, prueba el DNS)"; do
        destino="${entrada%%|*}"; nombre="${entrada#*|}"
        if ping -c1 -W2 "$destino" >/dev/null 2>&1; then
            printf '  %-16s %-40s responde\n' "$destino" "($nombre)"
        else
            printf '  %-16s %-40s NO responde\n' "$destino" "($nombre)"
        fi
    done
}

# ---------------------------- Modos ------------------------------------------
configurar_host() {
    log "== Configurando el HOST: puente ${PUENTE} sobre ${IFACE} =="
    limpiar_puente_viejo
    ARCHIVO="${NETPLAN_DIR}/${ARCHIVO_HOST}"
    # Si ya hay otros archivos que definen la misma tarjeta, pueden chocar con este.
    local otros
    otros="$(find "$NETPLAN_DIR" -maxdepth 1 -type f -name '*.yaml' ! -name "$ARCHIVO_HOST" 2>/dev/null | tr '\n' ' ')"
    if [[ -n "$otros" ]] && grep -qs "$IFACE" $otros 2>/dev/null; then
        aviso "Otros archivos de netplan también mencionan ${IFACE}: $otros"
        aviso "Si algo no funciona, revisa que no se contradigan (la guía solo usa ${ARCHIVO_HOST})."
    fi
    escribir_si_cambia "$ARCHIVO" 600 < <(yaml_host)
    if [[ $ARCHIVO_CAMBIO -eq 0 ]]; then
        log "El puente ya estaba configurado así. No se cambió nada."
        verificar
        return 0
    fi
    validar
    aplicar
    verificar
    cat <<EOF

--------------------------------------------------------------
PASO MANUAL QUE FALTA (en virt-manager, con la VM apagada):
  1) Abre la VM > botón azul con la letra i (detalles del hardware virtual).
  2) En el menú de la izquierda elige NIC.
  3) Fuente de red: cambia "Red virtual" por "Dispositivo de puente".
  4) Nombre del dispositivo: escribe ${PUENTE}   (modelo: virtio).
  5) Aplicar y encender la VM. Dentro de la VM, corre este mismo script y elige "VM".
--------------------------------------------------------------
EOF
}

configurar_vm() {
    log "== Configurando la VM: IP fija en ${IFACE} =="
    elegir_archivo_vm
    escribir_si_cambia "$ARCHIVO" 600 < <(yaml_vm)
    proteger_de_cloud_init
    if [[ $ARCHIVO_CAMBIO -eq 0 && $CAMBIOS -eq 0 ]]; then
        log "La VM ya estaba configurada así. No se cambió nada."
        verificar
        return 0
    fi
    validar
    aplicar
    verificar
    echo
    echo "Listo. Ahora esta máquina debe responder en ${IP} y llegar a la puerta de enlace ${GATEWAY}."
}

# Vuelve a la configuración anterior usando la copia .bak más reciente de cada archivo.
restaurar() {
    necesita_root
    local bak base restaurados=0 vistos=" "
    while IFS= read -r bak; do
        base="${bak%.bak.*}"
        [[ "$vistos" == *" $base "* ]] && continue
        vistos+="$base "
        cp -a "$bak" "$base"
        log "Restaurado: $base  (desde $bak)"
        restaurados=$((restaurados + 1))
    done < <(ls -1t "${NETPLAN_DIR}"/*.bak.* 2>/dev/null || true)
    if [[ $restaurados -eq 0 ]]; then
        log "No hay copias .bak en ${NETPLAN_DIR}."
        if [[ -f "${NETPLAN_DIR}/${ARCHIVO_HOST}" ]] && confirmar "¿Borrar ${ARCHIVO_HOST} (el puente creado por este script)?"; then
            rm -f "${NETPLAN_DIR}/${ARCHIVO_HOST}"
            log "Borrado ${ARCHIVO_HOST}."
            restaurados=1
        fi
    fi
    if [[ $restaurados -gt 0 ]]; then
        ARCHIVO="(restaurado)"; ROL="host"
        netplan generate && log "netplan generate: válido."
        if confirmar "¿Aplicar ahora con netplan try?"; then netplan try --timeout 120 || true; fi
    fi
}

estado() { IFACE=""; GATEWAY=""; verificar; }

# ---------------------------- Programa principal -----------------------------
case "${1:-}" in
    ""|menu)
        necesita_root
        preguntar_rol
        preguntar_datos
        if [[ "$ROL" == "host" ]]; then configurar_host; else configurar_vm; fi
        if [[ $CAMBIOS -eq 0 ]]; then log "Todo estaba ya aplicado: esta corrida no cambió nada."; fi
        ;;
    estado)    estado ;;
    restaurar) restaurar ;;
    *) echo "Uso: sudo $0 [estado|restaurar]    (sin parámetros: pregunta VM o Host)"; exit 1 ;;
esac
