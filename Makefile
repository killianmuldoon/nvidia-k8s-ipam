# Version information
include Makefile.version

SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
BUILD_DIR := ${PROJECT_DIR}/build

REGISTRY ?= ghcr.io/mellanox
IMAGE_TAG_BASE ?= $(REGISTRY)/nvidia-k8s-ipam
IMAGE_TAG ?= latest

# Image URL to use all building/pushing image targets
IMG ?= $(IMAGE_TAG_BASE):$(IMAGE_TAG)
DOCKERFILE ?= Dockerfile

# which container engine to use for image build/push
DOCKER_CMD ?= docker

# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.27.1

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

TARGET_OS ?= $(shell go env GOOS)
TARGET_ARCH ?= $(shell go env GOARCH)

# Options for go build command
GO_BUILD_OPTS ?= CGO_ENABLED=0 GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH)
# Linker flags for go build command
GO_LDFLAGS = $(VERSION_LDFLAGS)


PKGS = $(or $(PKG),$(shell cd $(PROJECT_DIR) && go list ./... | grep -v "^nvidia-k8s-ipam/vendor/" | grep -v ".*/mocks"))

.PHONY: all
all: build

##@ General

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

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: lint
lint: golangci-lint ## Lint code.
	$(GOLANGCILINT) run --timeout 10m

COVERAGE_MODE = atomic
COVER_PROFILE = $(PROJECT_DIR)/cover.out
LCOV_PATH =  $(PROJECT_DIR)/lcov.info

.PHONY: unit-test
unit-test: envtest ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" go test -covermode=$(COVERAGE_MODE) -coverprofile=$(COVER_PROFILE) $(PKGS)

.PHONY: test
test: lint unit-test

.PHONY: cov-report
cov-report: gcov2lcov unit-test  ## Build test coverage report in lcov format
	$(GCOV2LCOV) -infile $(COVER_PROFILE) -outfile $(LCOV_PATH)


##@ Build

.PHONY: build-controller
build-controller: ## build IPAM controller
	$(GO_BUILD_OPTS) go build -ldflags $(GO_LDFLAGS) -o $(BUILD_DIR)/ipam-controller ./cmd/ipam-controller/main.go

.PHONY: build-node
build-node: ## build IPAM node
	$(GO_BUILD_OPTS) go build -ldflags $(GO_LDFLAGS) -o $(BUILD_DIR)/ipam-node ./cmd/ipam-node/main.go

.PHONY: build-cni
build-cni: ## build IPAM cni
	$(GO_BUILD_OPTS) go build -ldflags $(GO_LDFLAGS) -o $(BUILD_DIR)/nv-ipam ./cmd/nv-ipam/main.go

.PHONY: build
build: build-controller build-node build-cni ## Build project binaries
	

.PHONY: docker-build
docker-build:  ## Build docker image with ipam binaries
	$(DOCKER_CMD) build -t $(IMG) -f $(DOCKERFILE) .

.PHONY: docker-push
docker-push: ## Push docker image with ipam binaries
	$(DOCKER_CMD) push $(IMG)


KIND_CLUSTER ?= kind
.PHONY: kind-load-image
kind-load-image:  ## Load ipam image to kind cluster
	kind load docker-image --name $(KIND_CLUSTER) $(IMG)

.PHONY: generate-mocks
generate-mocks:  ## generate mock objects
	PATH=$(PATH):$(LOCALBIN) go generate ./...

## Location to install dependencies to
LOCALBIN ?= $(PROJECT_DIR)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
ENVTEST ?= $(LOCALBIN)/setup-envtest
GOLANGCILINT ?= $(LOCALBIN)/golangci-lint
GCOV2LCOV ?= $(LOCALBIN)/gcov2lcov
MOCKERY ?= $(LOCALBIN)/mockery

## Tool Versions
GOLANGCILINT_VERSION ?= v1.52.2
GCOV2LCOV_VERSION ?= v1.0.5
MOCKERY_VERSION ?= v2.27.1

.PHONY: envtest
envtest: $(ENVTEST) ## Download envtest-setup locally if necessary.
$(ENVTEST): | $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest

.PHONY: golangci-lint
golangci-lint: $(GOLANGCILINT) ## Download golangci-lint locally if necessary.
$(GOLANGCILINT): | $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install github.com/golangci/golangci-lint/cmd/golangci-lint@$(GOLANGCILINT_VERSION)

.PHONY: gcov2lcov
gcov2lcov: $(GCOV2LCOV) ## Download gcov2lcov locally if necessary.
$(GCOV2LCOV): | $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install github.com/jandelgado/gcov2lcov@$(GCOV2LCOV_VERSION)

.PHONY: mockery
mockery: $(MOCKERY) ## Download gcov2lcov locally if necessary.
$(MOCKERY): | $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install github.com/vektra/mockery/v2@$(MOCKERY_VERSION)

.PHONY: clean
clean: ## Remove downloaded tools and compiled binaries
	@rm -rf $(LOCALBIN)
	@rm -rf $(BUILD_DIR)
