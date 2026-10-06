# ADR-018: PostgreSQL with CloudNativePG, backups to S3, SeaweedFS as the local S3

- **Status:** Accepted
- **Date:** 2026-10-06

## Context

LiteLLM and Langfuse each need a PostgreSQL database: keys, budgets and spend for the first, trace metadata, users and projects for the second.
Losing the LiteLLM database means losing every team's key and budget, so it needs a replica that takes over by itself, and backups that a restore has proven.
The same setup must run on k3d, in the CI and on Kapsule ([ADR-017](017-local-cluster-k3d.md)), and the backups need an S3 store in each environment.

The usual local S3, MinIO, is gone: no more binaries or images since October 2025, and the repository was archived on April 25, 2026.

## Options considered

For the database:

| Option | Pros | Cons |
| -- | -- | -- |
| A. CloudNativePG operator, v1.30.1 | CNCF project since 2025; failover, replicas, WAL archiving and point-in-time restore declared in one `Cluster` resource; the same YAML on k3d and Kapsule, so the CI tests the real setup | We run the database: upgrades, storage and monitoring are on us |
| B. Scaleway Managed Database | Nothing to operate; backups included | From €0.0156 an hour (about €11 a month) for the smallest node, per database; nothing equivalent on k3d or in the CI, so the local setup would differ from production |
| C. Zalando postgres-operator | Mature, used in production for years | Patroni and Spilo images of its own; a smaller community than CloudNativePG today |
| D. A PostgreSQL StatefulSet from a Helm chart | Simplest to start | No automatic failover; Bitnami, the most used chart, stopped publishing free versioned images in 2025 |

For backups, CloudNativePG's built-in Barman Cloud support is deprecated in favor of the Barman Cloud plugin, v0.15.1, which we use from the start.

For the local S3 store:

| Option | Pros | Cons |
| -- | -- | -- |
| A. SeaweedFS, v4.48 | Apache 2.0, active since 2015; `weed mini` runs everything in one process, about 65 MB of RAM at rest; buckets and access keys declared at startup | The S3 API is one feature among others (filer, WebDAV), not the core of the project |
| B. Garage | Light, built for self-hosting | Access keys and the storage layout are created with its CLI after startup, an imperative step outside Git; AGPL |
| C. RustFS | Drop-in replacement for MinIO, Apache 2.0 | 1.0 released on October 3, 2026: too young to bet on |
| D. MinIO | Most documented | Archived: no images, no security fixes |

## Decision

We choose **CloudNativePG**, one cluster per application (`litellm-db`, `langfuse-db`), with a primary and a replica on different nodes and synchronous replication.
Base backups (nightly, and one at creation) and continuous WAL archiving go to S3 through the **Barman Cloud plugin**, kept 7 days.
Locally, the S3 store is **SeaweedFS**; on Kapsule, Scaleway Object Storage.

The deciding argument is the CI: the failover and the restore run on every PR, against the same resources that will run on Kapsule.

## Consequences

- `scripts/postgres-check.sh` deletes the primary and checks that the replica takes over with the last commit (15 s measured locally). `scripts/restore-check.sh` restores a backup into a new cluster from S3 alone (about 50 s). The procedure is in the [restore runbook](../runbooks/postgres-restore.md).
- With synchronous replication, a commit waits for the replica: a few milliseconds more per write, in exchange for no lost transaction on failover. With no replica up, the primary keeps accepting writes (`dataDurability: preferred`), since availability matters more than durability for this data.
- Applications connect with the `<cluster>-app` Secret that CloudNativePG creates; no database password goes through Git or the secret manager.
- Two clusters of two instances add about 350 MB of RAM locally.
- We revisit this if operating PostgreSQL costs more time than a managed database costs money, or if the plugin's backups fail us on Kapsule.
