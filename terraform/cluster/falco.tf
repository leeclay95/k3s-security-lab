# Falco — runtime threat detection at the syscall level. This is the layer the
# API-server audit log CANNOT give you: it sees the commands run *inside* a
# container after an exec (not just the exec call), sensitive file reads, etc.
# Modern eBPF (CO-RE) driver — no kernel headers or module builds.
#
# OBSERVE-ONLY: writes JSON alerts to stdout; the cloudwatch-log-shipper tails
# them to floci CloudWatch /k8s/falco. Runs in its own `falco` namespace, so the
# webapp-scoped Gatekeeper constraints don't reject its (privileged) pods.
#
# See docs/falco.md for the driver rationale, the exec-visibility demo, and tests.

# k3d nodes don't mount debugfs, so the BPF probe can't resolve syscall
# tracepoint IDs and Falco captures nothing. Mount it before Falco installs.
# It's lost on node restart — scripts/recover.sh re-mounts it (like flannel/DNS).
resource "null_resource" "falco_debugfs" {
  depends_on = [time_sleep.cluster_ready]

  triggers = {
    node = "k3d-webapp-test-server-0"
  }

  provisioner "local-exec" {
    command = "docker exec k3d-webapp-test-server-0 sh -c 'mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug'"
  }
}

resource "helm_release" "falco" {
  depends_on       = [null_resource.falco_debugfs]
  name             = "falco"
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falco"
  version          = "9.1.0"
  namespace        = "falco"
  create_namespace = true
  wait             = true
  # Generous timeout: first run pulls the Falco image + rules artifacts.
  timeout = 600

  values = [yamlencode({
    driver = { kind = "modern_ebpf" } # CO-RE; host has BTF (kernel 6.x)
    tty    = true                     # flush alerts immediately

    falco = {
      json_output                  = true # so the log shipper can parse alerts
      json_include_output_property = true
    }

    resources = {
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { cpu = "500m", memory = "512Mi" }
    }

    # The default ruleset logs the shell *spawn* ("Terminal shell in container"),
    # not each command typed after it. This rule logs every process in the webapp
    # namespace, so the commands run after a kubectl exec are captured — the whole
    # point of adding Falco (the API-server audit log can't see them). Noisy by
    # design; tune/scope it for real use.
    customRules = {
      "webapp-commands.yaml" = <<-EOT
        - rule: Command run in webapp container
          desc: Log every process spawned inside a webapp-namespace container.
          condition: spawned_process and container and k8s.ns.name = webapp
          output: "Command in webapp container (cmd=%proc.cmdline pod=%k8s.pod.name user=%user.name parent=%proc.pname)"
          priority: NOTICE
          tags: [webapp, process, mitre_execution, T1059]
      EOT
    }
  })]
}
