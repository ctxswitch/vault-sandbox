CLUSTER ?= vault-demo

LOCALBIN ?= $(shell pwd)/bin

KUBECTL ?= kubectl

KUSTOMIZE ?= $(LOCALBIN)/kustomize
KUSTOMIZE_VERSION ?= v5.4.2

K3D ?= $(LOCALBIN)/k3d
K3D_VERSION ?= v5.7.4

.PHONY: cluster
cluster: $(K3D)
	@if $(K3D) cluster get $(CLUSTER) --no-headers >/dev/null 2>&1;  \
		then echo "Cluster exists, skipping creation"; \
		else k3d cluster create --config config/k3d/config.yaml --volume $(PWD):/app; \
		fi
	@$(KUBECTL) cluster-info

.PHONY: install
install: install-vault install-kubegres install-postgres

.PHONY: install-kubegres
install-kubegres: $(KUSTOMIZE)
	@$(KUSTOMIZE) build config/kubegres | envsubst | kubectl apply -f -
	@$(KUBECTL) wait --for=condition=available --timeout=120s deploy -l app.kubernetes.io/component=manager -n kubegres-system

install-postgres: $(KUSTOMIZE)
	@source vars.sh && @$(KUSTOMIZE) build config/postgres | envsubst | kubectl apply -f -
	@$(KUBECTL) rollout status --watch --timeout=600s statefulset/postgres-1

.PHONY: install-vault
install-vault: $(KUSTOMIZE)
	@$(KUSTOMIZE) build config/vault | envsubst | kubectl apply -f -

.PHONY: demo
demo: $(KUSTOMIZE)
	@source vars.sh && $(KUSTOMIZE) build config/demo | envsubst | kubectl apply -f -

.PHONY: init
init:
	@source vars.sh && psql -f init.sql

deps: $(KUSTOMIZE) $(K3D)

$(LOCALBIN):
	@mkdir -p $(LOCALBIN)

$(KUSTOMIZE): $(LOCALBIN)
	@test -s $(KUSTOMIZE) || \
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/kustomize/kustomize/v5@$(KUSTOMIZE_VERSION)

$(K3D): $(LOCALBIN)
	@test -s $(K3D) || \
	GOBIN=$(LOCALBIN) go install github.com/k3d-io/k3d/v5@$(K3D_VERSION)

.PHONY: clean
clean:
	@$(K3D) cluster delete $(CLUSTER)