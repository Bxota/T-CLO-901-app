# Application deployment runbook

This runbook operates the Laravel Helm chart in `charts/laravel`. Argo CD
reconciles committed chart changes; do not replace that flow with a manual
production `kubectl apply`.

## Image delivery contract

The `Build and publish application` workflow runs on pushes to `main` and on
manual dispatch. It installs dependencies and runs `php artisan test` before
it logs in to GHCR or pushes an image. A successful build publishes exactly
`ghcr.io/bxota/t-clo-901-app:${{ github.sha }}` and commits that full SHA into
`charts/laravel/values.yaml`. The chart must use this immutable SHA tag; do not
replace it with `latest` or another mutable tag.

The GHCR package remains private as specified in the deployment design's
section 7.
The workflow uses `GITHUB_TOKEN` with `packages: write` to publish. If
organization policy requires a separate publisher credential, configure the
repository `GHCR_PUSH_TOKEN` with only the required package-write scope and
use it for the publishing login under that policy. It is a CI-only credential:
never place it in the cluster. The cluster uses the separate read-only pull
credential described below.

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

The plaintext input file must remain outside the repository and be deleted
securely after sealing. Apply the same process to the Docker config JSON for
`ghcr-pull-secret`. Its token has read-only package-pull access only; it must
not be a GHCR push token. The deployment and migration Job reference
`mysql-credentials`, and their `imagePullSecrets` reference
`ghcr-pull-secret`.

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
Laravel pods, one MySQL pod, both EFS PVCs Bound, the migration hook completed,
and the daily backup and weekly restore-test CronJobs present. Investigate a
failed migration hook or an unbound PVC before retrying the rollout.

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
kubectl -n app get pvc mysql-data mysql-backups
kubectl -n app get svc laravel -o jsonpath='{.spec.ports[0].port}{"\n"}'
```

The expected evidence is `Synced` and `Healthy`, two Ready Laravel pods, a
Ready MySQL pod, Bound `mysql-data` and `mysql-backups` PVCs, a completed
migration Job, both backup CronJobs, and Service port `80`. Stop and diagnose
an unbound PVC, incomplete migration, or non-Healthy Application before any
resilience demo.

### Session and MySQL persistence check

This check deletes pods, so run it only in the controlled evidence cluster.
Record the PVC identity before the MySQL restart. The `/` request runs through
Laravel's `web` middleware and captures the session cookie; `/api/counter/add`
creates a durable counter record. Use the same cookie jar after each restart:

```bash
APP_URL="${APP_URL:?set this to the Laravel Service or route URL}"
COOKIE_JAR="$(mktemp)"

curl --fail --show-error --cookie-jar "$COOKIE_JAR" "$APP_URL/" >/dev/null
grep -q 'laravel_session' "$COOKIE_JAR"

LARAVEL_POD="$(kubectl -n app get pod -l app.kubernetes.io/name=laravel,app.kubernetes.io/instance=app \
  -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app delete pod "$LARAVEL_POD"
kubectl -n app rollout status deployment/laravel --timeout=5m
curl --fail --show-error --cookie "$COOKIE_JAR" "$APP_URL/" >/dev/null

curl --fail --show-error "$APP_URL/api/counter/add"
kubectl -n app get pvc mysql-data -o jsonpath='{.metadata.name}{"\n"}'
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
  | yq 'select(.kind == "Deployment" and .metadata.name == "laravel") \
        | {"replicas": .spec.replicas, "strategy": .spec.strategy.rollingUpdate, "readiness": (.spec.template.spec.containers[] | select(.name == "laravel") | .readinessProbe.httpGet.path)}'
git diff --check
git add charts/laravel/values.yaml
git commit -m "test: demonstrate failed Laravel readiness"
git push origin main
```

After Argo CD reconciles that commit, capture the failed rollout without
deleting healthy replicas:

```bash
kubectl -n app get pods -o wide
kubectl -n app describe deployment laravel
kubectl -n app rollout status deployment/laravel --timeout=90s || true
kubectl -n argocd get application app
```

With `maxUnavailable: 0` and `maxSurge: 1`, the old two pods remain Ready and
serving while no more than one new pod is created. The new pod remains NotReady
and the rollout must not report success. Argo CD must be out of `Healthy`
(normally `Progressing` before the Deployment progress deadline, then
`Degraded`); record the observed status rather than accepting a silent
replacement.

Restore the readiness path through a second Git commit (or a revert of the
temporary commit), then wait for Argo CD to make the rollout healthy again:

```bash
git revert --no-edit <broken-readiness-commit>
git push origin main
kubectl -n app rollout status deployment/laravel --timeout=5m
kubectl -n app get deployment/laravel pods
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

Capture the Job's `Complete` condition and logs with the evidence. The backup
script writes its gzip dump atomically under the `mysql-backups` PVC and checks
that the completed file is non-empty before it renames it; a completed Job is
therefore the directory-content evidence. A failed dump must leave the Job
failed and visible, not masquerade as a successful gzip file.

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

### Production data restore guard

The restore-test Job is the first and normal recovery check. Never load a dump
into a running MySQL pod or overwrite the live EFS data path with an ad-hoc
command. A production data replacement is a break-glass operation that requires
an operator-approved maintenance window, a newly verified backup, and a
reviewed restore Job committed through GitOps. Before that Job can replace live
data, pause reconciliation with a reviewed Git change: temporarily remove
`spec.syncPolicy.automated` from the root repository's
`infra/argocd/apps/app-app.yaml`, commit and push that change, and confirm the
Application has refreshed. Do not use an ad-hoc live patch for this normal
maintenance guard because Git reconciliation would undo it. Only then scale
Laravel to zero, stop the MySQL StatefulSet, and confirm both are stopped:

```bash
kubectl -n app scale deployment/laravel --replicas=0
kubectl -n app scale statefulset/mysql --replicas=0
kubectl -n app get deployment/laravel statefulset/mysql pods
```

Only the approved restore Job may replace the live data while MySQL is stopped.
After it completes and its restored data is validated, restore the committed
replica counts, restore the reviewed `spec.syncPolicy.automated` Git change,
resume Argo CD reconciliation, and require `Synced`/`Healthy`:

```bash
kubectl -n app scale statefulset/mysql --replicas=1
kubectl -n app rollout status statefulset/mysql --timeout=10m
kubectl -n app scale deployment/laravel --replicas=2
kubectl -n app rollout status deployment/laravel --timeout=5m
kubectl -n argocd get application app
```

## Rollback

To roll back, commit a previously known-good full image SHA to
`charts/laravel/values.yaml`, run the render checks above, and let Argo CD
reconcile that commit. Do not retag or overwrite a published GHCR image.
