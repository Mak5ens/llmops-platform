# Runbook: restore a PostgreSQL cluster from its backups

Use it when a database is lost or corrupted (a bad migration, a deleted table), or to check what it held at a given time.
The procedure is the one `scripts/restore-check.sh` runs on every PR, on `litellm-db`.

Backups ([ADR-018](../adr/018-postgresql-cloudnativepg.md)): a base backup every night at 03:00 and one when the cluster is created, plus WAL archived continuously, kept 7 days in S3 (SeaweedFS locally, Scaleway Object Storage in the cloud), under `s3://postgres-backups/<cluster>/`.
Any point in time of the last 7 days can be restored.

A restore always creates a **new cluster**: the damaged one stays as it is until the restored one has been checked.

## 1. Check what can be restored

```bash
kubectl -n llm-gateway get backups.postgresql.cnpg.io
# Recovery window of each cluster backed up to this store: first point, last base backup
kubectl -n llm-gateway get objectstore backups -o jsonpath='{.status.serverRecoveryWindow}{"\n"}'
```

If there is no `completed` backup, or the cluster's `ContinuousArchiving` condition is not `True`, stop here and look at the logs of the `plugin-barman-cloud` sidecar of the primary.

## 2. Restore into a new cluster

Write `restore.yaml`. Without `recoveryTarget`, the restore replays every archived WAL, up to the last commit that reached S3. To stop before an incident, set a time just before it (UTC):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: litellm-db-restored
  namespace: llm-gateway
spec:
  instances: 2
  storage:
    size: 1Gi
  bootstrap:
    recovery:
      source: origin
      # recoveryTarget:
      #   targetTime: "2026-10-06 14:30:00+00"
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: backups
          serverName: litellm-db
```

```bash
kubectl apply -f restore.yaml
kubectl -n llm-gateway wait --for=condition=Ready cluster/litellm-db-restored --timeout=15m
```

About 50 seconds locally for a small database; mostly the time to download the base backup and replay the WAL.

The restored cluster does not archive anything: it cannot overwrite the backups of `litellm-db`.

## 3. Check the data

```bash
kubectl -n llm-gateway exec -it litellm-db-restored-1 -c postgres -- psql -U postgres -d litellm
```

Compare with what you expect: last rows of the tables involved in the incident, row counts.

## 4. Switch the application to the restored data

The restored cluster has its own Services (`litellm-db-restored-rw`) and credentials (`litellm-db-restored-app`). The simplest switch, which keeps the name every manifest uses:

1. Stop the application (scale its Deployment to 0), so that nothing writes during the switch.
2. In Git, in the overlay of the environment concerned (not in `base`, or every new cluster would try to restore), patch `litellm-db`:
   - add a `bootstrap.recovery` section and an `externalClusters` entry like the ones above, with `serverName: litellm-db` and, if needed, the same `recoveryTarget`;
   - archive under a new name, `plugins[0].parameters.serverName: litellm-db-v2`, otherwise the new cluster would write over the backups it restores from.
3. Once ArgoCD has synced the change, delete the damaged cluster: `kubectl -n llm-gateway delete cluster litellm-db`. ArgoCD recreates it from Git, restored from the backups.
4. Scale the application back up, then delete `litellm-db-restored`.

Restoring under the same name while archiving under a new `serverName` was rehearsed on the local cluster on 2026-10-06: restored in 37 s, archiving resumed under `litellm-db-v2`.

## 5. Afterwards

- Check that `litellm-db` is `Cluster in healthy state` and that its `ContinuousArchiving` condition is `True` again.
- Take a base backup straight away, rather than waiting for the night:

  ```bash
  kubectl apply -f - <<EOF
  apiVersion: postgresql.cnpg.io/v1
  kind: Backup
  metadata:
    name: litellm-db-after-restore
    namespace: llm-gateway
  spec:
    cluster:
      name: litellm-db
    method: plugin
    pluginConfiguration:
      name: barman-cloud.cloudnative-pg.io
  EOF
  ```

- Write down what happened, when, and the recovery point used.
