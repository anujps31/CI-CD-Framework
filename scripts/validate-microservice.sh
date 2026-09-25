#!/usr/bin/env bash
set -euo pipefail
# Confirm the selected microservice can be built before it is sent to the cluster.
service_dir="${1:?service directory is required}" # Example: microservices/orders-api.
command -v docker >/dev/null || { echo 'docker is required'; exit 1; }
docker build --file "${service_dir}/Dockerfile" "${service_dir}"
