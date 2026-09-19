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
