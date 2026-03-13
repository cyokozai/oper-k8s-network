# Open PE Router on Kubernetes Network by Containerlab

## Usage

1. Build DevContainer image
2. Create a Kubernetes cluster using Kind

    ```bash
    kind create cluster --name c9s --config kind/kind-config.yaml
    ```

3. Deploy the Open PE Router on the Kubernetes cluster with Helmfile

    ```bash
    helmfile -f helm/helmfile.yaml apply
    ```

## Components

- [Containerlab](https://containerlab.dev/):  
  A container-based network emulator that allows you to create and manage complex network topologies using containers.
- [Open PE Router](https://openperouter.github.io/):  
  PE routers are used in service provider networks to connect customer edge (CE) devices to the provider's core network. They play a crucial role in routing and forwarding traffic between different customer sites and the provider's network.

```mermaid
graph TB
    subgraph host["ホスト (macOS / OrbStack)"]

        subgraph devcontainer["DevContainer\n(containerlab devcontainer)"]
            clab["clab deploy コマンド"]
            script["scripts/connect-tor.sh\n(nsenter で namespace 操作)"]
        end

        subgraph kind_net["Docker network: kind\n192.168.117.0/24"]
            direction LR
            cp["c9s-control-plane\n192.168.117.4"]
            w1["c9s-worker\n192.168.117.2"]
            w2["c9s-worker2\n192.168.117.3"]
        end

        subgraph clab_net["Docker network: clab-openperouter-lab\n(containerlab mgmt)"]
            tor["tor\n(FRR: ASN 64512)\nclab-openperouter-lab-tor"]
            ca["client-a\n172.16.1.2/24\nclab-openperouter-lab-client-a"]
            cb["client-b\n172.16.2.2/24\nclab-openperouter-lab-client-b"]
        end

        tor -- "eth1 ↔ eth1\n172.16.1.0/24" --- ca
        tor -- "eth2 ↔ eth1\n172.16.2.0/24" --- cb

        subgraph w1_inside["c9s-worker の内部"]
            openbr0["openbr0\n(bridge: 10.100.0.0/24)"]
            pe_w1["openperouter-router Pod\nnet1: 10.100.0.11/24\nASN 64514"]
        end

        subgraph w2_inside["c9s-worker2 の内部"]
            openbr0_w2["openbr0\n(bridge: 10.100.0.0/24)"]
            pe_w2["openperouter-router Pod\nnet1: 10.100.0.11/24\nASN 64514"]
        end

        subgraph cp_inside["c9s-control-plane の内部"]
            openbr0_cp["openbr0\n(bridge: 10.100.0.0/24)"]
            pe_cp["openperouter-router Pod\nnet1: 10.100.0.10/24\nASN 64514"]
        end

        openbr0 --- pe_w1
        openbr0_w2 --- pe_w2
        openbr0_cp --- pe_cp

        tor -. "veth (connect-tor.sh で作成)\nnet1: 10.100.0.100/24" .-> openbr0

        pe_w1 <-. "EVPN/VXLAN VNI:100\nVRF: red\n(10.200.0.0/24)" .-> pe_w2
        pe_w1 <-. "EVPN/VXLAN" .-> pe_cp
        pe_w2 <-. "EVPN/VXLAB" .-> pe_cp
    end
```
