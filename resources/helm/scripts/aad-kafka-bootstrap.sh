#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# CONFIG (override via env)
# =============================================================================
: "${ENV:=dev1}"   # dev1|test1|stage|prod
: "${TENANT_ID:=1174b7b3-9af8-43df-a3b2-06d8ee22d679}"
: "${KV_NAME:=kv-vzp-${ENV}-we-aks-002}"

# App registration display names
: "${KAFKA_AUDIENCE_APP_NAME:=nis-${ENV}-kafka-audience}"  # resource (audience) app
: "${KAFKA_AUDIENCE_APP_NAME_LEGACY:=nis-${ENV}-kafka}"    # fallback match if it exists

: "${KAFKA_UI_APP_NAME:=nis-${ENV}-kafka-ui}"              # Kafka-UI (confidential client)
: "${LAG_EXPORTER_APP_NAME:=nis-${ENV}-kafka-lag}"         # Lag exporter (daemon)
: "${SCHEMA_REGISTRY_APP_NAME:=nis-${ENV}-kafka-schema}"   # Schema Registry (daemon)
: "${KAFKA_CLIENT_APP_NAME:=nis-${ENV}-service-container-authentication}"      # Optional generic client (daemon)
: "${CREATE_GENERIC_CLIENT:=true}"                         # set "false" to skip generic client

# Kafka-UI redirect (add more in portal later if needed)
: "${KAFKA_UI_REDIRECT_URI:=http://localhost:8080/login/oauth2/code/azure}"

# Audience DNS Application ID URI (optional pretty URI shown in “Expose an API”)
# e.g. dev1 -> https://kafka.ndev1.az.vzp.cz ; test1 -> https://kafka.ntest1.az.vzp.cz
: "${KAFKA_AUDIENCE_DNS_URI:=}"

# Application role (application permission) value on the audience app
: "${AUDIENCE_APP_ROLE_VALUE:=kafka.access}"

# =============================================================================
# prerequisites
# =============================================================================
need(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found" >&2; exit 1; }; }
need az; need uuidgen; need jq

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
az account set --subscription "$SUBSCRIPTION_ID" >/dev/null

GRAPH="https://graph.microsoft.com/v1.0"

# =============================================================================
# Helpers
# =============================================================================
ensure_sp(){
  local appId="$1" max_tries=20 try=1
  az ad sp show --id "$appId" >/dev/null 2>&1 || az ad sp create --id "$appId" >/dev/null
  while ! az ad sp show --id "$appId" --query id -o tsv >/dev/null 2>&1; do
    (( try>=max_tries )) && { echo "ERROR: SP for $appId did not appear in time." >&2; exit 1; }
    sleep 3; ((try++))
  done
}

get_app_object_id(){
  local appId="$1" obj tries=20
  for ((i=1;i<=tries;i++)); do
    obj="$(az ad app show --id "$appId" --query id -o tsv 2>/dev/null || true)"
    [[ -n "${obj:-}" ]] && { echo "$obj"; return 0; }
    sleep 2
  done
  echo "ERROR" >&2; return 1
}

wait_sp_oid(){
  local appId="$1" obj tries=20
  for ((i=1;i<=tries;i++)); do
    obj="$(az ad sp show --id "$appId" --query id -o tsv 2>/dev/null || true)"
    [[ -n "${obj:-}" ]] && { echo "$obj"; return 0; }
    sleep 2
  done
  echo "ERROR" >&2; return 1
}

graph_patch_file(){
  local url="$1" body_file="$2" tries=8 delay=1
  for ((i=1;i<=tries;i++)); do
    if az rest --method PATCH --url "$url" --headers "Content-Type=application/json" --body @"$body_file" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"; delay=$((delay*2)); ((delay>16)) && delay=16
  done
  echo "ERROR: PATCH $url failed after retries" >&2; return 1
}

graph_post_json(){
  local url="$1" json="$2" tries=8 delay=1
  for ((i=1;i<=tries;i++)); do
    if az rest --method POST --url "$url" --headers "Content-Type=application/json" --body "$json" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"; delay=$((delay*2)); ((delay>16)) && delay=16
  done
  echo "[info] POST $url may already exist; continuing"
  return 0
}

graph_get(){
  local url="$1"
  az rest --method GET --url "$url" --output json 2>/dev/null || echo "{}"
}

get_appid_by_name(){
  az ad app list --display-name "$1" --query '[0].appId' -o tsv 2>/dev/null || true
}

get_first_existing_appid(){
  local id=""
  for n in "$@"; do
    id="$(get_appid_by_name "$n")"
    if [[ -n "$id" ]]; then echo "$id"; return 0; fi
  done
  echo ""
}

kv_put(){ az keyvault secret set --vault-name "$KV_NAME" --name "$1" --value "$2" >/dev/null; }

# =============================================================================
# Audience app helpers
# =============================================================================
upsert_audience_app_role(){
  local aud_appId="$1" role_value="$2"
  local app_obj_id; app_obj_id="$(get_app_object_id "$aud_appId")"
  local app_obj;    app_obj="$(graph_get "${GRAPH}/applications/${app_obj_id}")"

  local existing_id
  existing_id="$(echo "$app_obj" | jq -r --arg v "$role_value" '.appRoles[]? | select(.value==$v and .isEnabled==true) | .id' | head -n1 || true)"
  if [[ -n "${existing_id:-}" ]]; then
    echo "$existing_id"; return 0
  fi

  local new_id; new_id="$(uuidgen)"
  local current_roles; current_roles="$(echo "$app_obj" | jq '.appRoles // []')"

  local tmp_json; tmp_json="$(mktemp)"
  jq -n --argjson roles "$current_roles" --arg id "$new_id" --arg val "$role_value" '
    { appRoles:
      ( $roles + [{
        "allowedMemberTypes": ["Application"],
        "description": "Kafka audience application permission",
        "displayName": $val,
        "id": $id,
        "isEnabled": true,
        "value": $val,
        "origin": "Application"
      }])
    }' > "$tmp_json"
  graph_patch_file "${GRAPH}/applications/${app_obj_id}" "$tmp_json"
  rm -f "$tmp_json"
  echo "$new_id"
}

# Grant audience app role to a client SP (dependency + real grant)
add_and_grant_app_perm(){
  local CLIENT_APP_ID="$1" AUD_APP_ID="$2" APP_ROLE_ID="$3"
  ensure_sp "$CLIENT_APP_ID"; ensure_sp "$AUD_APP_ID"

  # Add dependency to client's manifest (idempotent)
  az ad app permission add --id "$CLIENT_APP_ID" --api "$AUD_APP_ID" \
    --api-permissions "${APP_ROLE_ID}=Role" >/dev/null || true

  # Real grant: appRoleAssignments on the CLIENT's SP
  local CLIENT_SP_OID RESOURCE_SP_OID
  CLIENT_SP_OID="$(az ad sp show --id "$CLIENT_APP_ID" --query id -o tsv)"
  RESOURCE_SP_OID="$(az ad sp show --id "$AUD_APP_ID"  --query id -o tsv)"

  local existing
  existing="$(graph_get "${GRAPH}/servicePrincipals/${CLIENT_SP_OID}/appRoleAssignments" \
     | jq -r --arg rid "$RESOURCE_SP_OID" --arg aid "$APP_ROLE_ID" \
       '.value[]? | select(.resourceId==$rid and .appRoleId==$aid) | .id' | head -n1 || true)"
  if [[ -z "$existing" ]]; then
    local payload
    payload="$(jq -n --arg principalId "$CLIENT_SP_OID" --arg resourceId "$RESOURCE_SP_OID" --arg appRoleId "$APP_ROLE_ID" \
      '{principalId:$principalId, resourceId:$resourceId, appRoleId:$appRoleId}')"
    graph_post_json "${GRAPH}/servicePrincipals/${CLIENT_SP_OID}/appRoleAssignments" "$payload"
  fi
}

# =============================================================================
# Kafka-UI roles helper (Admins + ReadOnly)
# =============================================================================
ensure_ui_app_roles(){
  local ui_appId="$1"
  local app_obj_id; app_obj_id="$(get_app_object_id "$ui_appId")"
  local app_obj;    app_obj="$(graph_get "${GRAPH}/applications/${app_obj_id}")"

  local have; have="$(echo "$app_obj" | jq '.appRoles // []')"

  # Desired roles
  local admin_id read_id
  admin_id="$(echo "$have" | jq -r '.[]? | select(.value=="KafkaUI-Admins" and .isEnabled==true) | .id' | head -n1 || true)"
  read_id="$(echo "$have" | jq -r '.[]? | select(.value=="KafkaUI-ReadOnly" and .isEnabled==true) | .id' | head -n1 || true)"
  [[ -z "${admin_id:-}" || "$admin_id" == "null" ]] && admin_id="$(uuidgen)"
  [[ -z "${read_id:-}"  || "$read_id"  == "null" ]] && read_id="$(uuidgen)"

  local merged
  merged="$(jq -n --argjson have "$have" --arg admin "$admin_id" --arg read "$read_id" '
    def role(id; name; desc):
      {allowedMemberTypes:["User"], description:desc, displayName:name,
       id:id, isEnabled:true, value:name, origin:"Application"};
    {
      appRoles:
        ( ($have | map(select(.value!="KafkaUI-Admins" and .value!="KafkaUI-ReadOnly"))) +
          [ role($admin; "KafkaUI-Admins";   "Admins of Kafka-UI")
          , role($read;  "KafkaUI-ReadOnly"; "Read-only users of Kafka-UI")
          ]
        )
    }')"

  local f; f="$(mktemp)"; echo "$merged" > "$f"
  graph_patch_file "${GRAPH}/applications/${app_obj_id}" "$f"
  rm -f "$f"
}

# =============================================================================
# MAIN
# =============================================================================
echo "== AAD bootstrap for ENV=${ENV}, KV=${KV_NAME}"

# ----------------------------
# 1) Audience (resource) app
# ----------------------------
KAFKA_AUDIENCE_APP_ID="$(get_first_existing_appid "$KAFKA_AUDIENCE_APP_NAME" "$KAFKA_AUDIENCE_APP_NAME_LEGACY")"
if [[ -z "$KAFKA_AUDIENCE_APP_ID" ]]; then
  echo "[CREATE] audience app: $KAFKA_AUDIENCE_APP_NAME"
  KAFKA_AUDIENCE_APP_ID="$(az ad app create \
      --display-name "$KAFKA_AUDIENCE_APP_NAME" \
      --sign-in-audience AzureADMyOrg \
      --enable-access-token-issuance true \
      --query appId -o tsv)"
else
  matched="$KAFKA_AUDIENCE_APP_NAME"
  [[ "$KAFKA_AUDIENCE_APP_ID" == "$(get_appid_by_name "$KAFKA_AUDIENCE_APP_NAME_LEGACY")" ]] && matched="$KAFKA_AUDIENCE_APP_NAME_LEGACY"
  echo "[REUSE] audience app: $matched ($KAFKA_AUDIENCE_APP_ID)"
fi
ensure_sp "$KAFKA_AUDIENCE_APP_ID"

# Expose an API → Application ID URIs
if [[ -n "${KAFKA_AUDIENCE_DNS_URI:-}" ]]; then
  az ad app update --id "$KAFKA_AUDIENCE_APP_ID" \
    --identifier-uris "api://${KAFKA_AUDIENCE_APP_ID}" "$KAFKA_AUDIENCE_DNS_URI" >/dev/null || true
else
  az ad app update --id "$KAFKA_AUDIENCE_APP_ID" \
    --identifier-uris "api://${KAFKA_AUDIENCE_APP_ID}" >/dev/null || true
fi

# Enforce v2 tokens
AUD_APP_OBJ_ID="$(get_app_object_id "$KAFKA_AUDIENCE_APP_ID")"
tmp_v2="$(mktemp)"; echo '{"api":{"requestedAccessTokenVersion":2}}' > "$tmp_v2"
graph_patch_file "${GRAPH}/applications/${AUD_APP_OBJ_ID}" "$tmp_v2"
rm -f "$tmp_v2"

# Upsert audience application role "kafka.access"
AUD_APPROLE_ID="$(upsert_audience_app_role "$KAFKA_AUDIENCE_APP_ID" "$AUDIENCE_APP_ROLE_VALUE")"

# KV notes (ids only)
kv_put "kafka-oidc-audience-app-id-${ENV}" "$KAFKA_AUDIENCE_APP_ID"
kv_put "kafka-oidc-tenant-id-${ENV}"        "$TENANT_ID"

AUDIENCE_SP_OID="$(wait_sp_oid "$KAFKA_AUDIENCE_APP_ID")"

# -----------------------------------
# 2) Kafka-UI app (confidential app)
# -----------------------------------
KAFKA_UI_APP_ID="$(get_appid_by_name "$KAFKA_UI_APP_NAME")"
if [[ -z "$KAFKA_UI_APP_ID" ]]; then
  echo "[CREATE] UI app: $KAFKA_UI_APP_NAME"
  KAFKA_UI_APP_ID="$(az ad app create \
      --display-name "$KAFKA_UI_APP_NAME" \
      --sign-in-audience AzureADMyOrg \
      --web-redirect-uris "$KAFKA_UI_REDIRECT_URI" \
      --enable-id-token-issuance true \
      --enable-access-token-issuance true \
      --query appId -o tsv)"
else
  echo "[REUSE] UI app: $KAFKA_UI_APP_NAME ($KAFKA_UI_APP_ID)"
  az ad app update --id "$KAFKA_UI_APP_ID" \
      --enable-id-token-issuance true \
      --enable-access-token-issuance true \
      --web-redirect-uris "$KAFKA_UI_REDIRECT_URI" >/dev/null || true
fi
ensure_sp "$KAFKA_UI_APP_ID"

# Ensure UI app roles (Admins/ReadOnly)
ensure_ui_app_roles "$KAFKA_UI_APP_ID"

# UI client secret
UI_CLIENT_SECRET="$(az ad app credential reset --id "$KAFKA_UI_APP_ID" \
  --display-name "kui-${ENV}-$(date +%Y%m%d-%H%M%S)" \
  --years 1 --query password -o tsv)"

# Store UI creds in KV
kv_put "kafka-ui-client-id-${ENV}"     "$KAFKA_UI_APP_ID"
kv_put "kafka-ui-client-secret-${ENV}" "$UI_CLIENT_SECRET"

# Give UI the audience permission (dependency + real grant)
add_and_grant_app_perm "$KAFKA_UI_APP_ID" "$KAFKA_AUDIENCE_APP_ID" "$AUD_APPROLE_ID"
UI_SP_OID="$(wait_sp_oid "$KAFKA_UI_APP_ID")"

# ------------------------------
# 3) Lag Exporter (daemon app)
# ------------------------------
LAG_APP_ID="$(get_appid_by_name "$LAG_EXPORTER_APP_NAME")"
if [[ -z "$LAG_APP_ID" ]]; then
  echo "[CREATE] lag exporter app: $LAG_EXPORTER_APP_NAME"
  LAG_APP_ID="$(az ad app create \
      --display-name "$LAG_EXPORTER_APP_NAME" \
      --sign-in-audience AzureADMyOrg \
      --enable-access-token-issuance true \
      --query appId -o tsv)"
else
  echo "[REUSE] lag exporter app: $LAG_EXPORTER_APP_NAME ($LAG_APP_ID)"
fi
ensure_sp "$LAG_APP_ID"

LAG_CLIENT_SECRET="$(az ad app credential reset --id "$LAG_APP_ID" \
  --display-name "lag-${ENV}-$(date +%Y%m%d-%H%M%S)" \
  --years 1 --query password -o tsv)"

kv_put "kafka-lag-client-id-${ENV}"     "$LAG_APP_ID"
kv_put "kafka-lag-client-secret-${ENV}" "$LAG_CLIENT_SECRET"

add_and_grant_app_perm "$LAG_APP_ID" "$KAFKA_AUDIENCE_APP_ID" "$AUD_APPROLE_ID"
LAG_SP_OID="$(wait_sp_oid "$LAG_APP_ID")"

# --------------------------------
# 4) Schema Registry (daemon app)
# --------------------------------
SCHEMA_APP_ID="$(get_appid_by_name "$SCHEMA_REGISTRY_APP_NAME")"
if [[ -z "$SCHEMA_APP_ID" ]]; then
  echo "[CREATE] schema registry app: $SCHEMA_REGISTRY_APP_NAME"
  SCHEMA_APP_ID="$(az ad app create \
      --display-name "$SCHEMA_REGISTRY_APP_NAME" \
      --sign-in-audience AzureADMyOrg \
      --enable-access-token-issuance true \
      --query appId -o tsv)"
else
  echo "[REUSE] schema registry app: $SCHEMA_REGISTRY_APP_NAME ($SCHEMA_APP_ID)"
fi
ensure_sp "$SCHEMA_APP_ID"

SCHEMA_CLIENT_SECRET="$(az ad app credential reset --id "$SCHEMA_APP_ID" \
  --display-name "schema-${ENV}-$(date +%Y%m%d-%H%M%S)" \
  --years 1 --query password -o tsv)"

kv_put "kafka-schema-client-id-${ENV}"     "$SCHEMA_APP_ID"
kv_put "kafka-schema-client-secret-${ENV}" "$SCHEMA_CLIENT_SECRET"

add_and_grant_app_perm "$SCHEMA_APP_ID" "$KAFKA_AUDIENCE_APP_ID" "$AUD_APPROLE_ID"
SCHEMA_SP_OID="$(wait_sp_oid "$SCHEMA_APP_ID")"

# --------------------------------
# 5) Optional Generic client app
# --------------------------------
if [[ "${CREATE_GENERIC_CLIENT,,}" == "true" ]]; then
  KAFKA_CLIENT_APP_ID="$(get_appid_by_name "$KAFKA_CLIENT_APP_NAME")"
  if [[ -z "$KAFKA_CLIENT_APP_ID" ]]; then
    echo "[CREATE] generic client app: $KAFKA_CLIENT_APP_NAME"
    KAFKA_CLIENT_APP_ID="$(az ad app create \
        --display-name "$KAFKA_CLIENT_APP_NAME" \
        --sign-in-audience AzureADMyOrg \
        --enable-access-token-issuance true \
        --query appId -o tsv)"
  else
    echo "[REUSE] generic client app: $KAFKA_CLIENT_APP_NAME ($KAFKA_CLIENT_APP_ID)"
  fi
  ensure_sp "$KAFKA_CLIENT_APP_ID"

  KAFKA_CLIENT_SECRET="$(az ad app credential reset --id "$KAFKA_CLIENT_APP_ID" \
    --display-name "kafka-client-${ENV}-$(date +%Y%m%d-%H%M%S)" \
    --years 1 --query password -o tsv)"

  kv_put "${KAFKA_CLIENT_APP_NAME}-id" "$KAFKA_CLIENT_APP_ID"
  kv_put "${KAFKA_CLIENT_APP_NAME}-secret" "$KAFKA_CLIENT_SECRET"

  add_and_grant_app_perm "$KAFKA_CLIENT_APP_ID" "$KAFKA_AUDIENCE_APP_ID" "$AUD_APPROLE_ID"
  KCLIENT_SP_OID="$(wait_sp_oid "$KAFKA_CLIENT_APP_ID")"
fi

# =============================================================================
# Done
# =============================================================================
cat <<EOF

OK] AAD bootstrap complete for ENV=${ENV}

Audience app: ${KAFKA_AUDIENCE_APP_NAME}
  - appId=${KAFKA_AUDIENCE_APP_ID}
  - Application ID URIs:
      - api://${KAFKA_AUDIENCE_APP_ID}
$( [[ -n "${KAFKA_AUDIENCE_DNS_URI:-}" ]] && echo "      - ${KAFKA_AUDIENCE_DNS_URI}" )
  - requestedAccessTokenVersion: v2
  - appRole (application): ${AUDIENCE_APP_ROLE_VALUE} (id=${AUD_APPROLE_ID})
  - SP OID: ${AUDIENCE_SP_OID}

Kafka-UI app: ${KAFKA_UI_APP_NAME}
  - app roles ensured: KafkaUI-Admins, KafkaUI-ReadOnly
  - client secret rotated and stored in KV

Key Vault '${KV_NAME}' updated with IDs/secrets for UI / Lag / Schema $( [[ "${CREATE_GENERIC_CLIENT,,}" == "true" ]] && echo "/ Generic" ).

Grants (application role: \${AUDIENCE_APP_ROLE_VALUE}):
  - ${KAFKA_UI_APP_NAME}        (SP OID: ${UI_SP_OID})
  - ${LAG_EXPORTER_APP_NAME}    (SP OID: ${LAG_SP_OID})
  - ${SCHEMA_REGISTRY_APP_NAME} (SP OID: ${SCHEMA_SP_OID})
$( if [[ "${CREATE_GENERIC_CLIENT,,}" == "true" ]]; then echo "  - ${KAFKA_CLIENT_APP_NAME}      (SP OID: ${KCLIENT_SP_OID})"; fi )

Clients request tokens with:
  token_endpoint = https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token
  scope          = $( [[ -n "${KAFKA_AUDIENCE_DNS_URI:-}" ]] && echo "${KAFKA_AUDIENCE_DNS_URI}/.default" || echo "api://${KAFKA_AUDIENCE_APP_ID}/.default" )

EOF
