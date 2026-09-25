#!/usr/bin/env bash
# Runs SonarQube Community Build with PostgreSQL on this VM in Docker. Both containers use
# --restart unless-stopped, so they come back by themselves after a reboot. The web port is
# bound to 127.0.0.1 only: the pipeline agent on this VM reaches it as http://localhost:9000,
# and people reach the UI through an SSH tunnel. Safe to re-run.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

sonar_image="${SONAR_IMAGE:-sonarqube:community}"
pg_image="${PG_IMAGE:-postgres:16}"
state_dir=/opt/sonarqube
# cleanup-agent-workspace.sh skips anything with this label when it prunes Docker.
keep_label="com.dataplatform.keep=true"

# Kernel settings SonarQube's embedded Elasticsearch needs; persisted across reboots.
cat >/etc/sysctl.d/99-sonarqube.conf <<'SYSCTL'
vm.max_map_count=524288
fs.file-max=131072
SYSCTL
sysctl --system >/dev/null

# The database password is generated once and kept root-only on the VM.
install -d -m 0700 "$state_dir"
if [[ ! -s "$state_dir/db-password" ]]; then
  (umask 077 && openssl rand -hex 24 >"$state_dir/db-password")
fi
db_password="$(cat "$state_dir/db-password")"

docker network inspect sonarnet >/dev/null 2>&1 || docker network create --label "$keep_label" sonarnet >/dev/null
for volume in sonar_pgdata sonar_data sonar_extensions sonar_logs; do
  docker volume inspect "$volume" >/dev/null 2>&1 || docker volume create --label "$keep_label" "$volume" >/dev/null
done

if ! docker container inspect sonar-db >/dev/null 2>&1; then
  docker run -d --name sonar-db --network sonarnet --restart unless-stopped --label "$keep_label" \
    -e POSTGRES_USER=sonar -e POSTGRES_PASSWORD="$db_password" -e POSTGRES_DB=sonar \
    -v sonar_pgdata:/var/lib/postgresql/data \
    "$pg_image" >/dev/null
fi

if ! docker container inspect sonarqube >/dev/null 2>&1; then
  docker run -d --name sonarqube --network sonarnet --restart unless-stopped --label "$keep_label" \
    -p 127.0.0.1:9000:9000 \
    -e SONAR_JDBC_URL=jdbc:postgresql://sonar-db:5432/sonar \
    -e SONAR_JDBC_USERNAME=sonar -e SONAR_JDBC_PASSWORD="$db_password" \
    --ulimit nofile=131072:131072 --ulimit nproc=8192:8192 \
    -v sonar_data:/opt/sonarqube/data \
    -v sonar_extensions:/opt/sonarqube/extensions \
    -v sonar_logs:/opt/sonarqube/logs \
    "$sonar_image" >/dev/null
fi

echo "Waiting for SonarQube to start (first start takes 2-3 minutes)..."
for _ in $(seq 1 60); do
  status="$(curl -fsS http://127.0.0.1:9000/api/system/status 2>/dev/null | jq -r .status 2>/dev/null || true)"
  if [[ "$status" == "UP" ]]; then
    echo "SonarQube is UP at http://127.0.0.1:9000"
    exit 0
  fi
  sleep 10
done
echo "SonarQube did not report UP within 10 minutes. Check: sudo docker logs sonarqube" >&2
exit 1