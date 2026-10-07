# Day-to-day operations. Everything is `make <target>` so the runbooks and
# Azure DevOps pipelines call the same entry points a human does.
TF      := terraform -chdir=infra/platform
ENV     ?= demo
RG      ?= rtl-platform
AKS     ?= rtl-aks

.PHONY: login bootstrap init plan apply stop start status infisical-ui kubeconfig destroy

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

destroy:
	$(TF) destroy -var-file=envs/$(ENV).tfvars
