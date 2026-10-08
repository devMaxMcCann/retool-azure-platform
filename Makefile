# Day-to-day operations. Everything is `make <target>` so the runbooks and
# Azure DevOps pipelines call the same entry points a human does.
TF      := terraform -chdir=infra/platform
ENV     ?= demo
RG      ?= rtl-platform
AKS     ?= rtl-aks

.PHONY: login bootstrap init plan apply stop start status infisical-ui kubeconfig destroy \
        secrets-init secrets-plan secrets-apply ingest-image dashboard-image ingest-run ingest-status

login:            ## az login (interactive, once per session)
	az login --only-show-errors >/dev/null && az account show --query "{sub:id,name:name,user:user.name}" -o table

bootstrap:        ## one-time: state storage account
	terraform -chdir=infra/bootstrap init -input=false
	terraform -chdir=infra/bootstrap apply

init:
	$(TF) init -input=false -backend-config=envs/$(ENV).backend.hcl

plan:
	$(TF) plan -var-file=envs/$(ENV).tfvars -out=$(ENV).tfplan

apply:
	$(TF) apply $(ENV).tfplan

# Cost control between demos: AKS and both Flexible Servers can be stopped
# (compute billing pauses; disks, NAT gateway and public IPs keep billing).
stop:
	az network application-gateway stop -g $(RG) -n rtl-appgw
	az aks stop -g $(RG) -n $(AKS)
	az postgres flexible-server stop -g $(RG) -n rtl-main
	az postgres flexible-server stop -g $(RG) -n rtl-data

start:
	az postgres flexible-server start -g $(RG) -n rtl-main
	az postgres flexible-server start -g $(RG) -n rtl-data
	az aks start -g $(RG) -n $(AKS)
	az network application-gateway start -g $(RG) -n rtl-appgw

status:
	az aks show -g $(RG) -n $(AKS) --query powerState.code -o tsv
	az postgres flexible-server list -g $(RG) --query "[].{name:name,state:state}" -o table

kubeconfig:
	az aks get-credentials -g $(RG) -n $(AKS) --overwrite-existing

infisical-ui:     ## private UI at http://localhost:8080
	kubectl -n infisical port-forward svc/infisical-infisical-standalone-infisical 8080:8080

# ---------- stage 2: Infisical (infra/secrets) ----------
# Needs `make infisical-ui` running in another terminal. The admin identity's
# credentials are read from the macOS Keychain into the environment for this
# one command only; they are never written to a file.
STF        := terraform -chdir=infra/secrets
INF_CREDS   = $$(security find-generic-password -a claude-code -s infisical-azure-admin -w)
INF_ENV     = INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=$$(echo "$(INF_CREDS)" | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientId"])') \
              INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=$$(echo "$(INF_CREDS)" | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientSecret"])')

secrets-init:
	$(STF) init -input=false -backend-config=../platform/envs/$(ENV).backend.hcl -backend-config=key=secrets.tfstate

secrets-plan:
	$(INF_ENV) $(STF) plan -out=secrets.tfplan

secrets-apply:
	$(INF_ENV) $(STF) apply secrets.tfplan

# ---------- ingestion image ----------
# Built inside Azure (ACR Tasks): no local Docker needed. Tag = UTC timestamp;
# CronJobs are pinned to a tag, never :latest.
ACR       = $$($(TF) output -raw acr_name)
TAG      ?= $(shell date -u +%Y%m%d-%H%M%S)

ingest-image:
	az acr build -r $(ACR) -t ingest:$(TAG) -f ingest/Dockerfile ingest
	@echo "built ingest:$(TAG)"

dashboard-image:
	az acr build -r $(ACR) -t dashboard:$(TAG) -f dashboard/Dockerfile dashboard
	@echo "built dashboard:$(TAG)"

# Run one step now instead of waiting for its schedule: make ingest-run STEP=warn
ingest-run:
	kubectl -n ingest create job $(STEP)-manual-$$(date +%s) --from=cronjob/$(STEP)

ingest-status:
	kubectl -n ingest get cronjobs,jobs

destroy:
	$(TF) destroy -var-file=envs/$(ENV).tfvars
