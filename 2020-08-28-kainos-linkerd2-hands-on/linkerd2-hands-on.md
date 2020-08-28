## What is service Mesh

### Data plane

Usually build with sidecar proxies (ie Envoy)

* service discovery
* health checking
* routing
* load balancing
* authentication and authorization
* observability 
 
### Control plane

All of the below items are the responsibility of the service mesh control plane.

* how does the proxy actually know to route /foo to service B? 
* how is the service discovery data that the proxy queries populated?
* how are the load balancing, timeout, circuit breaking, etc. settings specified?
* how are deploys accomplished using blue/green or gradual traffic shifting semantics?
* who configures systemwide authentication and authorization settings?

The control plane takes a set of isolated stateless sidecar proxies and turns them into a distributed system.

## Linkerd2 features

* all works out of the box with minimal effort
* http, http2, grpc proxying
* tcp proxying and protocol detection
* retries and timeouts
* automatic mTLS
* telemetry and monitoring
* intelligent loadbalancing - Linkerd uses an algorithm called EWMA, or exponentially weighted moving average, to automatically send requests to the fastest endpoints
* automatic proxy injection
* distributed tracing
* fault injection
* HA
* multicluster support
* CNI plugin
* traffic split
* ...

## Create cluster with kind (3 workers):

Grab kind binary from https://github.com/kubernetes-sigs/kind

```
cat <<< '
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
- role: worker
' > kind-config.yml
kind create cluster --name linkerd2-demo --config kind-config.yml
```

## Get linkerd2 2.8.0 and 2.8.1 binaries from github

```
curl -LO https://github.com/linkerd/linkerd2/releases/download/stable-2.8.0/linkerd2-cli-stable-2.8.0-darwin
curl -LO https://github.com/linkerd/linkerd2/releases/download/stable-2.8.1/linkerd2-cli-stable-2.8.1-darwin
chmod +x linkerd2
ln -s linkerd2-cli-stable-2.8.0-darwin linkerd
```

## Install linkerd2

```
linkerd check --pre
linkerd install | kubectl apply -f -
linkerd check
```

## Access dashboard

```
linkerd dashboard
linkerd -n linkerd top deploy/linkerd-web
```

## Install demo app

```
curl -sL https://run.linkerd.io/emojivoto.yml | kubectl apply -f -
kubectl -n emojivoto port-forward svc/web-svc 8080:80
```

App is available at http://localhost:8080

![Tracing Topology(https://linkerd.io/images/tracing/tracing-topology.svg)

## Mesh demo app
```
kubectl get -n emojivoto deploy -o yaml | linkerd inject - | kubectl apply -f -
linkerd -n emojivoto check --proxy
watch linkerd -n emojivoto stat deploy
linkerd -n emojivoto top deploy
linkerd -n emojivoto tap deploy/web
```

## Automatic proxy injection

Linkerd automatically adds the data plane proxy to pods when the linkerd.io/inject: enabled annotation is present on a namespace or any workloads such as deployments or pods.

Proxy injection is implemented as a Kubernetes admission webhook. This means that the proxies are added to pods within the Kubernetes cluster itself, regardless of whether the pods are created by kubectl, a CI/CD system, or any other system.

For each pod, two containers are injected:

1. linkerd-init, a Kubernetes Init Container that configures iptables to automatically forward all incoming and outgoing TCP traffic through the proxy. (Note that this container is not present if the Linkerd CNI Plugin has been enabled.)
2. linkerd-proxy, the Linkerd data plane proxy itself.

Note that simply adding the annotation to a resource with pre-existing pods will not automatically inject those pods. You will need to update the pods (e.g. with kubectl rollout restart etc.) for them to be injected. This is because Kubernetes does not call the webhook until it needs to update the underlying resources.

Automatic injection can be disabled for a pod or deployment for which it would otherwise be enabled, by adding the linkerd.io/inject: disabled annotation.

## Validate mTLS
```
linkerd -n linkerd edges deployment
linkerd -n emojivoto edges deployment
linkerd -n linkerd tap deploy
```

Non-mTLS calls are Kubernetes readiness probes. As probes are initiated from the kubelet, which is not in the mesh, there is no identity and these requests are not mTLS'd, as denoted by the tls=not_provided_by_remote message.

## Upgrade control plane to linkerd 2.8.1
```
rm linkerd
ln -s linkerd2-cli-stable-2.8.1-darwin linkerd
linkerd upgrade | kubectl apply -f -
linkerd check
kubectl -n linkerd get pod
linkerd check
linkerd -n emojivoto check --proxy
kubectl -n emojivoto delete pod --all --wait=false
linkerd -n emojivoto check --proxy
```

## Upgrade data plane to linkerd 2.8.1
```
linkerd -n emojivoto check --proxy
kubectl -n emojivoto delete pod --all --wait=false
linkerd -n emojivoto check --proxy
```

## Upgrade control plane to HA
```
linkerd upgrade --ha | kubectl apply -f -
linkerd check
kubectl label ns kube-system config.linkerd.io/admission-webhooks=disabled
linkerd check
```

## Restrict dashboard privileges to disallow Tap
```
linkerd upgrade --restrict-dashboard-privileges | kubectl apply -f -
kubectl delete clusterrolebindings/linkerd-linkerd-web-admin
```

More info available [here](https://linkerd.io/2/tasks/securing-your-cluster/)

## Customize installation

```
linkerd upgrade > linkerd.yaml

cat <<< '
resources:
- linkerd.yaml
' > kustomization.yaml
```

There are a couple components in the control plane that can benefit from being associated with a critical PriorityClass. While this configuration isn't currently supported as a flag to linkerd install, it is not hard to add by using Kustomize.

```
cat <<< '
apiVersion: scheduling.k8s.io/v1
description: Used for critical linkerd pods.
kind: PriorityClass
metadata:
  name: linkerd-critical
value: 10000000
' > linkerd-priority-class.yaml

cat <<< '
apiVersion: apps/v1
kind: Deployment
metadata:
  name: linkerd-identity
spec:
  template:
    spec:
      priorityClassName: linkerd-critical
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: linkerd-controller
spec:
  template:
    spec:
      priorityClassName: linkerd-critical
' > patch-priority-class.yaml

cat <<< '
resources:
- priority-class.yaml
- linkerd.yaml
patchesStrategicMerge:
- patch-priority-class.yaml
' > kustomization.yaml

kubectl kustomize build . | kubectl apply -f -
```

More - https://linkerd.io/2/tasks/customize-install/

## Service profiles

Service profiles provide Linkerd additional information about a service and how to handle requests for a service.

When an HTTP (not HTTPS) request is received by a Linkerd proxy, the destination service of that request is identified. If a service profile for that destination service exists, then that service profile is used to to provide per-route metrics, retries and timeouts.

There are a couple different ways to use linkerd profile to create service profiles.

* Swagger
* Protobuf
* Auto-Creation
* Template

```
linkerd profile -n emojivoto web-svc --tap deploy/web --tap-duration 10s
```

### Retries

In order for Linkerd to do automatic retries of failures, there are two questions that need to be answered:

* Which requests should be retried?
* How many times should the requests be retried?

The reason why these pieces of configuration are required is because retries can potentially be dangerous. Automatically retrying a request that changes state (e.g. a request that submits a financial transaction) could potentially impact your user's experience negatively. In addition, retries increase the load on your system. A set of services that have requests being constantly retried could potentially get taken down by the retries instead of being allowed time to recover.

For routes that are idempotent and don't have bodies, you can edit the service profile and add isRetryable to the retryable route:
```
spec:
  routes:
  - name: GET /api/annotations
    condition:
      method: GET
      pathRegex: /api/annotations
    isRetryable: true ### ADD THIS LINE ###
```

A retry budget is a mechanism that limits the number of retries that can be performed against a service as a percentage of original requests. This prevents retries from overwhelming your system. By default, retries may add at most an additional 20% to the request load (plus an additional 10 “free” retries per second). These settings can be adjusted by setting a retryBudget on your service profile.

```
spec:
  retryBudget:
    retryRatio: 0.2
    minRetriesPerSecond: 10
    ttl: 10s
```

Retries can be monitored by using the linkerd routes command with the --to flag and the -o wide flag. Since retries are performed on the client-side, we need to use the --to flag to see metrics for requests that one resource is sending to another (from the server's point of view, retries are just regular requests). When both of these flags are specified, the linkerd routes command will differentiate between “effective” and “actual” traffic.

### Timeouts

To limit how long Linkerd will wait before failing an outgoing request to another service, you can configure timeouts. These work by adding a little bit of extra information to the service profile for the service you're sending requests to.

Each route may define a timeout which specifies the maximum amount of time to wait for a response (including retries) to complete after the request is sent. If this timeout is reached, Linkerd will cancel the request, and return a 504 response. If unspecified, the default timeout is 10 seconds.

```
spec:
  routes:
  - condition:
      method: HEAD
      pathRegex: /authors/[^/]*\.json
    name: HEAD /authors/{id}.json
    timeout: 300ms
```

## Distributed Tracing with Jaeger

To use distributed tracing, you'll need to:

* Add a collector which receives spans from your application and Linkerd.
* Add a tracing backend to explore traces.
* Modify your application to emit spans.
* Configure Linkerd's proxies to emit spans.

![Tracing topology](https://linkerd.io/images/tracing/tracing-topology.svg)

```
cat <<< '
tracing:
    enabled: true
' > config.yaml

linkerd upgrade --addon-config config.yaml | kubectl apply -f -

kubectl -n linkerd rollout status deploy/linkerd-collector
kubectl -n linkerd rollout status deploy/linkerd-jaeger
```

Patch emojivoto app:

```
kubectl -n emojivoto patch -f https://run.linkerd.io/emojivoto.yml -p '
spec:
  template:
    metadata:
      annotations:
        linkerd.io/inject: enabled
        config.linkerd.io/trace-collector: linkerd-collector.linkerd:55678
        config.alpha.linkerd.io/trace-collector-service-account: linkerd-collector
'
kubectl -n emojivoto set env --all deploy OC_AGENT_HOST=linkerd-collector.linkerd:55678
kubectl -n linkerd port-forward svc/linkerd-jaeger 16686
```

Jaeger available at http://localhost:16686/

More - https://linkerd.io/2/tasks/distributed-tracing/

## Traffic Split

Linkerd's traffic split feature allows you to dynamically shift traffic between services. This can be used to implement lower-risk deployment strategies like blue-green deploys and canaries.

```
kubectl apply -k github.com/weaveworks/flagger/kustomize/linkerd
kubectl -n linkerd rollout status deploy/flagger
```

![Simople topology](https://linkerd.io/images/canary/simple-topology.svg)

```
kubectl create ns test && kubectl apply -f https://run.linkerd.io/flagger.yml
kubectl -n test rollout status deploy podinfo
kubectl -n test port-forward svc/podinfo 9898
```

App available under http://localhost:9898/

```
cat <<EOF | kubectl apply -f -
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: podinfo
  namespace: test
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: podinfo
  service:
    port: 9898
  analysis:
    interval: 10s
    threshold: 5
    stepWeight: 10
    maxWeight: 100
    metrics:
    - name: request-success-rate
      thresholdRange:
        min: 99
      interval: 1m
    - name: request-duration
      thresholdRange:
        max: 500
      interval: 1m
EOF

kubectl -n test get ev --watch
```

![Initialized architecture](https://linkerd.io/images/canary/initialized.svg)

```
kubectl -n test set image deployment/podinfo podinfod=quay.io/stefanprodan/podinfo:1.7.1
kubectl -n test get ev --watch
kubectl -n test set image deployment/podinfo podinfod=quay.io/stefanprodan/podinfo:1.7.0
```

![Ongoing architecture](https://linkerd.io/images/canary/ongoing.svg)

```
watch kubectl -n test get canary
kubectl -n test get trafficsplit podinfo -o yaml
watch linkerd -n test stat deploy --from deploy/load
kubectl -n test port-forward svc/frontend 8080
```

More - https://linkerd.io/2/tasks/canary-release/

## PodSecurityPolicies

Sadly it takes a lot of effort to setup this in `kind`.

Rewriting iptables is required for routing network traffic through the pod's linkerd-proxy container. When the CNI plugin is enabled, individual pods no longer need to include an init container that requires the NET_ADMIN capability to perform rewriting. This can be useful in clusters where that capability is restricted by cluster administrators.

```
linkerd install-cni | kubectl apply -f -
linkerd install --linkerd-cni-enabled | kubectl apply -f -
```

More - https://linkerd.io/2/features/cni/

## Uninstall linkerd

To remove the Linkerd data plane proxies, you should remove any Linkerd proxy injection annotations and roll the deployments. When Kubernetes recreates the pods, they will not have the Linkerd data plane attached.

```
linkerd uninstall | kubectl delete -f -
```

## Delete cluster

```
kind delete cluster --name linkerd2-demo
```

## Not covered

- automatic CA certificate rotation - [docs](https://linkerd.io/2/tasks/automatically-rotating-control-plane-tls-credentials/)
- bring your own Prometheus instance - [docs](https://linkerd.io/2/tasks/external-prometheus/)
- export metrics - [docs](https://linkerd.io/2/tasks/exporting-metrics/)
- debug proper application - [docs](https://linkerd.io/2/tasks/books/)
- multicluster traffic - [docs](https://linkerd.io/2/tasks/installing-multicluster/)
- fault injection - [docs](https://linkerd.io/2/tasks/fault-injection/)
- ingress usage - [docs](https://linkerd.io/2/tasks/using-ingress/)
- ...