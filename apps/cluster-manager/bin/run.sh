#!/bin/sh
set -eu

mode="${1:-}"
if [ -z "${mode}" ]; then
  echo "Usage: $0 <bootstrap|refresh> [cluster]" >&2
  exit 1
fi
shift

cluster="${1:-dev}"

case "${mode}" in
  bootstrap)
    context="${BOOTSTRAP_CONTEXT:-$(kubectl config current-context)}"
    namespace="${BOOTSTRAP_NAMESPACE:-cluster-manager}"
    registry_port="${BOOTSTRAP_REGISTRY_PORT:-5000}"
    image_name="${BOOTSTRAP_IMAGE_NAME:-bootstrap}"
    tag="${BOOTSTRAP_IMAGE_TAG:-$(date +%Y%m%d%H%M%S)}"
    job_name="${BOOTSTRAP_JOB_NAME:-bootstrap}"
    port_forward_log="${BOOTSTRAP_PORT_FORWARD_LOG:-${TMPDIR:-/tmp}/bootstrap-registry-port-forward.log}"
    job_script="/workspace/apps/cluster-manager/bin/bootstrap.sh"
    provision_resources="true"
    ;;
  refresh)
    context="${REFRESH_CONTEXT:-$(kubectl config current-context)}"
    namespace="${REFRESH_NAMESPACE:-cluster-manager}"
    registry_port="${REFRESH_REGISTRY_PORT:-5000}"
    image_name="${REFRESH_IMAGE_NAME:-refresh}"
    tag="${REFRESH_IMAGE_TAG:-$(date +%Y%m%d%H%M%S)}"
    job_name="${REFRESH_JOB_NAME:-refresh}"
    port_forward_log="${REFRESH_PORT_FORWARD_LOG:-${TMPDIR:-/tmp}/refresh-registry-port-forward.log}"
    job_script="/workspace/apps/cluster-manager/bin/refresh.sh"
    provision_resources="false"
    ;;
  *)
    echo "Unknown cluster-manager mode: ${mode}" >&2
    echo "Usage: $0 <bootstrap|refresh> [cluster]" >&2
    exit 1
    ;;
esac

image="localhost:${registry_port}/${image_name}:${tag}"
push_image="127.0.0.1:${registry_port}/${image_name}:${tag}"
port_forward_pid=""

start_port_forward() {
  kubectl --context "${context}" -n "${namespace}" port-forward --address 127.0.0.1 svc/registry "${registry_port}:5000" >"${port_forward_log}" 2>&1 &
  port_forward_pid="$!"
}

stop_port_forward() {
  if [ -n "${port_forward_pid}" ]; then
    kill "${port_forward_pid}" 2>/dev/null || true
    wait "${port_forward_pid}" 2>/dev/null || true
    port_forward_pid=""
  fi
}

cleanup() {
  stop_port_forward
}
trap cleanup EXIT INT TERM

cleanup_legacy_resources() {
  if kubectl --context "${context}" get namespace bootstrap-system >/dev/null 2>&1; then
    kubectl --context "${context}" -n bootstrap-system delete deployment operations-bootstrap-registry --ignore-not-found=true || true
    kubectl --context "${context}" -n bootstrap-system wait --for=delete --timeout=60s deployment/operations-bootstrap-registry >/dev/null 2>&1 || true
    kubectl --context "${context}" -n bootstrap-system delete service operations-bootstrap-registry --ignore-not-found=true || true
  fi
  kubectl --context "${context}" delete clusterrolebinding operations-bootstrap-cluster-admin --ignore-not-found=true || true
}

echo "Using kube context: ${context}"
echo "Using ${mode} image: ${image}"
echo "Using ${mode} push endpoint: ${push_image}"

if [ "${provision_resources}" = "true" ]; then
  cleanup_legacy_resources
  kubectl --context "${context}" apply --kustomize apps/cluster-manager/base
  kubectl --context "${context}" apply --kustomize apps/registry/base
  kubectl --context "${context}" -n "${namespace}" rollout status deployment/registry --timeout=120s
fi

docker build -f apps/cluster-manager/Dockerfile -t "${image}" .
docker tag "${image}" "${push_image}"

start_port_forward

attempt=1
while ! docker push "${push_image}"; do
  if [ "${attempt}" -ge 60 ]; then
    echo "Timed out pushing ${mode} image to ${image}" >&2
    cat "${port_forward_log}" >&2
    exit 1
  fi
  echo "${mode} image push failed; restarting registry port-forward" >&2
  stop_port_forward
  start_port_forward
  attempt=$((attempt + 1))
  sleep 1
done
stop_port_forward

kubectl --context "${context}" -n "${namespace}" delete job "${job_name}" --ignore-not-found=true
kubectl --context "${context}" -n "${namespace}" wait --for=delete --timeout=60s "job/${job_name}" >/dev/null 2>&1 || true
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
      serviceAccountName: bootstrap
      containers:
        - name: ${mode}
          image: ${image}
          imagePullPolicy: Always
          command:
            - /bin/sh
            - ${job_script}
          args:
            - ${cluster}
EOF

kubectl --context "${context}" -n "${namespace}" wait --for=create --timeout=60s "pod" -l "job-name=${job_name}"
