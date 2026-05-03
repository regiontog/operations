#!/bin/sh
set -eu

cluster="${1:-${BOOTSTRAP_CLUSTER:-dev}}"
cluster_file="clusters/${cluster}.cluster.yaml"
repo_branch="${BOOTSTRAP_REPO_BRANCH:-main}"
forgejo_account_secret="${BOOTSTRAP_FORGEJO_ACCOUNT_SECRET:-forgejo-operations}"

cd /workspace

if [ ! -f "${cluster_file}" ]; then
  echo "Cluster file not found: ${cluster_file}" >&2
  exit 1
fi

echo "Installing Argo CD and bootstrap CRDs"
kubectl --server-side=true apply --kustomize apps/argo-cd/base --force-conflicts

echo "Waiting for Argo CD and AppDecision CRDs"
kubectl wait --for=create --timeout=120s crd/applicationsets.argoproj.io
kubectl wait --for=condition=established --timeout=120s crd/applicationsets.argoproj.io
kubectl wait --for=create --timeout=120s crd/appdecisions.app-decisions.example.com
kubectl wait --for=condition=established --timeout=120s crd/appdecisions.app-decisions.example.com

echo "Waiting for Argo CD controllers"
kubectl -n argocd wait --for=condition=available --timeout=180s deployment/argocd-applicationset-controller
kubectl -n argocd wait --for=condition=available --timeout=180s deployment/argocd-repo-server

echo "Applying cluster decision: ${cluster_file}"
kubectl --server-side=true apply -f "${cluster_file}" --force-conflicts

echo "Deleting legacy cluster-bootstrap ApplicationSet"
kubectl -n argocd delete applicationset cluster-bootstrap --ignore-not-found=true || true

echo "Applying root ApplicationSets"
find app-of-apps -name '*.as.yaml' -type f | sort | while IFS= read -r appset; do
  echo "Applying ${appset}"
  kubectl -n argocd --server-side=true apply -f "${appset}" --force-conflicts
done

kubectl delete namespace bootstrap-system --ignore-not-found=true || true

echo "Waiting for Forgejo"
kubectl -n forgejo wait --for=create --timeout=300s service/forgejo-http
kubectl -n forgejo wait --for=create --timeout=300s deployment/forgejo
kubectl -n forgejo rollout status deployment/forgejo --timeout=300s

repo_url="$(kubectl -n argocd get appdecision "${cluster}" -o jsonpath='{.status.decisions[0].repoURL}')"
repo_without_scheme="${repo_url#*://}"
repo_path="${repo_without_scheme#*/}"
repo_owner="${repo_path%%/*}"

if [ -z "${repo_owner}" ] || [ "${repo_owner}" = "${repo_path}" ]; then
  echo "Could not infer Forgejo repository owner from repo URL: ${repo_url}" >&2
  exit 1
fi

if kubectl -n forgejo get secret "${forgejo_account_secret}" >/dev/null 2>&1; then
  forgejo_username="$(kubectl -n forgejo get secret "${forgejo_account_secret}" -o jsonpath='{.data.username}' | base64 -d)"
  forgejo_password="$(kubectl -n forgejo get secret "${forgejo_account_secret}" -o jsonpath='{.data.password}' | base64 -d)"
else
  forgejo_username="${repo_owner}"
  forgejo_password="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
  kubectl -n forgejo create secret generic "${forgejo_account_secret}" \
    --from-literal=username="${forgejo_username}" \
    --from-literal=password="${forgejo_password}" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -
fi

if [ "${forgejo_username}" != "${repo_owner}" ]; then
  echo "Forgejo account secret ${forgejo_account_secret} has username ${forgejo_username}, but repo owner is ${repo_owner}" >&2
  exit 1
fi

echo "Reconciling persistent Forgejo account ${forgejo_username}"
if kubectl -n forgejo exec deploy/forgejo -c forgejo -- \
  /usr/local/bin/gitea admin user create \
    --config /data/gitea/conf/app.ini \
    --username "${forgejo_username}" \
    --password "${forgejo_password}" \
    --email "${forgejo_username}@local.domain" \
    --must-change-password=false; then
  echo "Created Forgejo account ${forgejo_username}"
else
  kubectl -n forgejo exec deploy/forgejo -c forgejo -- \
    /usr/local/bin/gitea admin user change-password \
      --config /data/gitea/conf/app.ini \
      --username "${forgejo_username}" \
      --password "${forgejo_password}"
fi
kubectl -n forgejo exec deploy/forgejo -c forgejo -- \
  /usr/local/bin/gitea admin user must-change-password \
    --config /data/gitea/conf/app.ini \
    --unset \
    "${forgejo_username}"

echo "Configuring Argo CD repository credentials for ${repo_url}"
kubectl -n argocd create secret generic forgejo-repo-creds \
  --from-literal=type=git \
  --from-literal=url="${repo_url}" \
  --from-literal=username="${forgejo_username}" \
  --from-literal=password="${forgejo_password}" \
  --dry-run=client \
  -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml \
  | kubectl apply -f -

echo "Pushing operations repository snapshot to Forgejo"
rm -rf .git
git init
git config user.name "Operations Bootstrap"
git config user.email "bootstrap@localhost"
git add -A
git commit -m "Bootstrap operations snapshot"

askpass="$(mktemp)"
cat > "${askpass}" <<'EOF'
#!/bin/sh
case "${1}" in
  *Username*) printf '%s\n' "${GIT_USERNAME}" ;;
  *Password*) printf '%s\n' "${GIT_PASSWORD}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${askpass}"

git remote add forgejo-bootstrap "${repo_url}"
GIT_ASKPASS="${askpass}" \
  GIT_TERMINAL_PROMPT=0 \
  GIT_USERNAME="${forgejo_username}" \
  GIT_PASSWORD="${forgejo_password}" \
  git push --force forgejo-bootstrap "HEAD:${repo_branch}"
rm -f "${askpass}"

kubectl -n argocd annotate applications --all argocd.argoproj.io/refresh=hard --overwrite || true

echo "Bootstrap complete"
