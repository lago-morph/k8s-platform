---
status: stable
---

# What a finished platform contains

The expected state of a completely built platform — the inventory that
makes "everything is green" a meaningful claim. Use it two ways:
verifying a build you didn't perform (sweep the lists below), and
noticing what's *missing*, which no per-application health check can
tell you. States here are what the platform's own verified builds
produce, including the items that are expectedly not green.

## Delivery layer (Argo CD, management cluster)

Projects that must exist: `default` (carries only the bootstrap app),
`k8-platform` (hub control-plane resources), `platform-spoke` (the
spoke stack), `hub-addons`.

Applications in namespace `argocd`:

| Application | Expected state | Notes |
|---|---|---|
| `bootstrap` | Synced/Healthy | The app-of-apps; owns everything below |
| `crossplane-resources` | Synced/Healthy | Composite definitions, compositions, stores |
| `management-cluster-config` | Synced/Healthy | Hub-side configuration |
| `keycloak-db` | Synced/Healthy | The SSO database XR |
| `keycloak-secrets` | Synced/Healthy | The SSO bootstrap secret XRs |
| `platform-cluster-claim` | Synced/Healthy **after its deliberate sync** | Manual-sync gate by design — creates the platform services cluster |
| `spoke-access` | Synced/Healthy **after its deliberate sync** | Manual-sync gate — registers the spoke |
| `workload1-cluster` | **OutOfSync, by design** | The second-cluster gate stays unpulled until fan-out is exercised |

Per-spoke Applications (generated per registered spoke; for the
platform services cluster, prefix `platform-`):

| Application | Expected state | Notes |
|---|---|---|
| `platform-ingress-nginx` | Synced/Healthy | Ingress + the TLS-terminating load balancer |
| `platform-external-dns` | Synced/Healthy | DNS records for Ingress hosts |
| `platform-eso` | Synced/Healthy | Secret sync (ClusterSecretStore `aws-secrets-manager`) |
| `platform-hello` | Synced/Healthy | The built-in demo app — the behavioral gate's target |
| `platform-keycloak` | Synced/Healthy | SSO components (logins land with the identity phase) |
| observability set (kube-prometheus-stack, loki, alloy) | Synced/Healthy | The spoke-storage gap closed on clean build #6 (2026-09-09): with the EBS CSI addon and the default `gp3` StorageClass in place, all 3 monitoring PVCs Bound and both previously non-green Applications reached Healthy |
| storage (the default `gp3` StorageClass) | Synced/Healthy | Added by build #6; the Kubernetes half of spoke storage — the `aws-ebs-csi-driver` addon and its IRSA role are composed, not delivered here |

## Infrastructure layer (composite resources)

All with conditions `Synced`/`Ready`/`Responsive` = True:

- One platform-cluster XR (the platform services cluster)
- One spoke-access XR (its hub registration)
- `keycloak-db` (XDatabase, namespace `keycloak`)
- `keycloak-admin` and `keycloak-oidc-clients` (XPlatformSecrets,
  namespace `keycloak`)

## Endpoints

| Endpoint | Expected |
|---|---|
| `https://hello.platform.<domain>` | HTTP 200 over verified TLS — **the** behavioral gate |
| `https://argocd.management.<domain>` | Argo CD UI answering with a valid certificate (operator login) — attested by `tests/live/checks/after/argocd-endpoint-tls-live.sh`, which fetches it with TLS verification ON and fails if the chain does not validate (kp-nkz; measured `http=200 ssl_verify_result=0` on 2026-09-09 against the build-#6 hub, and a gating check as of the next build) |
| `https://grafana.platform.<domain>` | Host configured by the kube-prometheus-stack Application, which has been Healthy on storage since build #6 — but **no HTTP check of this endpoint has been recorded on any build**, so it is `pending clean-build verification`, not a green row |

## Reading this page as an oracle

1. Sweep the Application tables; every row must match its expected
   state, including the one deliberately non-green row
   (`workload1-cluster`, OutOfSync by design — the observability set
   stopped being expectedly non-green on build #6).
2. Sweep the XR list for Ready.
3. Hit the endpoints.
4. Anything present on the cluster but absent here, or here but absent
   on the cluster, or in an unexplained state — that is a finding, and
   this page is either the evidence or the defect.

This inventory changes only by PR, alongside the change that alters
the platform's shape; a build that disagrees with it means the build
or this page is wrong, and either one is worth a filed issue.
