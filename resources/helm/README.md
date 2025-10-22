# Kafka on AKS with Strimzi, Azure AD (OIDC) & Azure Key Vault (TLS)

This repository deploys a Strimzi-powered Kafka cluster on AKS that uses:
- **Azure AD (Entra ID)** for OAuth2 (SASL/OAUTHBEARER)
- **Azure Key Vault + Secrets Store CSI** to supply TLS materials and client credentials
- Optional components: **Kafka-UI** and the Strimzi-managed **Kafka Exporter**

> The chart pulls Key Vault objects via CSI into the `kafka` namespace and a materializer Job creates/upserts normal Kubernetes Secrets used by Strimzi and clients.

---

## 🔐 TLS & Certificates — End‑to‑End Steps

You need **two** Key Vault objects for TLS:

1) **`kafka-tls`** — a single PEM file that contains: **private key + leaf certificate + intermediates** (no root)
   - CSI mounts it as `tls.crtkey.pem`
   - The Job splits it and creates the K8s secret **`kafka-listener-cert`** (`tls.crt`/`tls.key`) used by brokers on the external listener

2) **`kafka-listener-ca`** — **issuer chain only** (intermediates + root, _no leaf, no key_)
   - CSI mounts it as `kafka-listener-ca.pem`
   - The Job creates/updates the K8s secret **`kafka-external-ca`** (`ca.crt`) that clients can use to trust the broker certificate

> If you omit `kafka-listener-ca`, the Job will **derive** a CA chain from the `kafka-tls` fullchain (by dropping the leaf). Providing it explicitly is recommended.

### A) From an existing server cert/key (example: **otest**)

You have these files:
```
intranet-ca2.pem   policy-ca2.pem   root-ca2.pem
kafka.key          kafka.notest.az.vzp.cz_2026-09-26_v2.cer
```

1. **Normalize and verify**
```bash
# Ensure the leaf is PEM
head -1 kafka.notest.az.vzp.cz_2026-09-26_v2.cer
cp kafka.notest.az.vzp.cz_2026-09-26_v2.cer cert-leaf.pem

# Key ↔ cert match (hashes must be identical)
openssl x509 -in cert-leaf.pem -noout -modulus | openssl md5
openssl rsa  -in kafka.key     -noout -modulus | openssl md5

# Optional: show SANs, issuer, validity
openssl x509 -in cert-leaf.pem -noout -subject -issuer -dates
openssl x509 -in cert-leaf.pem -noout -ext subjectAltName
```

2. **Build the two bundles**
```bash
# kafka-tls (key + leaf + INTERMEDIATES ONLY; no root)
cat kafka.key cert-leaf.pem intranet-ca2.pem policy-ca2.pem > tls.crtkey.pem

# kafka-listener-ca (INTERMEDIATES + ROOT; no leaf, no key)
cat intranet-ca2.pem policy-ca2.pem root-ca2.pem > kafka-listener-ca.pem
```

3. **Validate the chain**
```bash
openssl verify -CAfile kafka-listener-ca.pem cert-leaf.pem
# expect: cert-leaf.pem: OK
```

4. **Upload to Azure Key Vault**

_Set these once per environment:_
```bash
export KV_NAME="<your-kv-name>"       # e.g. kv-vzp-otest-we-aks-002
```

- **Option A — Import `kafka-tls` as an AKV certificate** (recommended; AKV keeps a backing secret):
```bash
az keyvault certificate import \
  --vault-name "$KV_NAME" \
  --name kafka-tls \
  --file tls.crtkey.pem
```

- **`kafka-listener-ca` as a secret** (CA chain only):
```bash
az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name kafka-listener-ca \
  --file kafka-listener-ca.pem
```

> Alternatively, you can store both as **secrets**:
> ```bash
> az keyvault secret set --vault-name "$KV_NAME" --name kafka-tls         --file tls.crtkey.pem
> az keyvault secret set --vault-name "$KV_NAME" --name kafka-listener-ca --file kafka-listener-ca.pem
> ```

### B) Creating a new CSR (if you need to request a cert)

1. **Create `kafka_cert.cnf`**
```ini
[req]
distinguished_name = req_distinguished_name
req_extensions = req_ext
prompt = no

[req_distinguished_name]
O  = VZP CR
OU = UICT
CN = kafka.ntest1.az.vzp.cz

[req_ext]
subjectAltName = @alt_names
keyUsage         = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = kafka.ntest1.az.vzp.cz
DNS.2 = kafka-0.ntest1.az.vzp.cz
DNS.3 = kafka-1.ntest1.az.vzp.cz
DNS.4 = kafka-2.ntest1.az.vzp.cz
```

2. **Generate key + CSR**
```bash
openssl genrsa -out kafka.key 2048
openssl req -new -key kafka.key -out kafka.csr -config kafka_cert.cnf

# Sanity: show SANs in CSR
openssl req -noout -text -in kafka.csr | grep -A1 "Subject Alternative Name"
```
3. **Submit `kafka.csr` to your PKI**, receive the signed server cert (PEM). Then follow section **A.2–A.4** above.

---

## 🧰 Chart values to point at your Key Vault

In your `values-<env>.yaml` (e.g., `values-otest.yaml`):
```yaml
azure:
  tenantId: "<TENANT-GUID>"
  keyVaultName: "<your-kv-name>"
  uamiClientId: "<UAMI-clientId>"

tls:
  spcName: kafka-akv-secrets-spc
  k8sSecretName: kafka-listener-cert
  certObjectName: kafka-tls            # reads tls.crtkey.pem from AKV
  caAkvObjectName: kafka-listener-ca   # reads kafka-listener-ca.pem from AKV (optional but recommended)

kafkaExporter:
  oauth:
    k8sSecretName: kafka-lag-exporter-oauth
    jaasKey: sasl-jaas-config
```

The chart will:
- Mount the above via CSI in `kafka` namespace
- Run a Job (SA `tls-writer`) to materialize:
  - `kafka/kafka-listener-cert` (tls.crt/tls.key)
  - `kafka/kafka-external-ca` (ca.crt) — from `kafka-listener-ca` or derived
  - OAuth JAAS secrets for Kafka-UI and Schema Registry in their namespaces, plus the Kafka Lag Exporter JAAS secret in the observability namespace

---

## Verify UAMI
- **User Assigned Managed Identity (UAMI)** used by the AKV CSI provider in AKS (needs read on secrets & certificates).
  Discover it and capture **clientId** (and resourceId if needed):

  ```bash
  az login
  az identity list -g rg-akscluster-$env$-we-002 -o table
  az identity show -g rg-akscluster-$env$-we-002 -n azurekeyvaultsecretsprovider-aks-vzp-$env$-we-002 --query "{clientId:clientId,resourceId:id}"
  example: 
    az identity list -g rg-akscluster-test1-we-002 -o table
    az identity show -g rg-akscluster-test1-we-002 -n azurekeyvaultsecretsprovider-aks-vzp-test1-we-002 --query "{clientId:clientId,resourceId:id}"
  ```

## 🚀 Install / Upgrade

**First install** (create namespaces; deploy operator + Kafka only):
```bash
helm upgrade --install kafka . \
  -n kafka --create-namespace \
  -f values.yaml -f values-$env.yaml \
  --set manageNamespace=true \
  --set kafkaUi.enabled=false \
  --set schemaRegistry.enabled=false \
  --set kafkaExporter.enabled=false \
  --wait --wait-for-jobs --timeout 10m
```

**Later upgrades** (enable extras once brokers are healthy):
```bash
helm upgrade --install kafka . \
  -n kafka \
  -f values.yaml -f values-$env.yaml \
  --set manageNamespace=false \
  --set kafkaUi.enabled=true \
  --set schemaRegistry.enabled=true \
  --set kafkaExporter.enabled=true \
  --wait --wait-for-jobs --timeout 10m
```

---

## ✅ Smoke Test

From this repo:
```bash
./scripts/smoke-test.sh --env test1
# Or clean up the test topic & SR subject
./scripts/smoke-test.sh --env test1 --cleanup
```

Environment presets live under `resources/helm/scripts/env/smoke-test-<env>.env`. Use `--env` to load one of them, or `--config` to point at a custom file that exports overrides (e.g., private registry images).

`IMG_KAFKA`, `IMG_CURL`, and `ALPINE` accept comma-separated lists. The script tries each candidate until one pulls successfully, so you can prefer an internal mirror and keep a public fallback (e.g., `IMG_KAFKA="myacr.azurecr.io/cp-kafka:7.9.0,quay.io/strimzi/kafka:0.39.0-kafka-3.7.0"`).

Environment presets live under `scripts/env/smoke-test-<env>.env` (dev1, test1, stage, prod). Use `--env` to load them or `--config <file>` for custom overrides (e.g., pointing `IMG_KAFKA` at an internal registry).

The script validates:
- Internal & external bootstrap reachability and OAuth authN/Z
- Produce/consume
- Schema Registry subject creation
- Kafka Lag Exporter metrics (if enabled)
- Per-broker headless DNS resolution

---

## 🔄 Certificate Rotation

1. Prepare new files and rebuild:
```bash
# Replace with new cert/key and CA files, then:
cat kafka.key NEW-cert-leaf.pem intranet-ca2.pem policy-ca2.pem > tls.crtkey.pem
cat intranet-ca2.pem policy-ca2.pem root-ca2.pem > kafka-listener-ca.pem
openssl verify -CAfile kafka-listener-ca.pem NEW-cert-leaf.pem
```

2. Upload to AKV (same object names: `kafka-tls`, `kafka-listener-ca`).  
3. Run `helm upgrade` (the Job detects changes and updates secrets).  
4. Strimzi rolls the external listener with the new certs.

---

## 🧪 Troubleshooting

- **CSI mount errors (SecretNotFound / Forbidden)**  
  - Verify Key Vault names and object names in `values-<env>.yaml`.
  - Confirm the UAMI has **get/list** on **secrets** (and certificates, if you used certificate import).

- **Materializer Job cannot create secrets**  
  - Check `tls-writer` **Role/RoleBinding** in `kafka`, `kafka-ui`, `schema-registry`, `observability`.
  - `kubectl -n kafka get job,pod -l job-name=akv-secrets-job -o wide`
  - `kubectl -n kafka logs job/akv-secrets-job`

---

## 📈 Azure Monitor managed Prometheus (optional)

- The standalone Kafka Lag Exporter Service (`kafka-lag-exporter` in the `observability` namespace by default) already carries `prometheus.io/*` annotations (`port: 9999`, `path: /metrics`). AMA will scrape it automatically if your cluster-wide config honours those annotations.
- If you also want broker JMX metrics in Prometheus, create a headless Service pointing at the Kafka pods with the same annotations (example shown earlier with `<cluster>-kafka-broker-metrics`).
- For reference, the chart can drop a reminder ConfigMap when `kafkaExporter.amaScrape.enabled=true`—it simply documents the annotated Service. You still manage `ama-metrics-prometheus-config` yourself.
