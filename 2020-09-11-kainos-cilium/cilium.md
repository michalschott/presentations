# what is cilium

[Project page](https://cilium.io/)

* another CNI plugin designed for high scale, security and observability out of the box
* eBPF based ([https://lmgtfy.com/?q=ebpf](https://lmgtfy.com/?q=ebpf))

Out of the box:
* networking: highly scalable kubernetes CNI, kube-proxy load balancer replacement, multicluster connectivity
* observability: identity-aware network visibility, network metrics + troubleshooting, API-aware network observability
* security: advanced network policy, security forensics + audit, transparent encryption

# setup cluster

Requirements:

* [Kind](https://github.com/kubernetes-sigs/kind)
* [Helm3 official](https://github.com/helm/helm) / [Helm3 with vendored deps](https://github.com/michalschott/helm)

```
cat <<< '
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
- role: worker
networking:
  disableDefaultCNI: true
' > kind.yaml

kind create cluster --config kind.yaml
```

**NOTE**
The cluster nodes will remain in state NotReady until Cilium is deployed. This behavior is expected.

# install cilium

`helm repo add cilium https://helm.cilium.io/`

Preload image to worker nodes:
```
docker pull cilium/cilium:v1.8.3
kind load docker-image cilium/cilium:v1.8.3
```

Install with helm:
```
helm install cilium cilium/cilium --version 1.8.3 \
   --namespace kube-system \
   --set global.nodeinit.enabled=true \
   --set global.kubeProxyReplacement=partial \
   --set global.hostServices.enabled=false \
   --set global.externalIPs.enabled=true \
   --set global.nodePort.enabled=true \
   --set global.hostPort.enabled=true \
   --set config.bpfMasquerade=false \
   --set global.pullPolicy=IfNotPresent \
   --set config.ipam=kubernetes
kubectl -n kube-system get pods --watch
```

# enable Hubble

Hubble is a fully distributed networking and security observability platform for cloud native workloads. It is built on top of Cilium and eBPF to enable deep visibility into the communication and behavior of services as well as the networking infrastructure in a completely transparent manner.

Hubble can be configured to be in local mode or distributed mode (beta).

## local mode

In local mode, Hubble listens on a UNIX domain socket. You can connect to a Hubble instance by running hubble command from inside the Cilium pod. This provides networking visibility for traffic observed by the local Cilium agent.

```
helm upgrade cilium cilium/cilium --version 1.8.3 \
   --namespace kube-system \
   --reuse-values \
   --set global.hubble.enabled=true \
   --set global.hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,http}"

kubectl exec -n kube-system -t ds/cilium -- hubble observe
```

## distributed mode

In distributed mode (beta), Hubble listens on a TCP port on the host network. This allows Hubble Relay to communicate with all the Hubble instances in the cluster. Hubble CLI and Hubble UI in turn connect to Hubble Relay to provide cluster-wide networking visibility.

**NOTE**
In Distributed mode, Hubble runs a gRPC service over plain-text HTTP on the host network without any authentication/authorization. The main consequence is that anybody who can reach the Hubble gRPC service can obtain all the networking metadata from the host. It is therefore strongly discouraged to enable distributed mode in a production environment.

```
helm upgrade cilium cilium/cilium --version 1.8.3 \
   --namespace kube-system \
   --reuse-values \
   --set global.hubble.enabled=true \
   --set global.hubble.listenAddress=":4244" \
   --set global.hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,http}" \
   --set global.hubble.relay.enabled=true \
   --set global.hubble.ui.enabled=true

kubectl rollout restart ds/cilium
```

Get hubble binary from https://github.com/cilium/hubble/releases

Once the hubble CLI is installed, set up a port forwarding for hubble-relay service and run hubble observe command:

```
kubectl port-forward -n kube-system svc/hubble-relay 4245:80
```

```
hubble observe --server localhost:4245
```

OR

```
export HUBBLE_DEFAULT_SOCKET_PATH=localhost:4245
hubble observe
```

To validate that Hubble UI is properly configured, set up a port forwarding for hubble-ui service:

```
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
```

and then open [http://localhost:12000/](http://localhost:12000/).

## grafana & prometheus

```
kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/v1.8/examples/kubernetes/addons/prometheus/monitoring-example.yaml

helm upgrade cilium cilium/cilium --version 1.8.3 \
   --namespace kube-system \
   --reuse-values \
   --set global.prometheus.enabled=true \
   --set global.operatorPrometheus.enabled=true \
   --set global.hubble.enabled=true \
   --set global.hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,http}"

kubectl -n cilium-monitoring port-forward service/grafana 3000:3000
kubectl -n cilium-monitoring port-forward service/prometheus 9090:9090
```

# Identity-aware and HTTP-aware policy enforcement

## Demo App

In our Star Wars-inspired example, there are three microservices applications: deathstar, tiefighter, and xwing. The deathstar runs an HTTP webservice on port 80, which is exposed as a Kubernetes Service to load-balance requests to deathstar across two pod replicas. The deathstar service provides landing services to the empire’s spaceships so that they can request a landing port. The tiefighter pod represents a landing-request client service on a typical empire ship and xwing represents a similar service on an alliance ship. They exist so that we can test different security policies for access control to deathstar landing services.

![topology](https://docs.cilium.io/en/v1.8/_images/cilium_http_gsg.png)

```
kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/v1.8/examples/minikube/http-sw-app.yaml
```

Each pod will be represented in Cilium as an Endpoint. We can invoke the cilium tool inside the Cilium pod to list them:

```
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system exec $POD -- cilium endpoint list

or 

kubectl -n kube-system exec ds/cilium -- cilium endpoint list
```

Both ingress and egress policy enforcement is still disabled on all of these pods because no network policy has been imported yet which select any of the pods.

## Check current access

From the perspective of the deathstar service, only the ships with label org=empire are allowed to connect and request landing. Since we have no rules enforced, both xwing and tiefighter will be able to request landing. To test this, use the commands below.

```
kubectl exec xwing -- curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing
kubectl exec tiefighter -- curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing
```

## Apply L3/L4 policy

We’ll start with the basic policy restricting deathstar landing requests to only the ships that have label (org=empire). This will not allow any ships that don’t have the org=empire label to even connect with the deathstar service. This is a simple policy that filters only on IP protocol (network layer 3) and TCP protocol (network layer 4), so it is often referred to as an L3/L4 network security policy.

**NOTE**
Note: Cilium performs stateful connection tracking, meaning that if policy allows the frontend to reach backend, it will automatically allow all required reply packets that are part of backend replying to frontend within the context of the same TCP/UDP connection.

![topology](https://docs.cilium.io/en/v1.8/_images/cilium_http_l3_l4_gsg.png)

```
cat <<EOF | kubectl apply -f -
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
description: "L3-L4 policy to restrict deathstar access to empire ships only"
metadata:
  name: "rule1"
spec:
  endpointSelector:
    matchLabels:
      org: empire
      class: deathstar
  ingress:
  - fromEndpoints:
    - matchLabels:
        org: empire
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
EOF
```

Check:

```
kubectl exec tiefighter -- curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing
kubectl exec xwing -- curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing
```

## inspecting policy

If we run cilium endpoint list again we will see that the pods with the label org=empire and class=deathstar now have ingress policy enforcement enabled.

```
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system exec $POD -- cilium endpoint list

kubectl get cnp
kubectl describe cnp rule1
```

Or use hubble-ui

## apply and test http-aware L7 policy

In the simple scenario above, it was sufficient to either give tiefighter / xwing full access to deathstar’s API or no access at all. But to provide the strongest security (i.e., enforce least-privilege isolation) between microservices, each service that calls deathstar’s API should be limited to making only the set of HTTP requests it requires for legitimate operation.

For example, consider that the deathstar service exposes some maintenance APIs which should not be called by random empire ships. To see this run:

`kubectl exec tiefighter -- curl -s -XPUT deathstar.default.svc.cluster.local/v1/exhaust-port`

![topology](https://docs.cilium.io/en/v1.8/_images/cilium_http_l3_l4_l7_gsg.png)

```
cat <<EOF | kubectl apply -f -
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
description: "L7 policy to restrict access to specific HTTP call"
metadata:
  name: "rule1"
spec:
  endpointSelector:
    matchLabels:
      org: empire
      class: deathstar
  ingress:
  - fromEndpoints:
    - matchLabels:
        org: empire
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http:
        - method: "POST"
          path: "/v1/request-landing"
EOF
```

```
kubectl exec tiefighter -- curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing
kubectl exec tiefighter -- curl -s -XPUT deathstar.default.svc.cluster.local/v1/exhaust-port
```

Observe with:
```
kubectl describe ciliumnetworkpolicies
kubectl -n kube-system exec cilium-$POD -- cilium policy get
```

## cleanup 
```
kubectl delete cnp rule1
kubectl delete -f https://raw.githubusercontent.com/cilium/cilium/v1.8/examples/minikube/http-sw-app.yaml
```

# locking down external access with DNS-based policies

## Demo app

In line with our Star Wars theme examples, we will use a simple scenario where the empire’s mediabot pods need access to Twitter for managing the empire’s tweets. The pods shouldn’t have access to any other external service.

```
kubectl create -f https://raw.githubusercontent.com/cilium/cilium/v1.8/examples/kubernetes-dns/dns-sw-app.yaml
```

## Apply DNS Egress policy

The following Cilium network policy allows mediabot pods to only access api.twitter.com.

```
cat <<EOF | kubectl apply -f -
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "fqdn"
spec:
  endpointSelector:
    matchLabels:
      org: empire
      class: mediabot
  egress:
  - toFQDNs:
    - matchName: "api.twitter.com"  
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": kube-system
        "k8s:k8s-app": kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: ANY
      rules:
        dns:
        - matchPattern: "*"
EOF
```

Let’s take a closer look at the policy:

* The first egress section uses toFQDNs: matchName specification to allow egress to api.twitter.com. The destination DNS should match exactly the name specified in the rule. The endpointSelector allows only pods with labels class: mediabot, org:empire to have the egress access.
* The second egress section allows mediabot pods to access kube-dns service. Note that rules: dns instructs Cilium to inspect and allow DNS lookups matching specified patterns. In this case, inspect and allow all DNS queries.

Note that with this policy the mediabot doesn’t have access to any internal cluster service other than kube-dns.

Test:
```
kubectl exec -it mediabot -- curl -sL https://api.twitter.com
kubectl exec -it mediabot -- curl -sL https://help.twitter.com
```

## DNS policies using patterns

The above policy controlled DNS access based on exact match of the DNS domain name. Often, it is required to allow access to a subset of domains. Let’s say, in the above example, mediabot pods need access to any Twitter sub-domain, e.g., the pattern *.twitter.com. We can achieve this easily by changing the toFQDN rule to use matchPattern instead of matchName.

```
cat <<EOF | kubectl apply -f -
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "fqdn"
spec:
  endpointSelector:
    matchLabels:
      org: empire
      class: mediabot
  egress:
  - toFQDNs:
    - matchPattern: "*.twitter.com" 
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": kube-system
        "k8s:k8s-app": kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: ANY
      rules:
        dns:
        - matchPattern: "*"
EOF
```

Test:
```
kubectl exec -it mediabot -- curl -sL https://help.twitter.com
kubectl exec -it mediabot -- curl -sL https://about.twitter.com
kubectl exec -it mediabot -- curl -sL https://twitter.com
```

## Combining DNS, Port and L7 rules

The DNS-based policies can be combined with port (L4) and API (L7) rules to further restrict the access. In our example, we will restrict mediabot pods to access Twitter services only on ports 443. The toPorts section in the policy below achieves the port-based restrictions along with the DNS-based policies.

```
cat <<EOF | kubectl apply -f -
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "fqdn"
spec:
  endpointSelector:
    matchLabels:
      org: empire
      class: mediabot
  egress:
  - toFQDNs:
    - matchPattern: "*.twitter.com" 
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP 
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": kube-system
        "k8s:k8s-app": kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: ANY
      rules:
        dns:
        - matchPattern: "*"    
EOF
```

Test:

```
kubectl exec -it mediabot -- curl https://help.twitter.com
kubectl exec -it mediabot -- curl http://help.twitter.com
```

## cleanup

```
kubectl delete -f https://raw.githubusercontent.com/cilium/cilium/v1.8/examples/kubernetes-dns/dns-sw-app.yaml
kubectl delete cnp fqdn
```

# what else can cilium do

* CNI chaining

```
CNI chaining allows to use Cilium in combination with other CNI plugins.

With Cilium CNI chaining, the base network connectivity and IP address management is managed by the non-Cilium CNI plugin, but Cilium attaches BPF programs to the network devices created by the non-Cilium plugin to provide L3/L4/L7 network visibility & policy enforcement and other advanced features like transparent encryption.

Currently supported:
* aws-cni
* azure cni
* calico
* generic veth chaining
* portmap (hostport)
* weavenet
```

* use policy-dry-run mode - [details here](https://docs.cilium.io/en/v1.8/gettingstarted/policy-creation/)

* secure gRPC endpoints

* advanced networking (AWS ENI mode, BGP with kube-router, cluster mesh, replace kube-proxy)

* lock down external access using AWS metadata:
```
---
kind: CiliumNetworkPolicy
apiVersion: cilium.io/v2
metadata:
  name: to-groups-sample
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      org: alliance
      class: xwing
  egress:
  - toPorts:
    - ports:
      - port: '80'
        protocol: TCP
    toGroups:
    - aws:
        securityGroupsIds:
        - 'sg-0f2146100a88d03c3'
```

* manage host firewalls (beta, feedback very much welcome)
```
apiVersion: "cilium.io/v2"
kind: CiliumClusterwideNetworkPolicy
description: ""
metadata:
  name: "demo-host-policy"
spec:
  nodeSelector:
    matchLabels:
      node-access: ssh
  ingress:
  - fromEntities:
    - cluster
  - toPorts:
    - ports:
      - port: "22"
        protocol: TCP
```

* integrate with Istio

[Docs](https://docs.cilium.io/en/v1.8/)