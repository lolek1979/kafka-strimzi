# Script run examples

## AAD bootstrap (`aad-kafka-bootstrap.sh`)

```bash
# dev1
ENV=dev1 \
KAFKA_AUDIENCE_DNS_URI="https://kafka.ndev1.az.vzp.cz" \
./resources/helm/scripts/aad-kafka-bootstrap.sh

# test1
ENV=test1 \
KAFKA_AUDIENCE_DNS_URI="https://kafka.ntest1.az.vzp.cz" \
./resources/helm/scripts/aad-kafka-bootstrap.sh

# stage
ENV=stage \
KAFKA_AUDIENCE_DNS_URI="https://kafka.nstage.az.vzp.cz" \
./resources/helm/scripts/aad-kafka-bootstrap.sh

# prod
ENV=prod \
KAFKA_AUDIENCE_DNS_URI="https://kafka.nprod.az.vzp.cz" \
./resources/helm/scripts/aad-kafka-bootstrap.sh
```

## Smoke test (`smoke-test.sh`)

Environment presets live under `resources/helm/scripts/env/smoke-test-<env>.env`. Use `--env` to load one of them, or `--config` to point at a custom file that exports overrides (e.g., private registry images).

`IMG_KAFKA`, `IMG_CURL`, and `ALPINE` can list multiple images separated by commas. The script tests each in order and uses the first one that pulls successfully—perfect for trying your ACR mirror before falling back to the public registry.

```bash
# Run smoke test against test1
./resources/helm/scripts/smoke-test.sh --env test1

# Clean up test topic/subject afterwards
./resources/helm/scripts/smoke-test.sh --env test1 --cleanup

# Custom registry example
cat > /tmp/smoke-custom.env <<'EOF'
IMG_KAFKA=myacr.azurecr.io/cp-kafka:7.9.0
IMG_CURL=myacr.azurecr.io/curl:8.5.0
EOF
./resources/helm/scripts/smoke-test.sh --config /tmp/smoke-custom.env
```
