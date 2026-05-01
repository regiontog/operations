#!/bin/sh
set -eu

cluster="${1:-dev}"
context="${BOOTSTRAP_CONTEXT:-$(kubectl config current-context)}"
namespace="${BOOTSTRAP_NAMESPACE:-bootstrap-system}"
registry_port="${BOOTSTRAP_REGISTRY_PORT:-5000}"
image_name="${BOOTSTRAP_IMAGE_NAME:-operations-bootstrap}"
tag="${BOOTSTRAP_IMAGE_TAG:-$(date +%Y%m%d%H%M%S)}"
job_name="${BOOTSTRAP_JOB_NAME:-operations-bootstrap}"
job_timeout_seconds="${BOOTSTRAP_JOB_TIMEOUT_SECONDS:-600}"

image="localhost:${registry_port}/${image_name}:${tag}"
push_image="127.0.0.1:${registry_port}/${image_name}:${tag}"
port_forward_log="${BOOTSTRAP_PORT_FORWARD_LOG:-${TMPDIR:-/tmp}/operations-bootstrap-registry-port-forward.log}"
port_forward_pid=""
logs_pid=""

start_port_forward() {
  kubectl --context "${context}" -n "${namespace}" port-forward --address 127.0.0.1 svc/operations-bootstrap-registry "${registry_port}:5000" >"${port_forward_log}" 2>&1 &
  port_forward_pid="$!"
}

stop_port_forward() {
  if [ -n "${port_forward_pid}" ]; then
    kill "${port_forward_pid}" 2>/dev/null || true
    wait "${port_forward_pid}" 2>/dev/null || true
    port_forward_pid=""
  fi
}

stop_log_follow() {
  if [ -n "${logs_pid}" ]; then
    kill "${logs_pid}" 2>/dev/null || true
    wait "${logs_pid}" 2>/dev/null || true
    logs_pid=""
  fi
}

cleanup() {
  stop_log_follow
  stop_port_forward
}
trap cleanup EXIT INT TERM

echo "Using kube context: ${context}"
echo "Using bootstrap image: ${image}"
echo "Using bootstrap push endpoint: ${push_image}"

kubectl --context "${context}" apply --kustomize apps/cluster-bootstrap/base
kubectl --context "${context}" apply --kustomize apps/registry/base

docker build -f apps/cluster-bootstrap/Dockerfile -t "${image}" .
docker tag "${image}" "${push_image}"

kubectl --context "${context}" -n "${namespace}" rollout status deployment/operations-bootstrap-registry --timeout=120s
start_port_forward

attempt=1
while ! docker push "${push_image}"; do
  if [ "${attempt}" -ge 60 ]; then
    echo "Timed out pushing bootstrap image to ${image}" >&2
    cat "${port_forward_log}" >&2
    exit 1
  fi
  echo "Bootstrap image push failed; restarting registry port-forward" >&2
  stop_port_forward
  start_port_forward
  attempt=$((attempt + 1))
  sleep 1
done
stop_port_forward

kubectl --context "${context}" -n "${namespace}" delete job "${job_name}" --ignore-not-found=true
kubectl --context "${context}" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${namespace}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: operations-bootstrap
      containers:
        - name: bootstrap
          image: ${image}
          imagePullPolicy: Always
          args:
            - ${cluster}
EOF
kubectl --context "${context}" -n "${namespace}" wait --for=create --timeout=60s "pod" -l "job-name=${job_name}"
