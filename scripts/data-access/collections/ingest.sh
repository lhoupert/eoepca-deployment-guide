#!/bin/bash

DEFAULT_COLLECTIONS_FILE="./collections.json"
DEFAULT_ITEMS_FILE="./items.json"
# The loader runs from the pgstac image the deployment uses: keep in step with pgstacBootstrap.image in ../eoapi/values-template.yaml
PGSTAC_IMAGE="${PGSTAC_IMAGE:-ghcr.io/stac-utils/pgstac-pypgstac:v0.10.2@sha256:71bb2db9277df41bcd29e2f7e90a37ffb17f3c3b73266309b2dd29713d77b321}"

if [ "$#" -eq 2 ]; then
    EOAPI_COLLECTIONS_FILE="$1"
    EOAPI_ITEMS_FILE="$2"
else
    EOAPI_COLLECTIONS_FILE="$DEFAULT_COLLECTIONS_FILE"
    EOAPI_ITEMS_FILE="$DEFAULT_ITEMS_FILE"
    echo "No specific files provided. Using defaults:"
    echo "  Collections file: $EOAPI_COLLECTIONS_FILE"
    echo "  Items file: $EOAPI_ITEMS_FILE"
fi

NAMESPACES=("default" "eoapi" "data-access")
EOAPI_POD_STAC=""
FOUND_NAMESPACE=""

for NS in "${NAMESPACES[@]}"; do
    EOAPI_POD_STAC=$(kubectl get pods -n "$NS" -l app=eoapi-stac -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
    if [ -n "$EOAPI_POD_STAC" ]; then
        FOUND_NAMESPACE="$NS"
        echo "Found eoapi-stac pod: $EOAPI_POD_STAC in namespace: $FOUND_NAMESPACE"
        break
    fi
done

if [ -z "$EOAPI_POD_STAC" ]; then
    echo "Could not determine eoapi-stac pod."
    exit 1
fi

for FILE in "$EOAPI_COLLECTIONS_FILE" "$EOAPI_ITEMS_FILE"; do
    if [ ! -f "$FILE" ]; then
        echo "File not found: $FILE. You may set them via the EOAPI_COLLECTIONS_FILE and EOAPI_ITEMS_FILE environment variables."
        exit 1
    fi
done

# The loader pod gets the same database credentials as the STAC API pod
DSN_ENV=$(kubectl get pod -n "$FOUND_NAMESPACE" "$EOAPI_POD_STAC" -o jsonpath='{.spec.containers[0].env[?(@.name=="PGADMIN_URI")]}')
if [ -z "$DSN_ENV" ]; then
    echo "No PGADMIN_URI on pod $EOAPI_POD_STAC."
    exit 1
fi

LOADER_POD="pypgstac-loader"
echo "Starting loader pod $LOADER_POD in namespace $FOUND_NAMESPACE..."
trap 'kubectl delete pod -n "$FOUND_NAMESPACE" "$LOADER_POD" --ignore-not-found --grace-period=1 >/dev/null' EXIT
if ! kubectl run "$LOADER_POD" -n "$FOUND_NAMESPACE" --restart=Never --image="$PGSTAC_IMAGE" \
    --overrides="{\"spec\":{\"containers\":[{\"name\":\"$LOADER_POD\",\"image\":\"$PGSTAC_IMAGE\",\"command\":[\"sleep\",\"3600\"],\"env\":[$DSN_ENV]}]}}" ||
    ! kubectl wait -n "$FOUND_NAMESPACE" --for=condition=Ready "pod/$LOADER_POD" --timeout=300s; then
    echo "Failed to start the loader pod."
    exit 1
fi

echo "Copying files to pod..."
echo "Using collections file: $EOAPI_COLLECTIONS_FILE"
echo "Using items file: $EOAPI_ITEMS_FILE"
kubectl cp "$EOAPI_COLLECTIONS_FILE" "$FOUND_NAMESPACE/$LOADER_POD":/tmp/collections.json
kubectl cp "$EOAPI_ITEMS_FILE" "$FOUND_NAMESPACE/$LOADER_POD":/tmp/items.json

echo "Loading collections..."
if ! kubectl exec -n "$FOUND_NAMESPACE" "$LOADER_POD" -- bash -c 'pypgstac load collections /tmp/collections.json --dsn "$PGADMIN_URI" --method insert_ignore'; then
    echo "Failed to load collections."
    exit 1
fi

echo "Loading items..."
if ! kubectl exec -n "$FOUND_NAMESPACE" "$LOADER_POD" -- bash -c 'pypgstac load items /tmp/items.json --dsn "$PGADMIN_URI" --method insert_ignore'; then
    echo "Failed to load items."
    exit 1
fi

echo "Ingestion complete."
