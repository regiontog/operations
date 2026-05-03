#!/bin/sh
set -eu

cluster="${1:-${REFRESH_CLUSTER:-dev}}"
repo_branch="${REFRESH_REPO_BRANCH:-main}"
forgejo_account_secret="${REFRESH_FORGEJO_ACCOUNT_SECRET:-forgejo-operations}"

cd /workspace

repo_url="$(kubectl -n argocd get appdecision "${cluster}" -o jsonpath='{.status.decisions[0].repoURL}')"
if [ -z "${repo_url}" ]; then
  echo "Could not read repo URL from AppDecision: ${cluster}" >&2
  exit 1
fi

forgejo_username="$(kubectl -n forgejo get secret "${forgejo_account_secret}" -o jsonpath='{.data.username}' | base64 -d)"
forgejo_password="$(kubectl -n forgejo get secret "${forgejo_account_secret}" -o jsonpath='{.data.password}' | base64 -d)"

echo "Pushing operations repository snapshot to Forgejo"
rm -rf .git
git init
git config user.name "Operations Refresh"
git config user.email "refresh@localhost"
git add -A
git commit -m "Refresh operations snapshot"

askpass=""
cleanup_credentials() {
  if [ -n "${askpass}" ]; then
    rm -f "${askpass}"
  fi
}
trap cleanup_credentials EXIT

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

git remote add forgejo-refresh "${repo_url}"
GIT_ASKPASS="${askpass}" \
  GIT_TERMINAL_PROMPT=0 \
  GIT_USERNAME="${forgejo_username}" \
  GIT_PASSWORD="${forgejo_password}" \
  git push --force forgejo-refresh "HEAD:${repo_branch}"
rm -f "${askpass}"
askpass=""

kubectl -n argocd annotate applications --all argocd.argoproj.io/refresh=hard --overwrite

echo "Refresh complete"
