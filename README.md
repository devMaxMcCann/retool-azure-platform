# Retool platform on Azure

Self-hosted Retool on Azure Kubernetes Service, built entirely in Terraform, fed by
a public-data ingestion pipeline where every source carries a citation for why it
is legal to publish.

- **Live demo (public):** https://demo.retool.maxmccann.us — company risk, ingestion feeds, sources, architecture
- **Write-up:** https://maxmccann.us/retool-platform.html
- **JSON API (read-only):** `https://demo.retool.maxmccann.us/api/companies`, `/api/company/<id>`, `/api/feeds`

## What's here

| Path | What it is |
|---|---|
| `infra/bootstrap/` | Terraform state storage: Entra ID auth only, IP-allowlisted, versioned |
| `infra/platform/` | The platform: VNet + NAT, AKS, App Gateway (AGIC), Let's Encrypt via DNS-01, PostgreSQL Flexible Servers, Key Vault, Container Registry, Retool prod + nonprod (Retool's Helm chart), Infisical, the ingestion CronJobs and the dashboard |
| `infra/secrets/` | Infisical configuration: one project, a folder and a Kubernetes-auth identity per consumer, passwords copied from Key Vault with ephemeral reads (never in state) |
| `infra/vendor/` | How Retool's own Terraform modules are fetched and patched (see below) |
| `ingest/` | One loader per public source, run as Kubernetes CronJobs, plus the analytics build |
| `dashboard/` | The read-only public dashboard and JSON API |
| `data/` | The publication review: per-source licence citations and publish decisions |

## Design notes

- **Retool's official modules, not a fork.** The platform composes Retool's Azure
  blueprint modules. Reviewing every plan before applying it found three defects in
  them (Key Vault access stripped on the second apply, ingress controller hard-wired
  to one namespace, an ingress-class mismatch that silently returned 502s). Retool's
  repository publishes no licence, so its code is not stored here: `make vendor`
  downloads the exact release and applies the documented patches
  ([infra/vendor/PATCHES.md](infra/vendor/PATCHES.md)).
- **Nonprod upgrade lane.** Prod and nonprod Retool run in separate namespaces with
  separate databases and secrets, behind one App Gateway. Version bumps land in
  nonprod first.
- **Least privilege for data.** Loaders write only rows that pass the publication
  filters. Apps and the dashboard read a published schema as a read-only role with
  no access to the raw database.
- **Secrets.** Key Vault is the root of trust; Infisical (private, no public route)
  hands each consumer its own credentials.
- **Polite, honest ingestion.** One User-Agent with a contact address, robots.txt
  read per host, and a 401/403/429 is recorded and never worked around.

## Running it

```bash
make login            # az login
make bootstrap        # once: state storage
make init ENV=demo    # fetches + patches Retool's modules, then terraform init
make plan ENV=demo && make apply ENV=demo
```

Per-operator values (subscription, admin CIDRs, image tags) go in
`infra/platform/local.auto.tfvars`, which is gitignored.

## Attribution

Architecture icons: Microsoft Azure Architecture Icons (per Microsoft's icon terms),
the Kubernetes icon set (Apache-2.0 / CC-BY-4.0), and the PostgreSQL Slonik logo —
see [dashboard/icons/ATTRIBUTION.md](dashboard/icons/ATTRIBUTION.md).
