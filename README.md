# Development tools required

```bash
cargo install argocd-webhook-trigger
cargo install watchexec-cli
mise install
```

System dependencies: Docker, curl, and jq.

# Bootstrap a cluster

```bash
# Optionally start a local development cluster
$ task create-cluster

# Bootstrap the current kubectl context with clusters/dev.cluster.yaml
$ task bootstrap -- dev

# Refresh argocd apps on local commit in the background (so we don't have to wait 3 minutes)
$ task refresh &
```

The bootstrap image registry currently assumes a single-node cluster. The host
pushes to `localhost:5000` through `kubectl port-forward`, and the node pulls the
same image from `localhost:5000` because the registry pod uses host networking.
This can work for local or remote single-node clusters, but multi-node clusters
will need a stable registry endpoint and container runtime trust/configuration on
each node.

# Troubleshooting

If istio-cni pod fails with a message like `2025-03-05T13:21:48.924349Z    error    cni-agent    Command error: xtables parameter problem: ip6tables-restore: unable to initialize table 'nat'` this was caused by a missing kernel module in the minikube qemu vm, presumably because minikube does not support ipv6. Can be fixed by using the docker driver for minikube and ensuring that the host has all istio module requirements(https://istio.io/latest/docs/ops/deployment/platform-requirements/)
