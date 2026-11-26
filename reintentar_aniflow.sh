#!/usr/bin/env bash
set -euo pipefail

# Rellena solo estos cinco valores con datos de tu consola OCI (se pueden override por entorno):
COMPARTMENT_ID="${COMPARTMENT_ID:-ocid1.tenancy.oc1..aaaaaaacrxoyxveqtss6sshjv5hyrwi6nuvwptkgvy2xuivfzpinpxg2bwa}" # OCID del compartment raíz (tenancy)
AD_NAME="${AD_NAME:-loPQ:SA-BOGOTA-1-AD-1}" # Availability Domain de sa-bogota-1
SUBNET_ID="${SUBNET_ID:-ocid1.subnet.oc1.sa-bogota-1.aaaaaaaayd3qnmunzymcberuuksma7lgbsmpckbplr7o23hmkfr4boqnyhxa}" # OCID de la subnet pública
IMAGE_ID="${IMAGE_ID:-ocid1.image.oc1.sa-bogota-1.aaaaaaaazy5djfegqb5bqqkxvhvj3syvamkhxqexvzxsnkkdfxy26qyxa5pq}" # Ubuntu 24.04 aarch64 (Canonical-Ubuntu-24.04-aarch64-2026.07.17-0)
SSH_PUB_KEY_FILE="${SSH_PUB_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}" # Clave pública SSH (nunca la privada)

REGION="sa-bogota-1"
DISPLAY_NAME="${DISPLAY_NAME:-aniflow-a1}"
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEMORY_GB=12
BOOT_VOLUME_GB=80
RETRY_INTERVAL="${RETRY_INTERVAL:-45}"
RATE_LIMIT_BACKOFF="${RATE_LIMIT_BACKOFF:-300}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-0}"
DRY_RUN="${DRY_RUN:-0}"

OCI_BIN="${OCI_BIN:-$HOME/oci-venv/bin/oci}"
OCI_CONFIG="${OCI_CONFIG:-$HOME/.oci/config}"

log() {
  printf '%s %s\n' "$(date '+%F %T %Z')" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

preflight() {
  local missing=()
  [[ -x "$OCI_BIN" ]] || missing+=("$HOME/oci-venv/bin/oci (ejecutable)")
  [[ -r "$OCI_CONFIG" ]] || missing+=("$HOME/.oci/config (legible)")
  if (( ${#missing[@]} > 0 )); then
    if (( DRY_RUN )); then
      log "AVISO (DRY_RUN) falta(n): ${missing[*]}"
    else
      die "falta(n): ${missing[*]}. Instala oci-cli en ~/oci-venv y configura ~/.oci con '$OCI_BIN setup config'. No se muestra el contenido de archivos ni claves."
    fi
  fi
}

require_value() {
  local name="$1" value="$2"
  [[ -n "$value" ]] || die "$name está vacío; rellénalo en la cabecera del script."
}

require_ocid() {
  local name="$1" value="$2" kind="$3"
  require_value "$name" "$value"
  [[ "$value" == "ocid1.$kind."* ]] || die "$name no parece un OCID ocid1.$kind..."
}

validar_entradas() {
  if [[ "$COMPARTMENT_ID" != ocid1.compartment.* && "$COMPARTMENT_ID" != ocid1.tenancy.* ]]; then
    die "COMPARTMENT_ID no parece un OCID ocid1.compartment... ni ocid1.tenancy..."
  fi
  require_value "AD_NAME" "$AD_NAME"
  require_ocid "SUBNET_ID" "$SUBNET_ID" "subnet"
  require_ocid "IMAGE_ID" "$IMAGE_ID" "image"
  require_value "SSH_PUB_KEY_FILE" "$SSH_PUB_KEY_FILE"
  [[ -f "$SSH_PUB_KEY_FILE" && -r "$SSH_PUB_KEY_FILE" && -s "$SSH_PUB_KEY_FILE" ]] || die "SSH_PUB_KEY_FILE no es un archivo público legible y no vacío."
  [[ "$RETRY_INTERVAL" =~ ^[0-9]+$ ]] && (( RETRY_INTERVAL >= 30 )) || die "RETRY_INTERVAL debe ser un entero >= 30."
  [[ "$RATE_LIMIT_BACKOFF" =~ ^[0-9]+$ ]] && (( RATE_LIMIT_BACKOFF >= RETRY_INTERVAL )) || die "RATE_LIMIT_BACKOFF debe ser un entero >= RETRY_INTERVAL."
  [[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || die "MAX_ATTEMPTS debe ser un entero (0 = sin límite)."
  [[ "$DRY_RUN" =~ ^[01]$ ]] || die "DRY_RUN debe ser 0 o 1."
}

lanzar_instancia() {
  "$OCI_BIN" --region "$REGION" compute instance launch \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$AD_NAME" \
    --display-name "$DISPLAY_NAME" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
    --image-id "$IMAGE_ID" \
    --subnet-id "$SUBNET_ID" \
    --assign-public-ip true \
    --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
    --ssh-authorized-keys-file "$SSH_PUB_KEY_FILE"
}

preflight
validar_entradas

log "Región: $REGION | AD: $AD_NAME | shape: $SHAPE ($OCPUS OCPU / ${MEMORY_GB} GB) | boot: ${BOOT_VOLUME_GB} GB"
log "Intervalo: ${RETRY_INTERVAL}s | intentos máximos: $MAX_ATTEMPTS (0 = sin límite)"

attempt=0
while :; do
  if (( MAX_ATTEMPTS > 0 && attempt >= MAX_ATTEMPTS )); then
    die "se alcanzó MAX_ATTEMPTS=$MAX_ATTEMPTS sin crear la instancia"
  fi
  attempt=$((attempt + 1))
  log "Intento $attempt"

  if (( DRY_RUN )); then
    log "DRY_RUN: no se llama a la API; se omiten todos los valores sensibles."
    exit 0
  fi

  set +e
  salida=$(lanzar_instancia 2>&1)
  codigo=$?
  set -e

  if (( codigo == 0 )); then
    if [[ "$salida" =~ ocid1\.instance\.[^[:space:]\",]+ ]]; then
      log "Instancia creada: ${BASH_REMATCH[0]}"
    else
      log "Instancia creada; no se pudo extraer el OCID de la salida."
    fi
    break
  fi

  if grep -Eqi 'out[[:space:]]+of[[:space:]]+(host[[:space:]]+)?capacity|out-of-(host-)?capacity' <<< "$salida"; then
    log "Sin capacidad; reintentando en ${RETRY_INTERVAL}s."
    sleep "$RETRY_INTERVAL"
    continue
  fi

  if grep -Eqi 'too[[:space:]]*many[[:space:]]*requests|rate[[:space:]]*limit|throttl' <<< "$salida"; then
    log "Límite de tasa de la API; esperando ${RATE_LIMIT_BACKOFF}s."
    sleep "$RATE_LIMIT_BACKOFF"
    continue
  fi

  die "error de OCI no relacionado con capacidad (exit $codigo). No se imprime la salida cruda."
done

log "Fin: instancia aprovisionada tras $attempt intento(s)."
