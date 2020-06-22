---
title: How to keep your k8s workers healthy, patched and secure without any impact on hosted applications.
theme: solarized
revealOptions:
  slideNumber: true
---

## How to keep your k8s workers healthy, patched and secure without any impact on hosted applications

---

# #agenda

* glossary
* worker lifecycle

---

# #whoAmI

Michal Schott

* WebOps Engineer
* Street Manager
* k8s or die!

https://schottlabs.eu/resume/

---

# #glossary

* k8s - kubernetes
* k8s worker - place where you run containers, regular VM with OS attached to k8s masterplane
* kubectl - ssh replacement

----

# #glossary

* healthy - no kernel panics etc
* patched - OS is up-to-date with all patches available
* secure - attack vector is as small as possible
* impact on hosted application - end user do not notice downtime

----

# #glossary

* pod - collection of containers
* endpoint - IP address of pod
* service - load balanced (round robin) collection of endpoints, network entrypoint to your containers
* PDB - pod disruption budged, how many pods needs to stay in healthy state during maintenance

----

# #glossary

* node unscheduleable - k8s scheduler can **NOT** assign pods to node // kubectl cordon
* node scheduleable - k8s scheduler can assign pods to node // kubectl uncordon
* eviction - pod termination event, usually happens when you want to relocate workload to different worker // kubectl drain

---

# #workerLifecycle

---

Resources:
* https://www.youtube.com/watch?v=pffTghceW0Y
* https://docs.flatcar-linux.org/os/sdk-disk-partitions/
