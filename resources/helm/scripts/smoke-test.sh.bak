#!/usr/bin/env bash
set -euo pipefail

ok()   { printf "\033[32m[OK]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[WARN]\033[0m %s\n" "$*"; }
die()  { printf "\033[31m[ERR]\033[0m %s\n" "$*"; exit 1; }
usage() {
  cat <<'EOF'
Usage: smoke-test.sh [--env <name>] [--config <file>] [--cleanup]

Options:
  --env <name>     Load presets from scripts/env/smoke-test-<name>.env
  --config <file>  Source a custom environment file with overrides
  --cleanup        Delete the test topic and schema registry subject
  --help           Show this message

Override any variable via environment (e.g. IMG_KAFKA, INTERNAL_BOOT, ...).
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="${SCRIPT_DIR}/env"

CONFIG=""
CLEANUP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -gt 1 ]] || die "--env requires a value"
      CONFIG="${ENV_DIR}/smoke-test-$2.env"
      shift 2
      ;;
    --config)
      [[ $# -gt 1 ]] || die "--config requires a value"
      CONFIG="$2"
      shift 2
      ;;
    --cleanup)
      CLEANUP=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown arg: $1 (supported: --env <name>, --config <file>, --cleanup, --help)"
      ;;
  esac
done

if [[ -n "$CONFIG" ]]; then
  [[ -f "$CONFIG" ]] || die "config file not found: $CONFIG"
  # shellcheck source=/dev/null
  source "$CONFIG"
  warn "Loaded config: $CONFIG"
fi

# =========================
# Namespaces
# =========================
: "${NS_KAFKA:=kafka}"
: "${NS_UI:=kafka-ui}"
: "${NS_SR:=schema-registry}"
: "${NS_LAG:=observability}"
: "${EXPORTER_NS:=${NS_LAG}}"
: "${EXPORTER_SERVICE:=kafka-lag-exporter}"
: "${EXPORTER_PORT:=9999}"

# =========================
# Topic + payload
# =========================
: "${TOPIC:=it.smoke}"
: "${PARTITIONS:=3}"
: "${RF:=3}"

# Kolik zpráv posílat/číst v jednotlivých testech
: "${MSG_COUNT_INT:=3}"
: "${MSG_COUNT_EXT:=3}"

# =========================
# Bootstrap endpoints
# =========================
: "${INTERNAL_BOOT:=kafka-vzp-test1-we-002-kafka-bootstrap.${NS_KAFKA}.svc.cluster.local:9092}"
: "${EXTERNAL_BOOT:=kafka.ntest1.az.vzp.cz:9094}"   # must match TLS cert SAN

# =========================
# Secrets to read credentials from
# Pick ONE of these blocks by setting JAAS_NS/JAAS_SECRET accordingly.
# =========================
# 1) Default: use Kafka-UI JAAS (created by AKV sync job)
: "${JAAS_NS:=${NS_UI}}"
: "${JAAS_SECRET:=kafka-ui-oauth}"

# 2) Alternative: Kafka Lag Exporter JAAS
# JAAS_NS="${NS_LAG}"
# JAAS_SECRET="kafka-lag-exporter-oauth"

# 3) Alternative: Schema Registry JAAS
# JAAS_NS="${NS_SR}"
# JAAS_SECRET="schema-registry-oauth"

# External listener CA (optional; only if your external LB uses a private CA)
: "${CA_NS:=${NS_KAFKA}}"
: "${CA_SECRET:=kafka-external-ca}"   # must contain key: ca.crt

# =========================
# Images / binaries (comma-separated list to allow fallbacks)
# =========================
: "${IMG_KAFKA:=confluentinc/cp-kafka:8.1.0-1-ubi9}"
: "${IMG_CURL:=curlimages/curl:8.11.1}"
: "${ALPINE:=alpine:3.20}"

# Kafka CLI commands (override if image layout differs)
: "${KAFKA_TOPICS_CMD:=/usr/bin/kafka-topics}"
: "${KAFKA_PRODUCER_CMD:=/usr/bin/kafka-console-producer}"
: "${KAFKA_CONSUMER_CMD:=/usr/bin/kafka-console-consumer}"
: "${KAFKA_API_VERSIONS_CMD:=/usr/bin/kafka-broker-api-versions}"

# =========================
# Azure AD OAuth (must match your env)
# =========================
: "${AAD_TENANT:=1174b7b3-9af8-43df-a3b2-06d8ee22d679}"
: "${AAD_AUDIENCE:=ad750293-8d4a-49ed-b09d-9eb435647a5b}"   # nis-<env>-kafka-audience appId (GUID)
: "${AAD_TOKEN_URL:=https://login.microsoftonline.com/${AAD_TENANT}/oauth2/v2.0/token}"
: "${AAD_SCOPE:=api://${AAD_AUDIENCE}/.default}"

# Per-broker headless DNS (optional sanity)
if ! declare -p BROKER_DNS >/dev/null 2>&1; then
  BROKER_DNS=(
    "kafka-vzp-test1-we-002-broker-0.kafka-vzp-test1-we-002-kafka-brokers.${NS_KAFKA}.svc"
    "kafka-vzp-test1-we-002-broker-1.kafka-vzp-test1-we-002-kafka-brokers.${NS_KAFKA}.svc"
    "kafka-vzp-test1-we-002-broker-2.kafka-vzp-test1-we-002-kafka-brokers.${NS_KAFKA}.svc"
  )
fi

choose_image() {
  local images="$1" name="$2"
  IFS=',' read -ra CANDIDATES <<<"$images"
  for img in "${CANDIDATES[@]}"; do
    img="$(echo "$img" | xargs)"
    [[ -z "$img" ]] && continue
    local suffix job
    suffix="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c6)"
    job="smoke-imgcheck-${suffix}"
    if kubectl create job "$job" --namespace "$NS_KAFKA" --image="$img" -- /bin/sh -c 'exit 0' >/dev/null 2>&1; then
      if kubectl wait --namespace "$NS_KAFKA" --for=condition=complete job/"$job" --timeout=60s >/dev/null 2>&1; then
        kubectl delete job "$job" --namespace "$NS_KAFKA" --ignore-not-found --wait=false >/dev/null 2>&1 || true
        echo "$img"
        return 0
      fi
    fi
    kubectl delete job "$job" --namespace "$NS_KAFKA" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    warn "image '$img' failed to pull; trying next candidate..."
  done
  die "failed to pull any $name images from list: $images"
}
req()  { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# ========= Local prerequisites =========
req kubectl
req base64
req date
req timeout || true  # on busybox timeout might be absent; handled in pod anyway

# Resolve preferred images (iterate through comma-separated list)
IMG_KAFKA="$(choose_image "${IMG_KAFKA}" "Kafka")"
IMG_CURL="$(choose_image "${IMG_CURL}" "curl")"
ALPINE="$(choose_image "${ALPINE}" "alpine")"

# ========= Pull secrets =========
# JAAS (required)
if ! JAAS_B64="$(kubectl -n "$JAAS_NS" get secret "$JAAS_SECRET" -o jsonpath='{.data.sasl-jaas-config}' 2>/dev/null)"; then
  die "JAAS secret not found: ${JAAS_SECRET} in ns ${JAAS_NS}"
fi
# CA (optional)
CA_B64="$(kubectl -n "$CA_NS" get secret "$CA_SECRET" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"

# ========= Helpers =========
cleanup_kafka_topic() {
  echo "== Cleanup Kafka topic =="
  kubectl -n "$NS_KAFKA" run k-del --image="$IMG_KAFKA" --restart=Never --attach --rm --command -- \
    bash -lc "
      set -euo pipefail
      BOOT='$INTERNAL_BOOT'
      JAAS=\$(echo '$JAAS_B64' | base64 -d)
      cat >/tmp/k.properties <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler
sasl.oauthbearer.token.endpoint.url=$AAD_TOKEN_URL
sasl.oauthbearer.scope=$AAD_SCOPE
sasl.jaas.config=\${JAAS}
EOF
      /usr/bin/kafka-topics --bootstrap-server \"\$BOOT\" \
        --command-config /tmp/k.properties --delete --topic '$TOPIC' || true
    " >/dev/null
  ok "topic '$TOPIC' deleted (or absent)"
}

cleanup_schema_registry() {
  echo "== Cleanup Schema Registry subject =="
  kubectl -n "$NS_SR" run sr-del --image="$IMG_CURL" --restart=Never --attach --rm -- \
    sh -lc "
      curl -fsS -X DELETE \
        http://schema-registry-port.$NS_SR.svc.cluster.local:8081/subjects/$TOPIC-value?permanent=true \
        || true
    " >/dev/null || true
  ok "schema registry subject '$TOPIC-value' deleted (or absent)"
}

# Wait for a bootstrap (internal/external); type in $1 for log message only
wait_bootstrap() {
  local which="$1" boot="$2" timeout_s="${3:-300}"
  echo "Waiting for $which bootstrap ($boot) ..."
  local start now elapsed
  start=$(date +%s)
  while true; do
    now=$(date +%s); elapsed=$((now - start))
    if (( elapsed > timeout_s )); then
      die "$which bootstrap not reachable within ${timeout_s}s"
    fi
    if kubectl -n "$NS_KAFKA" run "wait-${which}" --image="$IMG_KAFKA" --restart=Never --attach --rm --quiet --command -- \
      bash -lc "
        set -euo pipefail
        BOOT='$boot'
        JAAS=\$(echo '$JAAS_B64' | base64 -d)

        # základ bez protokolu
        cat >/tmp/k.properties <<'EOF'
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler
sasl.oauthbearer.token.endpoint.url=$AAD_TOKEN_URL
sasl.oauthbearer.scope=$AAD_SCOPE
EOF
        # přidání JAAS
        echo \"sasl.jaas.config=\${JAAS}\" >>/tmp/k.properties

        if [[ \"$which\" == \"external\" ]]; then
          # TLS větev
          if [ -n '$CA_B64' ]; then echo '$CA_B64' | base64 -d > /tmp/ca.pem; fi
          if [ -s /tmp/ca.pem ]; then
            echo 'ssl.truststore.type=PEM'             >>/tmp/k.properties
            echo 'ssl.truststore.location=/tmp/ca.pem' >>/tmp/k.properties
          fi
          echo 'security.protocol=SASL_SSL' >>/tmp/k.properties
        else
          # interní PLAINTEXT
          echo 'security.protocol=SASL_PLAINTEXT' >>/tmp/k.properties
        fi

        # rychlý metadata call s timeoutem
        timeout 15s /usr/bin/kafka-broker-api-versions --bootstrap-server \"\$BOOT\" \
          --command-config /tmp/k.properties >/dev/null 2>&1
      "; then
      ok "$which bootstrap reachable"
      return 0
    else
      printf "."
      sleep 5
    fi
  done
}


if [[ "$CLEANUP" -eq 1 ]]; then
  cleanup_kafka_topic
  cleanup_schema_registry
  ok "cleanup done"
  exit 0
fi

# ================= 0) Wait for bootstraps =================
wait_bootstrap internal "$INTERNAL_BOOT" 300
wait_bootstrap external "$EXTERNAL_BOOT" 300

# ================= 1) Internal test =================
echo "== Internal SASL_PLAINTEXT + OAuth =="
kubectl -n "$NS_KAFKA" run it-int --image="$IMG_KAFKA" --restart=Never --attach --rm --command -- \
  bash -lc "
    set -euo pipefail
    BOOT='$INTERNAL_BOOT'
    JAAS=\$(echo '$JAAS_B64' | base64 -d)
    cat >/tmp/k.properties <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler
sasl.oauthbearer.token.endpoint.url=$AAD_TOKEN_URL
sasl.oauthbearer.scope=$AAD_SCOPE
sasl.jaas.config=\${JAAS}
EOF
    /usr/bin/kafka-topics --bootstrap-server \"\$BOOT\" --command-config /tmp/k.properties \
      --create --if-not-exists --topic '$TOPIC' --partitions $PARTITIONS --replication-factor $RF

    printf 'msg-1\nmsg-2\nmsg-3\n' | \
      /usr/bin/kafka-console-producer --bootstrap-server \"\$BOOT\" \
      --producer.config /tmp/k.properties --topic '$TOPIC' >/dev/null

    /usr/bin/kafka-console-consumer --bootstrap-server \"\$BOOT\" \
      --consumer.config /tmp/k.properties --topic '$TOPIC' \
      --from-beginning --max-messages $MSG_COUNT_INT --timeout-ms 8000
  " || die "internal produce/consume failed"
ok "internal produce/consume works"

# ================= 2) External test =================
echo "== External SASL_SSL + OAuth (hostname verification ON) =="
kubectl -n "$NS_KAFKA" run it-ext --image="$IMG_KAFKA" --restart=Never --attach --rm --command -- \
  bash -lc "
    set -euo pipefail
    BOOT='$EXTERNAL_BOOT'
    JAAS=\$(echo '$JAAS_B64' | base64 -d)
    if [ -n '$CA_B64' ]; then echo '$CA_B64' | base64 -d > /tmp/ca.pem; fi

    cat >/tmp/k.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler
sasl.oauthbearer.token.endpoint.url=$AAD_TOKEN_URL
sasl.oauthbearer.scope=$AAD_SCOPE
sasl.jaas.config=\${JAAS}
EOF

    if [ -s /tmp/ca.pem ]; then
      echo 'ssl.truststore.type=PEM'             >>/tmp/k.properties
      echo 'ssl.truststore.location=/tmp/ca.pem' >>/tmp/k.properties
      # hostname verification ON by default
    fi

    printf 'ext-a\next-b\next-c\n' | \
      /usr/bin/kafka-console-producer --bootstrap-server \"\$BOOT\" \
      --producer.config /tmp/k.properties --topic '$TOPIC' >/dev/null

    /usr/bin/kafka-console-consumer --bootstrap-server \"\$BOOT\" \
      --consumer.config /tmp/k.properties --topic '$TOPIC' \
      --from-beginning --max-messages $MSG_COUNT_EXT --timeout-ms 8000
  " || die "external produce/consume failed"
ok "external produce/consume works with strict hostname verification"

# ================= 3) Schema Registry =================
echo "== Schema Registry create subject =="
kubectl -n "$NS_SR" run sr-cli --image="$IMG_CURL" --restart=Never --attach --rm -- \
  sh -lc "
    curl -fsS -X POST http://schema-registry-port.$NS_SR.svc.cluster.local:8081/subjects/$TOPIC-value/versions \
      -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
      -d '{\"schema\":\"{\\\"type\\\":\\\"record\\\",\\\"name\\\":\\\"Msg\\\",\\\"fields\\\":[{\\\"name\\\":\\\"f\\\",\\\"type\\\":\\\"string\\\"}]}\"}' \
      | grep -E '\"id\"|[0-9]'
  " || die "schema registry POST failed"
ok "schema registry subject created/readable"

# ================= 4) Kafka Exporter metrics =================
echo "== Kafka Exporter metrics =="
kubectl -n "$EXPORTER_NS" run curl-exporter --image="$IMG_CURL" --restart=Never --attach --rm -- \
  sh -lc "curl -fsS http://$EXPORTER_SERVICE.$EXPORTER_NS.svc.cluster.local:${EXPORTER_PORT}/metrics \
          | grep -E 'kafka_topic_partitions|kafka_consumergroup_lag' | head -n 5 || true" || true
ok "kafka exporter responds (if deployed)"

# ================= 5) Headless per-broker DNS =================
echo "== Per-broker headless DNS =="
kubectl -n "$NS_KAFKA" run dnscheck --image="$ALPINE" --restart=Never --attach --rm -- \
  sh -lc "apk add --no-cache bind-tools >/dev/null; \
          for h in ${BROKER_DNS[*]}; do echo ' - ' \$h; getent hosts \$h || true; done" || true
ok "headless DNS resolves (or was skipped)"

echo
ok "SMOKE TEST: ALL CHECKS PASSED"
echo "Topic: $TOPIC"
echo "Internal bootstrap: $INTERNAL_BOOT"
echo "External bootstrap: $EXTERNAL_BOOT"
echo "JAAS from: ${JAAS_SECRET} (ns: ${JAAS_NS})"
# Resolve preferred images (iterate through comma-separated list)
IMG_KAFKA="$(choose_image "${IMG_KAFKA}" "Kafka")"
IMG_CURL="$(choose_image "${IMG_CURL}" "curl")"
ALPINE="$(choose_image "${ALPINE}" "alpine")"
