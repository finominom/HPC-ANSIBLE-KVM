# Role: monitoring

Prometheus, Alertmanager and Grafana on the master; node_exporter on every
host; slurm_exporter on the master.

```
 c01, c02, master          master
 node_exporter :9100  -->  Prometheus 127.0.0.1:9090 --> Alertmanager 127.0.0.1:9093 --> e-mail (optional)
 (master only may           ^          |
  connect: rich rule)       |          v
 slurm_exporter 127.0.0.1:9341      Grafana 127.0.0.1:3000  <-- you, through an SSH tunnel
 (sinfo, squeue, sdiag ...)
```

| Part | Version | From | Runs on | Port |
|---|---|---|---|---|
| Prometheus | 3.13.5 (LTS) | GitHub release, SHA-256 checked | master | 127.0.0.1:9090 |
| Alertmanager | 0.35.0 | GitHub release, SHA-256 checked | master | 127.0.0.1:9093 |
| node_exporter | 1.12.1 | GitHub release, SHA-256 checked | every host | :9100, master only |
| slurm_exporter (SckyzO) | 1.8.6 | GitHub release, SHA-256 checked | master | 127.0.0.1:9341 |
| Grafana OSS | current release | rpm.grafana.com (signed repo) | master | 127.0.0.1:3000 |

The master downloads each archive once into `/opt/monitoring-dist` and
Ansible copies the binaries to the hosts, so the compute nodes need no
internet access. To upgrade, change a `monitoring_*_version` and re-run.

**Why this Slurm exporter:** EPEL 9 ships Slurm 22.05. Slurm 25.11 and later
publish Prometheus metrics from slurmctld itself (`MetricsType=metrics/openmetrics`);
22.05 does not, so an exporter that runs the Slurm commands is needed. If you
later move to Slurm 25.11+, set `monitoring_slurm_exporter_enabled: false` and
scrape slurmctld on port 6817 instead.

## Dashboards (provisioned, folder → dashboard)

- **Nodes**: Node Exporter Full (grafana.com 1860), NFS Full
- **Slurm**: Cluster Overview, Jobs & Queue, Node Detail, Usage, Scheduler, Exporter Health

Provisioned dashboards cannot be overwritten from the web UI: use "Save as"
to make an editable copy.

## Alerts

`files/hpc-alerts.yml` (ours): HostDown, SlurmExporterDown,
FilesystemAlmostFull (>90%), FilesystemReadOnly, MemoryLow (<5%),
ClockNotSynchronised, ClockOffsetLarge (>50 ms), SystemdUnitFailed, HostRebooted.
`slurm-alerts.yml` / `slurm-rules.yml`: from the Slurm exporter project
(node down/drain, pending jobs, failure rate, scheduler, slurmdbd queue).

Without `monitoring_alert_email_to`, alerts are visible in Grafana
(Alerting → Alert rules, data source Prometheus) and on the Alertmanager
page (`ssh -L 9093:localhost:9093`). To e-mail them (Gmail / Google
Workspace needs an App Password):

```yaml
# group_vars/master/main.yml
monitoring_alert_email_to: hpc-admin@uniben.edu
monitoring_smtp_from: hpc-alerts@uniben.edu
monitoring_smtp_username: hpc-alerts@uniben.edu
# group_vars/master/vault.yml (ansible-vault edit)
vault_alert_smtp_password: "app-password"
```

## Variables you are most likely to change

| Variable | Default | Notes |
|---|---|---|
| `monitoring_scrape_group` | `monitored` | inventory group whose hosts are scraped |
| `monitoring_grafana_addr` | `127.0.0.1` | SSH tunnel; set an IP plus `monitoring_grafana_open_zone` to open it |
| `monitoring_prometheus_retention` | `30d` | |
| `monitoring_prometheus_data_dir` | `/var/lib/prometheus` | `/data/prometheus` on the real master if `/var` is small |
| `monitoring_slurm_exporter_args` | `[]` | e.g. `["--no-collector.licenses"]` if a collector fails on Slurm 22.05 |
| `monitoring_node_exporter_args` | systemd, textfile | |

Write `*.prom` files into `/var/lib/node_exporter/textfile/` on any host
(from cron) to add your own metrics: GPU, InfiniBand, licence counts.
