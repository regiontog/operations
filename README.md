# Bootstrap local cluster

```bash
$ minikube start --driver docker # Start k8s cluster
$ task git-serve & # Serve the local git repo in the background (required for local development)
$ task bootstrap -- local
```

# Troubleshooting

If istio-cni pod fails with a message like `2025-03-05T13:21:48.924349Z    error    cni-agent    Command error: xtables parameter problem: ip6tables-restore: unable to initialize table 'nat'` this was caused by a missing kernel module in the minikube qemu vm, presumably because minikube does not support ipv6. Can be fixed by using the docker driver for minikube and ensuring that the host has all istio module requirements(https://istio.io/latest/docs/ops/deployment/platform-requirements/)
