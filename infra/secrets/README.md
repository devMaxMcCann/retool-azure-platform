# infra/secrets: Infisical stage 2

`infra/platform` installs Infisical. This root configures it: the `data-platform`
project, one folder per consumer, the database credentials, and a Kubernetes-auth
machine identity per consuming namespace that can read only its own folder.

## One-time, by hand (needs a human admin session)

Infisical's first admin can't be created by Terraform (`autoBootstrap` is off on
purpose), and identity creation needs an admin session.

1. `make infisical-ui`, leave it running, open <http://localhost:8080>.
2. Sign up: this first account becomes the instance admin.
3. Create an organization if prompted. Copy its **Organization ID** from
   Organization Settings into `infra/secrets/local.auto.tfvars`:
   ```hcl
   subscription_id  = "..."            # same as infra/platform
   key_vault_name   = "rtl-mx1f-kv"    # infra/platform output key_vault_name
   infisical_org_id = "..."
   ```
4. Access Control → Machine Identities → **Create Identity**: name `terraform`,
   org role **Admin**, auth method **Universal Auth**. Create a client secret and
   store the Client ID and Client Secret in the macOS Keychain as one JSON value,
   so they never sit in a file or shell history:
   ```bash
   security add-generic-password -a "$USER" -s infisical-terraform \
     -w '{"clientId":"...","clientSecret":"..."}'
   ```
   The Makefile reads them from there for each `secrets-*` run
   (override with `KEYCHAIN_SERVICE=` / `KEYCHAIN_ACCOUNT=`).

## Every run

```bash
make infisical-ui    # in its own terminal
make secrets-init    # first time only
make secrets-plan
make secrets-apply
```

## What lands where

| Infisical folder | Consumer | Synced to |
|---|---|---|
| `/ingest` | loader CronJobs (SA `ingest/ingest`), role `ingest_loader` on `jobs_ingest` | Secret `ingest/pg-ingest` |
| `/analytics` | analytics builder (SA `ingest/analytics`), role `analytics_builder` on `jobs_analytics` | Secret `ingest/pg-analytics` |
| `/retool` | Retool's Postgres resource, role `retool_reader` on `jobs_analytics` | none: on Retool's free tier the resource is set up in the UI |

Each folder holds `PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PGSSLMODE`, so
libpq/psycopg connect with no app config.

## Where secrets do and don't end up

- DB passwords are read from Key Vault with **ephemeral** reads and written with
  **write-only** values: they are not in this root's state.
- The token reviewer's service-account JWT **is** in state (the provider has no
  write-only form for it). State is the AAD-auth storage account from
  `infra/bootstrap`. The token can only create TokenReviews.
- Rotating a DB password: change it in Key Vault, bump `password_version`, re-apply.
