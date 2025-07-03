# Build the controller by default.
.DEFAULT_GOAL := build

# Configure app identity from project metadata.
APP_NAME ?= $(shell cat APP)
APP_VERSION ?= $(shell cat VERSION)

# Configure image identity from project metadata and app identity.
IMG_REGISTRY ?= ghcr.io
IMG_NAME ?= sambatv/${APP_NAME}
IMG_TAG ?= ${APP_VERSION}
IMG ?= ${IMG_REGISTRY}/${IMG_NAME}:${IMG_TAG}

# Configure helm chart identity from app identity.
CHART = charts/${APP_NAME}

# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:deprecatedV1beta1CompatibilityPreserveUnknownFields=false"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

GOVERSION ?= 1.23

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

##@ Info

.PHONY: help
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
	@printf "\n\nConfiguration:\n\n"
	@printf "  Targets use the following environment variables and defaults:\n\n"
	@printf "  \033[36mAPP_NAME\033[0m      App name        [%s]\n" ${APP_NAME}
	@printf "  \033[36mAPP_VERSION\033[0m   App version     [%s]\n" ${APP_VERSION}
	@printf "  \033[36mIMG_REGISTRY\033[0m  Image registry  [%s]\n" ${IMG_REGISTRY}
	@printf "  \033[36mIMG_NAME\033[0m      Image name      [%s]\n" ${IMG_NAME}
	@printf "  \033[36mIMG_TAG\033[0m       Image tag       [%s]\n" ${IMG_TAG}
	@printf "  \033[36mIMG\033[0m           Image           [%s]\n" ${IMG}

.PHONY: env
env: ## Display project config environment variables
	@printf "\033[36mAPP_NAME\033[0m=${APP_NAME}\n"
	@printf "\033[36mAPP_VERSION\033[0m=${APP_VERSION}\n"
	@printf "\033[36mIMG_REGISTRY\033[0m=${IMG_REGISTRY}\n"
	@printf "\033[36mIMG_NAME\033[0m=${IMG_NAME}\n"
	@printf "\033[36mIMG_TAG\033[0m=${IMG_TAG}\n"
	@printf "\033[36mIMG\033[0m=${IMG}\n"

##@ Toolchain

CONTROLLER_GEN = $(shell pwd)/bin/controller-gen

.PHONY: controller-gen
controller-gen: ## Install controller-gen locally if necessary
	$(call go-get-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.17.2)

KUSTOMIZE = $(shell pwd)/bin/kustomize

# go-get-tool will 'go get' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go install $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: ## Format operator manager source code
	go fmt ./...

.PHONY: lint
lint: ## Lint operator manager source code
	go vet ./...

ENVTEST_ASSETS_DIR=$(shell pwd)/testbin

.PHONY: test
test: manifests generate fmt lint ## Test operator manager source code
	mkdir -p ${ENVTEST_ASSETS_DIR}
	test -f ${ENVTEST_ASSETS_DIR}/setup-envtest.sh || curl -sSLo ${ENVTEST_ASSETS_DIR}/setup-envtest.sh https://raw.githubusercontent.com/kubernetes-sigs/controller-runtime/v0.8.3/hack/setup-envtest.sh
	source ${ENVTEST_ASSETS_DIR}/setup-envtest.sh; fetch_envtest_tools $(ENVTEST_ASSETS_DIR); setup_envtest_env $(ENVTEST_ASSETS_DIR); go test ./... -coverprofile cover.out

.PHONY: build
build: generate fmt lint ## Build operator manager binary
	go build -o bin/manager main.go

.PHONY: run
run: manifests generate fmt lint ## Run operator manager
	go run ./main.go

.PHONY: clean
clean: ## Clean build artifacts
	rm -f cover.out
	rm -fr bin charts dist testbin

##@ Deployment

.PHONY: install
install: manifests ## Install operator CRDs in cluster
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: manifests ## Uninstall operator CRDs in cluster
	$(KUSTOMIZE) build config/crd | kubectl delete --ignore-not-found -f -

.PHONY: preview
preview: ## Preview deploy operator manager manifests
	$(KUSTOMIZE) build config/default

.PHONY: deploy
deploy: manifests ## Deploy operator manager in cluster
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: undeploy
undeploy: ## Undeploy operator manager in cluster
	$(KUSTOMIZE) build config/default | kubectl delete -f -

##@ Docker

.PHONY: docker-build
docker-build: ## Build docker image
	@echo 'building $(IMG)'
	DOCKER_BUILDKIT=1 docker build -t $(IMG) .

.PHONY: docker-scan
docker-scan: ## Scan docker image for vulnerabilities
	@echo 'scanning $(IMG)'
	docker scan --accept-license $(IMG)

.PHONY: docker-push
docker-push: ## Push docker image to repository
	@echo 'pushing $(IMG)'
	docker push $(IMG)

##@ Chart

.PHONY: chart-build
chart-build: manifests ## Build helm chart
	scripts/build-operator-helm-chart --src config/default --dst $(CHART)

.PHONY: chart-lint
chart-lint: ## Lint helm chart
	helm lint $(CHART)

.PHONY: chart-template
chart-template: ## Template helm chart
	helm template $(APP_NAME) $(CHART)

.PHONY: chart-install
chart-install: ## Install helm chart with default values
	helm install $(APP_NAME) $(CHART) --namespace $(APP_NAME) --create-namespace
