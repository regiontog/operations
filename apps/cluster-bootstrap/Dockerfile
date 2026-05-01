FROM alpine/k8s:1.35.3

WORKDIR /workspace

COPY . /workspace

ENTRYPOINT ["/bin/sh", "/workspace/apps/cluster-bootstrap/bin/bootstrap.sh"]
