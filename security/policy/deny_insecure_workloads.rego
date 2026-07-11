package main

# Conftest (OPA) policies that shift-left the lab's runtime Gatekeeper
# constraints, so an insecure workload is caught at PR time instead of only at
# admission. Mirrors: block-privileged, require-non-root, require-resource-limits,
# block-host-namespaces, block-dangerous-caps.
#
# Conftest evaluates each YAML document in the rendered chart as its own `input`.
# Non-workload docs (ConfigMap, Service, CRDs, ...) simply don't match and pass.
#
# Compliance mapping (NIST SP 800-53 Rev. 5)
# ------------------------------------------
# Each deny below is annotated with the control(s) it enforces. Traceability so
# a passing gate can be pointed at an ATO/SSP as automated evidence. Controls
# used here, with the Kubernetes hardening rationale (aligns with the
# NSA/CISA Kubernetes Hardening Guide and CIS Kubernetes Benchmark crosswalks):
#
#   AC-6      Least Privilege
#   AC-6(1)   Least Privilege | Authorize Access to Security Functions
#   AC-6(2)   Least Privilege | Non-Privileged Access for Nonsecurity Functions
#   AC-6(9)   Least Privilege | Log Use of Privileged Functions
#   CM-7      Least Functionality (disable unneeded capabilities/features)
#   CM-7(1)   Least Functionality | Periodic Review
#   SC-5      Denial-of-Service Protection
#   SC-6      Resource Availability (resource allocation / priority)
#   SC-7      Boundary Protection
#   SC-39     Process Isolation
#   SI-16     Memory Protection

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
# NIST 800-53: AC-6, AC-6(1), CM-7, SC-39
# A privileged container disables container isolation and is effectively root on
# the node — the canonical least-privilege / process-isolation violation.
deny contains msg if {
	is_workload
	some c in all_containers
	c.securityContext.privileged == true
	msg := sprintf("%s: container %q must not run privileged", [name, c.name])
}

# --- require-non-root ------------------------------------------------------
# NIST 800-53: AC-6, AC-6(2), CM-7
# Running as UID 0 grants nonsecurity workload code root-equivalent authority in
# the container; forcing non-root is least-privilege for everyday functions.
container_non_root(c) if c.securityContext.runAsNonRoot == true

container_non_root(_) if pod_spec.securityContext.runAsNonRoot == true

deny contains msg if {
	is_workload
	some c in all_containers
	not container_non_root(c)
	msg := sprintf("%s: container %q must set runAsNonRoot=true (pod or container)", [name, c.name])
}

# --- require-resource-limits ----------------------------------------------
# NIST 800-53: SC-5, SC-6, SI-16
# CPU/memory limits cap a container's resource consumption so a runaway or
# hostile workload can't starve co-tenants (DoS protection / resource
# availability); the memory limit specifically backstops memory protection.
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
# NIST 800-53: SC-7, SC-39, AC-6
# hostNetwork/hostPID/hostIPC break the pod out of its namespace isolation:
# hostNetwork bypasses network boundary controls and NetworkPolicy (SC-7), while
# hostPID/hostIPC expose the node's process/IPC namespaces (SC-39 process
# isolation, AC-6 least privilege).
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
# NIST 800-53: AC-6, AC-6(1), CM-7, SC-39
# Linux capabilities like SYS_ADMIN/SYS_MODULE/SYS_PTRACE hand a container
# kernel-level privilege and cross-process reach — blocking them (and requiring
# drop ALL) is least privilege + least functionality + process isolation.
dangerous_caps := {"ALL", "NET_RAW", "NET_ADMIN", "SYS_ADMIN", "SYS_PTRACE", "SYS_MODULE"}

deny contains msg if {
	is_workload
	some c in all_containers
	some cap in c.securityContext.capabilities.add
	cap in dangerous_caps
	msg := sprintf("%s: container %q adds dangerous capability %q", [name, c.name, cap])
}

# Encourage the hardened default of dropping ALL capabilities.
# NIST 800-53: AC-6, CM-7
deny contains msg if {
	is_workload
	some c in all_containers
	not drops_all(c)
	msg := sprintf("%s: container %q must drop ALL capabilities", [name, c.name])
}

drops_all(c) if "ALL" in c.securityContext.capabilities.drop
