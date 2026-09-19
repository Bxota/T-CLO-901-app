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

## Rollback

To roll back, commit a previously known-good full image SHA to
`charts/laravel/values.yaml`, run the render checks above, and let Argo CD
reconcile that commit. Do not retag or overwrite a published GHCR image.
