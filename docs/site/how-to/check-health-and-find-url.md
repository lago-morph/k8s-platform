---
status: stable
---

# Check an application's health and find its URL

Answer "is my app healthy, and what's its URL?" using only what the
platform exposes. Three layers, checked in order — delivery, runtime,
endpoint — because each one scopes the next. The exact fields and
their meanings live in
[Health and status surfaces](../reference/health-surfaces.md).

## 1. Is it delivered? (Argo CD Application)

On the management cluster:

```bash
kubectl get application <cluster-short-name>-<app> -n argocd \
  -o jsonpath='{.status.sync.status}/{.status.health.status}'
```

- `Synced/Healthy` — Git and cluster agree, workload reports ready.
  Move on.
- `OutOfSync/...` — a rollout or a not-yet-reconciled change.
- `.../Degraded` — resources failing; read the message:

```bash
kubectl get application <name> -n argocd \
  -o jsonpath='{.status.operationState.message}'
```

## 2. Is it running? (your namespace)

On the cluster the app runs on:

```bash
kubectl -n <ns> get pods
kubectl -n <ns> rollout status deploy/<name>
kubectl -n <ns> get events --sort-by=.lastTimestamp | tail -5
kubectl -n <ns> logs deploy/<name> --tail=50
```

## 3. What's the URL, and does it answer?

The URL is declared by your own Ingress — read it back rather than
remembering it:

```bash
kubectl -n <ns> get ingress <name> \
  -o jsonpath='{.spec.rules[0].host}'
```

Then:

```bash
curl -sSf https://<that-host>
```

HTTP 200 over verified TLS is the platform's definition of a working
exposure. If layers 1 and 2 are green but this fails, work the
[expose guide's troubleshooting order](expose-an-application.md#troubleshooting-order)
— it is almost always DNS propagation on a fresh Ingress.

## For infrastructure you provisioned

Composite resources report the same way everywhere:

```bash
kubectl get xplatformsecret,xdatabase -n <ns>   # READY column
kubectl describe xdatabase <name> -n <ns>       # conditions + events
```

## Where to find logs

Most logs are one `kubectl logs` away. The table says where each kind
of log lives, how to reach it, and what is **not** kept anywhere.

!!! warning "Live behaviour unverified"
    The control-plane log configuration below is committed but has not
    yet run on a build, and the commands in this table have not been
    exercised against a live platform: `pending clean-build verification`.

| Log | Where it lives | How to reach it | Kept for |
|---|---|---|---|
| A running container | the node | `kubectl -n <ns> logs <pod> [-c <container>]` | the pod's life |
| The previous run of a restarted container | the node | `kubectl -n <ns> logs <pod> --previous` | until the next restart |
| A pod that was deleted or rescheduled | **nowhere** | not kept: read it before it goes. Its lifecycle (who deleted it, when) is in the audit log below | — |
| Events (`Back-off`, `FailedScheduling`, …) | the cluster | `kubectl -n <ns> get events --sort-by=.lastTimestamp` | about 1 hour |
| EKS control plane: API server, audit, authenticator — hub **and** every spoke | CloudWatch Logs, `/aws/eks/<cluster>/cluster` | `aws logs tail /aws/eks/<cluster>/cluster --since 1h --log-stream-name-prefix kube-apiserver-audit`, or the CloudWatch console | 7 days (`control_plane_log_retention_days`) |
| kubelet / containerd on a live node | the node's journal | `kubectl debug node/<node> -it --image=busybox -- chroot /host journalctl -u kubelet --since '1 hour ago'` (needs create-pod rights) | the node's life |
| A node that never joined | EC2 console output | `aws ec2 get-console-output --instance-id <id> --latest --output text` | the instance's life |
| A Terraform or verification run | GitHub Actions | the run's page in the Actions tab | 90 days |
| `k8p-bringup.sh` on the ops box | the browser shell's terminal | scroll back, or keep a copy yourself with `script -a ~/bringup.log` before you run it | the session; **lost** when the box is destroyed |

The cluster names are `k8-platform-mgmt` (hub), `k8-platform-services`
(platform) and `k8-platform-workload1` (workload). Audit log streams are
named `kube-apiserver-audit-*`, API server streams `kube-apiserver-*`,
and authenticator streams `authenticator-*`.

The ops box's instance role can describe log groups but cannot search
them (`logs:FilterLogEvents`), so `aws logs tail` there fails; run it
with the account's own credentials or use the CloudWatch console.
