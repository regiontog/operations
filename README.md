# Development tools required

```bash
mise install
```

System dependencies outside mise: Docker and jq.

# Bootstrap a cluster

```bash
# Optionally start a local development cluster
$ task create-cluster

# Bootstrap the current kubectl context with clusters/dev.cluster.yaml
$ task bootstrap -- dev

# Push the repo snapshot and refresh image, then hard-refresh Argo CD apps
$ task refresh -- dev
```

## Private cluster access

The development overlay installs a WireGuard VPN for laptop access, PowerDNS for
private DNS, and a fixed ClusterIP service in front of the Istio ingress gateway.
The laptop peer is intentionally split-tunnel only:

- `10.96.53.53/32` routes to the PowerDNS recursor.
- `10.96.80.80/32` routes to the private Istio ingress service.

The PowerDNS recursor forwards `dev.internal` to the in-cluster authoritative
PowerDNS server and forwards other queries to Cloudflare DNS.

After Argo CD has synced the WireGuard resources, fetch the generated laptop
configuration with:

```bash
kubectl -n wireguard get secret laptop-vpn-peer-configs \
  -o jsonpath='{.data.alan-laptop}' | base64 -d
```

For the local k0s Docker cluster, `task create-cluster` publishes UDP NodePort
`31820` on the host and the generated WireGuard endpoint is `127.0.0.1:31820`.
For a remote cluster, change `spec.externalAddress` in
`apps/wireguard-access/overlays/dev/wireguard.yaml` to the node or load balancer
address reachable from the laptop. Also replace the development PowerDNS API key
in `apps/private-dns/overlays/dev/secret.yaml` before using this outside a local
cluster.

The cluster-manager namespace contains the bootstrap service account and the
registry used by bootstrap and refresh. The registry currently assumes a
single-node cluster. The host pushes to `127.0.0.1:5000` through `kubectl
port-forward`, and the node pulls the same image from `localhost:5000` because
the registry pod uses host networking. This can work for local or remote
single-node clusters, but multi-node clusters will need a stable registry
endpoint and container runtime trust/configuration on each node.

# Troubleshooting

If istio-cni pod fails with a message like `2025-03-05T13:21:48.924349Z    error    cni-agent    Command error: xtables parameter problem: ip6tables-restore: unable to initialize table 'nat'` this was caused by a missing kernel module in the minikube qemu vm, presumably because minikube does not support ipv6. Can be fixed by using the docker driver for minikube and ensuring that the host has all istio module requirements(https://istio.io/latest/docs/ops/deployment/platform-requirements/)
