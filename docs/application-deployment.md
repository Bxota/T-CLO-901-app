# Application deployment runbook

This runbook operates the Laravel Helm chart in `charts/laravel`. Argo CD
reconciles committed chart changes; do not replace that flow with a manual
production `kubectl apply`.

## Image delivery contract

The `Build and publish application` workflow runs on pushes to `main` and on
manual dispatch. Its `mirror-vendor-images` job runs first (see the next
section). The `test-build-publish` job then installs dependencies, runs
`php artisan test`, lints and renders `charts/laravel`, and only then logs in
to GHCR and pushes an image. A successful build publishes exactly
`ghcr.io/bxota/t-clo-901-app:${{ github.sha }}` and commits that full SHA into
`charts/laravel/values.yaml` (only the 40-hex application tag line is
rewritten; the MySQL dependency tag is never touched). The chart must use this
immutable SHA tag; do not replace it with `latest` or another mutable tag. The
chart schema rejects `latest` and any application image outside
`ghcr.io/bxota/`.

The cluster nodes are `arm64` (Graviton) while GitHub runners are `amd64`,
so the image is published as a multi-arch manifest (`linux/amd64,linux/arm64`,
built through QEMU). An amd64-only image fails on the nodes with
`no match for platform in manifest`. Check with:

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,ARCH:.status.nodeInfo.architecture'
```

Both GHCR logins use the repository secret `GHCR_PUSH_TOKEN`, a personal
access token limited to `write:packages`/`read:packages`. The GHCR packages
were created by that token and are not linked to the repository, so the
default `GITHUB_TOKEN` is denied (`permission_denied: write_package`). The
chart tag commit still uses `GITHUB_TOKEN`, whose pushes do not retrigger the
workflow. `GHCR_PUSH_TOKEN` is a CI-only credential: never place it in the
cluster, which uses the separate read-only pull secret described below. Exactly
one workflow may commit the chart image tag; a second tag-bumping workflow
(such as the former `build-and-push.yml`) races with this one and rewrites
`values.yaml` with `yq -i`, stripping its comments and blank lines.

## Admission policy and image mirror contract

The infrastructure repository's `ValidatingAdmissionPolicy`
`app-namespace-guardrails` denies any pod in namespace `app` that lacks the
`app.kubernetes.io/name` label, lacks requests/limits on any container, or
runs an image outside `ghcr.io/bxota/`. Every pod this chart creates therefore
carries the labels, declares resources, and runs a `ghcr.io/bxota/` image,
including the EFS bootstrap, migration, backup, restore-test and restore pods.
Vendor images are CI-maintained mirrors of pinned upstream tags. The
`mirror-vendor-images` job copies each manifest with
`docker buildx imagetools create` on every run (idempotent) before the chart
tag is updated:

| Upstream (pinned) | Mirror consumed by the chart | Chart value |
| --- | --- | --- |
| `docker.io/bitnamilegacy/mysql:8.0.37-debian-12-r2` | `ghcr.io/bxota/bitnami-mysql:8.0.37-debian-12-r2` | `mysql.image` |
| `docker.io/library/mysql:8.0.37` | `ghcr.io/bxota/mysql:8.0.37` | `backup.image` |
| `docker.io/library/busybox:1.37.0` | `ghcr.io/bxota/busybox:1.37.0` | `bootstrap.image` |

Bitnami stopped publishing versioned tags under `docker.io/bitnami/`; the
chart-`10.3.0` default image `docker.io/bitnami/mysql:8.0.37-debian-12-r2`
returns `404` and only the `bitnamilegacy` copy exists, which is why the mirror
source is `bitnamilegacy`. The chart schema enforces the mirror contract:
`mysql.image.registry` must be `ghcr.io` and every vendor image value must start
with `ghcr.io/bxota/`. When a vendor tag changes, update the workflow matrix
and `values.yaml` in the same commit, and keep this table aligned. Argo CD
auto-syncs a merged commit immediately, before that run's mirror job has
finished, so run the workflow once by hand (`workflow_dispatch`) before the
first merge of a new vendor tag; otherwise the MySQL and bootstrap pods sit in
`ImagePullBackOff` until the mirror lands, then recover on their own. The mirror
packages must be private GHCR packages of the same owner (a package created
by CI is public by default: set its visibility to private in the package
settings), so the read-only `ghcr-pull-secret` token pulls them as well; every pod template, including the
Bitnami StatefulSet (`mysql.image.pullSecrets`), references that pull secret.

Local pre-check of the same rules (no cluster needed): the first command lists
each pod template's name label and images, the second must print nothing.

```bash
helm template app charts/laravel --namespace app --set image.tag=test-sha > /tmp/laravel-rendered.yaml
yq -N -r 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job" or .kind == "CronJob")
  | (.spec.template // .spec.jobTemplate.spec.template) as $t
  | .kind + "/" + .metadata.name + " name=" + ($t.metadata.labels["app.kubernetes.io/name"] // "MISSING")
    + " images=" + ([$t.spec.containers[].image] | join(","))' /tmp/laravel-rendered.yaml
yq -N -r 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job" or .kind == "CronJob")
  | (.spec.template // .spec.jobTemplate.spec.template) as $t
  | $t.spec.containers[] | select(.resources.requests == null or .resources.limits == null)
  | "NO-RESOURCES " + .name' /tmp/laravel-rendered.yaml
```

Every line of the first output must show a real name label and only
`ghcr.io/bxota/` images.

## Sealed Secret contract

The chart references these existing Secrets; it must never generate them or
store their plaintext values:

```text
Secret app/mysql-credentials:
  mysql-root-password  (Bitnami chart key)
  mysql-password       (application user and backup job)
  app-key              (Laravel APP_KEY)

Secret app/ghcr-pull-secret:
  kubernetes.io/dockerconfigjson (.dockerconfigjson)
```

Generate all secret values outside Git. Seal the manifests with the cluster's
Sealed Secrets public certificate and commit only the resulting ciphertext.
For example, keep `mysql-credentials.secret.yaml` outside this repository and
use this command shape:

```bash
kubeseal --format yaml --cert sealed-secrets-public-cert.pem < mysql-credentials.secret.yaml > charts/laravel/templates/mysql-credentials.sealedsecret.yaml
```

Both Secrets are committed as `SealedSecret` manifests in
`charts/laravel/templates/` (`mysql-credentials.sealedsecret.yaml`,
`ghcr-pull-secret.sealedsecret.yaml`), synced at wave 0 with
`SkipDryRunOnMissingResource=true` because their CRD comes from the platform
Application. The controller in `kube-system` decrypts them into the plain
Secrets the chart references. To rotate a value, seal a new Secret with the
committed certificate and commit the result; never edit the plain Secret:

```bash
kubectl create secret generic mysql-credentials --namespace app \
  --from-literal=mysql-root-password="$(openssl rand -base64 24)" \
  --from-literal=mysql-password="$(openssl rand -base64 24)" \
  --from-literal=app-key="base64:$(openssl rand -base64 32)" \
  --dry-run=client -o yaml \
  | kubeseal --cert <infrastructure-repository>/sealed-secrets/pub-cert.pem --format yaml \
  > charts/laravel/templates/mysql-credentials.sealedsecret.yaml
```

Rotating `mysql-root-password` or `mysql-password` on an initialised MySQL
data directory does **not** change the passwords MySQL knows; run the matching
`ALTER USER` first, in a maintenance window. The full sealing workflow, key
backup and rebuild procedure are in the root repository's
`docs/runbooks/07-secrets-registry.md`. A first-ever cluster with no sealed
manifests yet is the only case where Secrets are created by hand, and that
step is documented there too.

To replace a wrong or rotated pull token, seal a new `ghcr-pull-secret` the
same way (`kubectl create secret docker-registry ghcr-pull-secret --namespace
app --docker-server=ghcr.io --docker-username=Bxota
--docker-password=<read-only token> --dry-run=client -o yaml | kubeseal --cert
<infrastructure-repository>/sealed-secrets/pub-cert.pem --format yaml`) and
commit it. A pod created before the fix keeps failing to pull until it is
deleted (`kubectl -n app delete pod <name>`; the Job or ReplicaSet recreates
it). Pull failures show as `403 Forbidden` on `ghcr.io/token` when the token
lacks access to a private package.

The plaintext input file must remain outside the repository and be deleted
securely after sealing. Its token has read-only package-pull access only; it
must not be a GHCR push token, and it must be able to read the mirrored
vendor packages listed above (same GHCR owner). The Deployment, migration Job
and backup jobs use `mysql-password`; only the break-glass restore Job uses
`mysql-root-password`; every pod template references `ghcr-pull-secret`.

## Build, render, and deploy

Build the dependency and validate the rendered resources before committing a
chart change or allowing Argo CD to reconcile it:

```bash
helm dependency build charts/laravel
helm lint charts/laravel --set image.tag=test-sha
helm template app charts/laravel --namespace app --set image.tag=test-sha | kubectl apply --dry-run=client -f -
kubectl -n app get deploy,pods,svc,pvc,cronjob
kubectl -n app rollout status deployment/laravel --timeout=5m
```

After Argo CD syncs the immutable image tag, the steady state is two Ready
Laravel pods, one MySQL pod, both EFS PVCs Bound (`data-mysql-0`, created by
the Bitnami StatefulSet's `data` volume claim template and bound to the static
PV `mysql-data`; and `mysql-backups`), the migration hook completed, and the
daily backup and weekly restore-test CronJobs present. Investigate a failed
migration hook or an unbound PVC before retrying the rollout.

`kubectl apply --dry-run=client` needs a reachable API server for schema
discovery; without a cluster, the `helm lint`/`helm template` steps plus the
admission pre-check above are the local validation.

### Argo CD sync order

Argo CD owns the hook lifecycle; the templates carry no `helm.sh/hook`
annotations. Each wave waits for the previous one to be Healthy (Jobs:
completed; StatefulSet: Ready), so on a fresh cluster MySQL is Ready before
migrations run and migrations complete before the Deployment is applied.

| Phase / wave | Resources | Why here |
| --- | --- | --- |
| PreSync 0 | `Job/laravel-efs-bootstrap` (re-created on every sync, `BeforeHookCreation`) | Creates `/mysql-data` (owner `1001:1001`, Bitnami MySQL) and `/mysql-backups` (owner `999:999`, official mysql image) on EFS. EFS ignores `fsGroup`, so ownership must be set explicitly. |
| Sync 0 | PVs `mysql-data`/`mysql-backups`, PVC `mysql-backups`, ConfigMap and Service `laravel` | Static storage and non-secret config. |
| Sync 1 | Bitnami MySQL (`mysql.commonAnnotations`) | Binds `data-mysql-0` to the PV, then becomes Ready. |
| Sync 2 | `Job/laravel-mysql-restore-<hash>` (only when `restore.enabled`) | Break-glass restore against the Ready MySQL, before migrations. |
| Sync 3 | `Job/laravel-migrate` (`BeforeHookCreation`) | `php artisan migrate --force` against the Ready MySQL. The completed Job stays visible until the next sync replaces it. |
| Sync 4 | `Deployment/laravel`, `HTTPRoute/laravel` | Rolls out only after migrations succeeded; the route binds `app.15.224.195.86.sslip.io` on the shared `public-gateway` (`envoy-gateway-system`, listener `https`) to `Service/laravel:80`. |

The `laravel` Service and Deployment select on
`app.kubernetes.io/component=web` in addition to name/instance, so hook and
maintenance pods, which share the name/instance labels for the admission
policy, never receive Service traffic.

## GitOps promotion and inspection

Promote a reviewed chart or application change by committing and pushing it.
Do not normally apply rendered chart resources directly with `kubectl` or run
`helm upgrade` against the cluster: Argo CD owns the desired state.

```bash
git add charts/laravel
git commit -m "chore: promote Laravel image <full-git-sha>"
git push origin main

kubectl -n argocd get application app
kubectl -n argocd annotate application app argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd get application app \
  -o jsonpath='{.status.sync.status}{" sync; "}{.status.health.status}{" health\\n"}'
kubectl -n argocd get application app -w
```

The expected final Application state is `Synced` and `Healthy`. Auto-sync
normally applies the pushed revision. If it is intentionally disabled, use the
Argo CD CLI for the reviewed revision, then wait for its operation and health;
this is still an Argo CD reconciliation, not a manual resource apply:

```bash
argocd app get app --refresh
argocd app sync app
argocd app wait app --sync --health --operation --timeout 300
```

The final `kubectl ... -w` command is a watch; stop it with `Ctrl-C` after the
Application reaches `Synced`/`Healthy`.

## Rollout and resilience evidence

Run this evidence procedure in a controlled acceptance cluster, not against a
shared production workload. Argo CD remains the only deployment writer: use
reviewed Git commits and wait for reconciliation; do not substitute a manual
imperative deployment or `helm upgrade`. First confirm the Application source still
has the expected repository, `charts/laravel` path, and `app` namespace:

```bash
rg -n "name: app|path: charts/laravel|namespace: app|repoURL" \
  <infrastructure-repository>/argocd/apps/app-app.yaml
```

After the application workflow has published an immutable SHA and committed it
to the chart, capture the healthy deployment baseline:

```bash
kubectl -n argocd get application app
kubectl -n app get deploy,pods,svc,pvc,job,cronjob
kubectl -n app rollout status deployment/laravel --timeout=5m
kubectl -n app get pvc data-mysql-0 mysql-backups
kubectl -n app get svc laravel -o jsonpath='{.spec.ports[0].port}{"\n"}'
kubectl -n app get httproute laravel -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}{" "}{end}{"\n"}'
curl --fail --show-error --silent --output /dev/null --write-out '%{http_code}\n' https://app.15.224.195.86.sslip.io/
kubectl -n app get endpointslice -l kubernetes.io/service-name=laravel \
  -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.conditions.ready}{"\n"}{end}'

# Terminal 1: keep the forward open. Terminal 2: the request must return HTTP 200.
kubectl -n app port-forward service/laravel 18080:80
curl --fail --show-error --silent --output /dev/null --write-out '%{http_code}\n' \
  --retry 5 --retry-connrefused http://127.0.0.1:18080/
```

The expected evidence is `Synced` and `Healthy`, two Ready Laravel pods, a
Ready MySQL pod, Bound `data-mysql-0` and `mysql-backups` PVCs, a completed
migration Job, both backup CronJobs, Service port `80`, exactly the two web
pods listed as `ready=true` endpoints, the HTTPRoute reporting `Accepted=True`
and `ResolvedRefs=True`, an HTTP `200` on the public URL, and an HTTP `200`
through the Service. A `404` from the public URL with a healthy Deployment
means the HTTPRoute is missing or not accepted by the Gateway.
The port-forward request is the "Service answers" evidence; the port number
alone only proves the spec. Stop and diagnose an unbound PVC, incomplete
migration, or non-Healthy Application before any resilience demo.

### Session and MySQL persistence check

This check deletes pods, so run it only in the controlled evidence cluster.
Record the PVC identity before the MySQL restart. The `/` request runs through
Laravel's `web` middleware and captures the session cookie; `/api/counter/add`
creates a durable counter record. Use the same cookie jar after each restart:

```bash
APP_URL="${APP_URL:-https://app.15.224.195.86.sslip.io}"
COOKIE_JAR="$(mktemp)"

curl --fail --show-error --cookie-jar "$COOKIE_JAR" "$APP_URL/" >/dev/null
grep -q 'laravel_session' "$COOKIE_JAR"

LARAVEL_POD="$(kubectl -n app get pod -l app.kubernetes.io/name=laravel,app.kubernetes.io/instance=app,app.kubernetes.io/component=web \
  -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app delete pod "$LARAVEL_POD"
kubectl -n app rollout status deployment/laravel --timeout=5m
curl --fail --show-error --cookie "$COOKIE_JAR" "$APP_URL/" >/dev/null

curl --fail --show-error "$APP_URL/api/counter/add"
kubectl -n app get pvc data-mysql-0 -o jsonpath='{.metadata.name}{" -> "}{.spec.volumeName}{"\n"}'
MYSQL_POD="$(kubectl -n app get pod -l app.kubernetes.io/name=mysql,app.kubernetes.io/instance=app,app.kubernetes.io/component=primary \
  -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app delete pod "$MYSQL_POD"
kubectl -n app rollout status statefulset/mysql --timeout=10m
curl --fail --show-error "$APP_URL/api/counter/count"
curl --fail --show-error --cookie "$COOKIE_JAR" "$APP_URL/" >/dev/null
```

The replacement Laravel pod must become Ready, the cookie-backed request must
continue to return successfully, and the counter value returned after MySQL is
Ready must include the value returned by `counter/add`. The current UI does not
read back a session sentinel. Therefore cookie continuity is middleware/session
storage evidence, not a conclusive application-value assertion; add a
reviewed, non-production endpoint that writes and reads a nonce before claiming
stronger cross-pod session semantics.

### Deliberate broken-readiness demonstration

Use a dedicated, reviewed temporary commit in the controlled evidence cluster.
Change only `probes.readiness.path` in `charts/laravel/values.yaml` from `/` to
`/this-path-must-not-exist`; do not change the image tag, replica count, or
liveness path. Render before merging and record the temporary commit SHA:

```bash
helm lint charts/laravel --set image.tag=test-sha
helm template app charts/laravel --namespace app --set image.tag=test-sha \
  | yq 'select((.kind == "Deployment") and (.metadata.name == "laravel")) | {"replicas": .spec.replicas, "strategy": .spec.strategy.rollingUpdate, "readiness": (.spec.template.spec.containers[] | select(.name == "laravel") | .readinessProbe.httpGet.path)}'
git diff --check
git add charts/laravel/values.yaml
git commit -m "test: demonstrate failed Laravel readiness"
git push origin main
```

After Argo CD reconciles that commit, capture the failed rollout without
deleting healthy replicas:

```bash
kubectl -n app get pods -l app.kubernetes.io/name=laravel,app.kubernetes.io/instance=app,app.kubernetes.io/component=web -o wide
kubectl -n app get rs -l app.kubernetes.io/name=laravel,app.kubernetes.io/instance=app,app.kubernetes.io/component=web -o wide
kubectl -n app get pods -l app.kubernetes.io/name=laravel,app.kubernetes.io/instance=app,app.kubernetes.io/component=web \
  -o 'custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,OWNER:.metadata.ownerReferences[0].name,CREATED:.metadata.creationTimestamp'
kubectl -n app describe deployment laravel

# After the commands above identify the new NotReady pod, keep this running in terminal 1.
kubectl -n app port-forward service/laravel 18080:80

# In terminal 2, capture the Service endpoints immediately before and after the request.
kubectl -n app get endpointslice -l kubernetes.io/service-name=laravel \
  -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.conditions.ready}{"\t"}{.conditions.serving}{"\n"}{end}'
curl --fail --show-error --retry 5 --retry-connrefused http://127.0.0.1:18080/
kubectl -n app get endpointslice -l kubernetes.io/service-name=laravel \
  -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.conditions.ready}{"\t"}{.conditions.serving}{"\n"}{end}'

kubectl -n app rollout status deployment/laravel --timeout=90s || true
kubectl -n argocd get application app
```

With `maxUnavailable: 0` and `maxSurge: 1`, the old two pods remain Ready and
serving while no more than one new pod is created. The new pod remains NotReady
and the rollout must not report success. Argo CD must be out of `Healthy`
(normally `Progressing` before the Deployment progress deadline, then
`Degraded`); record the observed status rather than accepting a silent
replacement. Keep the pod/ReplicaSet output and successful Service request in
the evidence record: together they identify the NotReady new ReplicaSet while
showing that the Service continued to route to an old Ready replica. During the
broken rollout, only the old Ready pod names should report `ready=true` in the
EndpointSlice snapshots; the new NotReady pod may be absent or report
`ready=false`. Correlate the successful curl with that ready-endpoint set, not
with the response body, which does not identify its serving pod.

Restore the readiness path through a second Git commit (or a revert of the
temporary commit), then wait for Argo CD to make the rollout healthy again:

```bash
git revert --no-edit <broken-readiness-commit>
git push origin main
kubectl -n app rollout status deployment/laravel --timeout=5m
kubectl -n app get deployment/laravel
kubectl -n app get pods -l app.kubernetes.io/name=laravel,app.kubernetes.io/instance=app,app.kubernetes.io/component=web -o wide
kubectl -n argocd get application app
```

The valid new pod must become Ready before old pods terminate, and the final
Deployment must again have two Ready replicas. Confirm
`charts/laravel/values.yaml` contains `probes.readiness.path: /` before any
subsequent chart commit.

## Backup and restore verification

Trigger an on-demand backup from the existing CronJob and wait for its Job to
complete before relying on it. The Job writes to the separate EFS backup PVC;
it does not alter the live MySQL data PVC.

```bash
BACKUP_JOB="laravel-mysql-backup-manual-$(date +%s)"
kubectl -n app create job --from=cronjob/laravel-mysql-backup "$BACKUP_JOB"
kubectl -n app wait --for=condition=complete "job/$BACKUP_JOB" --timeout=10m
kubectl -n app logs "job/$BACKUP_JOB"
```

Capture the Job's `Complete` condition and logs with the evidence (the log
ends with `backup written: /backup/app-<stamp>.sql.gz`). The backup script
writes its gzip dump atomically under the `mysql-backups` PVC and checks that
the completed file is non-empty before it renames it; a completed Job is
therefore the directory-content evidence. A failed dump must leave the Job
failed and visible, not masquerade as a successful gzip file. Backup, restore-
test and restore pods run as the official mysql image's UID `999` with all
capabilities dropped; the EFS bootstrap Job gives `/mysql-backups` to that UID.
Pruning runs only after a successful dump and uses `-mtime +(retentionDays-1)`,
so with the default `retentionDays: 7` exactly the seven newest daily dumps are
kept.

Prove the latest backup can be restored by triggering the existing restore-test
CronJob. It starts MySQL with an `emptyDir` and mounts only the backup PVC, so
this procedure is isolated from the live MySQL data PVC.

```bash
RESTORE_TEST_JOB="laravel-mysql-restore-test-manual-$(date +%s)"
kubectl -n app create job \
  --from=cronjob/laravel-mysql-restore-test "$RESTORE_TEST_JOB"
kubectl -n app wait --for=condition=complete "job/$RESTORE_TEST_JOB" --timeout=10m
kubectl -n app logs "job/$RESTORE_TEST_JOB"
```

The restore-test log must show a successful import and `SELECT COUNT(*) FROM
migrations`. It discovers the newest gzip dump from the backup PVC, imports it
into an `emptyDir` MySQL instance, and fails the Job if decompression, import,
or the migrations-table query fails. This is the independent proof that the
backup directory contains a usable dump without mounting or changing the live
MySQL data PVC.

### Production data restore

The restore-test Job is the first and normal recovery check. Never load a dump
into the live MySQL with an ad-hoc `kubectl exec`, and never write to the live
EFS data path by hand. A production data replacement is a break-glass
operation that requires an operator-approved maintenance window, a dump that
the restore-test Job has already verified, and the chart's reviewed
`restore-job.yaml`, which is rendered only when `restore.enabled` is true. The
Job runs at sync wave 2 (after MySQL is Ready, before the migration Job), uses
`mysql-root-password`, mounts the backup PVC read-only, drops and re-creates
`app_database` from the named dump, and fails visibly if the file is missing or
the import or validation query fails. Grants on `app_database.*` survive the
`DROP`/`CREATE`, so `app_user` keeps its access. The Job name ends with a hash
of `restore.dumpFile` and carries no `BeforeHookCreation` policy, so re-syncing
the same commit does not drop the database a second time; only a commit naming
a different dump creates a new Job.

1. Pause self-healing so the temporary scale-down below is not reverted before
   the restore sync. In the infrastructure repository, remove
   `spec.syncPolicy.automated` from `argocd/apps/app-app.yaml` in a reviewed
   commit and push it. That directory is applied imperatively by the bootstrap
   playbook, not by Argo CD, so the commit alone changes nothing: apply it from
   the infrastructure repository clone, then confirm the Application reports no
   automated policy (empty output or a `syncOptions`-only object):

   ```bash
   kubectl apply -f argocd/apps/app-app.yaml
   kubectl -n argocd get application app -o jsonpath='{.spec.syncPolicy.automated}{"\n"}'
   ```

2. Stop writers. MySQL stays running (a logical import needs it). The sync in
   step 3 applies the Deployment again at wave 4, after the restore and the
   migration succeeded, which is what brings the two replicas back:

   ```bash
   kubectl -n app scale deployment/laravel --replicas=0
   kubectl -n app get deployment/laravel statefulset/mysql pods
   ```

3. Select the dump and run the restore through Git. Set both values in
   `charts/laravel/values.yaml` (the schema requires an `app-<UTC stamp>.sql.gz`
   name when `restore.enabled` is true), then sync the reviewed revision with
   Argo CD:

   ```bash
   RESTORE_TEST_JOB="laravel-mysql-restore-test-$(date +%s)"
   kubectl -n app create job --from=cronjob/laravel-mysql-restore-test "$RESTORE_TEST_JOB"
   kubectl -n app wait --for=condition=complete "job/$RESTORE_TEST_JOB" --timeout=10m
   # Prints "restore test using: /backup/app-<UTC stamp>.sql.gz"; dumpFile is the basename only.
   kubectl -n app logs "job/$RESTORE_TEST_JOB" | grep 'restore test using:' | sed 's#.*/##'

   # Edit charts/laravel/values.yaml by hand (yq -i would strip its comments and blank lines):
   #   restore:
   #     enabled: true
   #     dumpFile: "app-<UTC stamp>.sql.gz"
   helm lint charts/laravel --set image.tag=test-sha
   git add charts/laravel/values.yaml
   git commit -m "ops: restore app_database from app-<UTC stamp>.sql.gz"
   git push origin main
   argocd app sync app --timeout 1800
   argocd app wait app --operation --timeout 1800
   kubectl -n app get job -l app.kubernetes.io/component=mysql-restore
   kubectl -n app logs -l app.kubernetes.io/component=mysql-restore --tail=-1
   ```

   The sync operation must succeed and the Job log must end with the
   `migrations` count and `restore succeeded`. A failed restore fails the sync
   operation at wave 2 (the migration Job and the Deployment are not applied)
   and leaves the database in the state the failing statement produced; fix the
   cause and re-run by committing a corrected `restore.dumpFile`, which creates
   a new Job.

4. Disable the restore and resume normal operation. Set `restore.enabled` back
   to `false` and `restore.dumpFile` to `""`, commit, push, and sync (the
   migration Job runs again and is a no-op; the completed restore Job is not
   pruned because it is a hook, so delete it by hand). Then restore the
   `spec.syncPolicy.automated` block in the infrastructure repository, push,
   re-apply `argocd/apps/app-app.yaml` the same way as in step 1, and require
   `Synced`/`Healthy`:

   ```bash
   kubectl -n app rollout status deployment/laravel --timeout=5m
   kubectl -n app delete job -l app.kubernetes.io/component=mysql-restore
   kubectl -n argocd get application app -o jsonpath='{.spec.syncPolicy.automated}{"\n"}'
   kubectl -n argocd get application app
   ```

## Rollback

To roll back, commit a previously known-good full image SHA to
`charts/laravel/values.yaml`, run the render checks above, and let Argo CD
reconcile that commit. Do not retag or overwrite a published GHCR image.
