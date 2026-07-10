FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ansible curl ca-certificates jq openssh-client git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY . /workspace/

RUN chmod +x setup.sh verify.sh teardown.sh scripts/*.sh chaos/*.sh chaos/lib/*.sh 2>/dev/null || true

# Run setup on target VM via SSH, not inside this container:
#   docker build -t chaos-k8s-deployer docker/
#   docker run --rm -it -v ~/.ssh:/root/.ssh chaos-k8s-deployer \
#     ssh user@vm 'git clone ... && cd chaos-k8s && ./setup.sh'

CMD ["bash", "-c", "echo 'Copy repo to Ubuntu 22.04 VM and run ./setup.sh on the VM.'"]
