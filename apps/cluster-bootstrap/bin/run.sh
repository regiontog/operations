#!/bin/sh
set -eu

cluster="${1:-dev}"
context="${BOOTSTRAP_CONTEXT:-$(kubectl config current-context)}"
namespace="${BOOTSTRAP_NAMESPACE:-bootstrap-system}"
registry_port="${BOOTSTRAP_REGISTRY_PORT:-5000}"
image_name="${BOOTSTRAP_IMAGE_NAME:-operations-bootstrap}"
tag="${BOOTSTRAP_IMAGE_TAG:-}"
job_name="${BOOTSTRAP_JOB_NAME:-operations-bootstrap}"

if [ -z "${tag}" ]; then
  tag="$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    tag="${tag}-dirty-$(date +%Y%m%d%H%M%S)"
  fi
fi

image="localhost:${registry_port}/${image_name}:${tag}"
tmp_job="$(mktemp)"
port_forward_pid=""

cleanup() {
  rm -f "${tmp_job}"
  if [ -n "${port_forward_pid}" ]; then
    kill "${port_forward_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "Using kube context: ${context}"
echo "Using bootstrap image: ${image}"

kubectl --context "${context}" apply --kustomize apps/cluster-bootstrap/base
kubectl --context "${context}" apply --kustomize apps/registry/base

docker build -f apps/cluster-bootstrap/Dockerfile -t "${image}" .

kubectl --context "${context}" -n "${namespace}" rollout status deployment/operations-bootstrap-registry --timeout=120s
kubectl --context "${context}" -n "${namespace}" port-forward svc/operations-bootstrap-registry "${registry_port}:5000" >/tmp/operations-bootstrap-registry-port-forward.log 2>&1 &
port_forward_pid="$!"

for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${registry_port}/v2/" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "${port_forward_pid}" 2>/dev/null; then
    echo "Registry port-forward exited early" >&2
    cat /tmp/operations-bootstrap-registry-port-forward.log >&2
    exit 1
  fi
  sleep 1
done

curl -fsS "http://127.0.0.1:${registry_port}/v2/" >/dev/null
docker push "${image}"

kubectl --context "${context}" -n "${namespace}" delete job "${job_name}" --ignore-not-found=true

cat > "${tmp_job}" <<EOF
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

kubectl --context "${context}" apply -f "${tmp_job}"
kubectl --context "${context}" -n "${namespace}" wait --for=create --timeout=60s "pod" -l "job-name=${job_name}"
kubectl --context "${context}" -n "${namespace}" logs --follow "job/${job_name}" || true
kubectl --context "${context}" -n "${namespace}" wait --for=condition=complete --timeout=10m "job/${job_name}"
