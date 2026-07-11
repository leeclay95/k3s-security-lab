package main

# Conftest (OPA) policies that shift-left the lab's runtime Gatekeeper
# constraints, so an insecure workload is caught at PR time instead of only at
# admission. Mirrors: block-privileged, require-non-root, require-resource-limits,
# block-host-namespaces, block-dangerous-caps.
#
# Conftest evaluates each YAML document in the rendered chart as its own `input`.
# Non-workload docs (ConfigMap, Service, CRDs, ...) simply don't match and pass.

import future.keywords.contains
import future.keywords.if
import future.keywords.in

workload_kinds := {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "Pod"}

is_workload if input.kind in workload_kinds

# Pod spec lives in a different place for a bare Pod vs a controller.
pod_spec := input.spec.template.spec if input.kind != "Pod"

pod_spec := input.spec if input.kind == "Pod"

# All app + init containers.
all_containers contains c if c := pod_spec.containers[_]

all_containers contains c if c := pod_spec.initContainers[_]

name := sprintf("%s/%s", [input.kind, input.metadata.name])

# --- block-privileged ------------------------------------------------------
deny contains msg if {
	is_workload
	some c in all_containers
	c.securityContext.privileged == true
	msg := sprintf("%s: container %q must not run privileged", [name, c.name])
}

# --- require-non-root ------------------------------------------------------
container_non_root(c) if c.securityContext.runAsNonRoot == true

container_non_root(_) if pod_spec.securityContext.runAsNonRoot == true

deny contains msg if {
	is_workload
	some c in all_containers
	not container_non_root(c)
	msg := sprintf("%s: container %q must set runAsNonRoot=true (pod or container)", [name, c.name])
}

# --- require-resource-limits ----------------------------------------------
deny contains msg if {
	is_workload
	some c in all_containers
	not c.resources.limits.cpu
	msg := sprintf("%s: container %q must set resources.limits.cpu", [name, c.name])
}

deny contains msg if {
	is_workload
	some c in all_containers
	not c.resources.limits.memory
	msg := sprintf("%s: container %q must set resources.limits.memory", [name, c.name])
}

# --- block-host-namespaces -------------------------------------------------
deny contains msg if {
	is_workload
	pod_spec.hostNetwork == true
	msg := sprintf("%s: hostNetwork is not allowed", [name])
}

deny contains msg if {
	is_workload
	pod_spec.hostPID == true
	msg := sprintf("%s: hostPID is not allowed", [name])
}

deny contains msg if {
	is_workload
	pod_spec.hostIPC == true
	msg := sprintf("%s: hostIPC is not allowed", [name])
}

# --- block-dangerous-caps --------------------------------------------------
dangerous_caps := {"ALL", "NET_RAW", "NET_ADMIN", "SYS_ADMIN", "SYS_PTRACE", "SYS_MODULE"}

deny contains msg if {
	is_workload
	some c in all_containers
	some cap in c.securityContext.capabilities.add
	cap in dangerous_caps
	msg := sprintf("%s: container %q adds dangerous capability %q", [name, c.name, cap])
}

# Encourage the hardened default of dropping ALL capabilities.
deny contains msg if {
	is_workload
	some c in all_containers
	not drops_all(c)
	msg := sprintf("%s: container %q must drop ALL capabilities", [name, c.name])
}

drops_all(c) if "ALL" in c.securityContext.capabilities.drop
