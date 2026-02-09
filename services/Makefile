# Pyroscope Services — Test Runner
#
# Prerequisites:
#   - Java 17+ (for compilation; projects target Java 11 or 21)
#   - Docker (for SOR integration tests using Testcontainers)
#
# Usage:
#   make test          — run all tests across all 4 projects
#   make test-bor      — run BOR tests (Java 21 + Java 11)
#   make test-sor      — run SOR tests (Java 21 + Java 11, requires Docker)
#   make test-unit     — run unit tests only (no Docker required)
#   make test-<project> — run tests for a specific project
#   make clean         — clean all build artifacts

SHELL := /bin/bash

BOR      := pyroscope-bor
BOR11    := pyroscope-bor-java11
SOR      := pyroscope-sor
SOR11    := pyroscope-sor-java11
PROJECTS := $(BOR) $(BOR11) $(SOR) $(SOR11)

.PHONY: test test-bor test-sor test-unit clean help \
        test-bor-21 test-bor-11 test-sor-21 test-sor-11

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

test: test-bor test-sor ## Run all tests (requires Docker for SOR)

test-bor: test-bor-21 test-bor-11 ## Run all BOR tests

test-sor: test-sor-21 test-sor-11 ## Run all SOR tests (requires Docker)

test-unit: ## Run unit tests only (no Docker)
	cd $(BOR)   && ./gradlew test --tests '*ProfileTypeTest' --tests '*PyroscopeClientExtractTest' --tests '*TriageRulesTest' --tests '*DiffComputationTest' --tests '*HotspotScorerTest'
	cd $(BOR11) && ./gradlew test --tests '*ProfileTypeTest' --tests '*PyroscopeClientExtractTest' --tests '*TriageRulesTest' --tests '*DiffComputationTest' --tests '*HotspotScorerTest'
	cd $(SOR)   && ./gradlew test --tests '*ProfileTypeTest' --tests '*PyroscopeClientExtractTest'
	cd $(SOR11) && ./gradlew test --tests '*ProfileTypeTest' --tests '*PyroscopeClientExtractTest'

test-bor-21: ## Run pyroscope-bor (Java 21) tests
	cd $(BOR) && ./gradlew test

test-bor-11: ## Run pyroscope-bor-java11 tests
	cd $(BOR11) && ./gradlew test

test-sor-21: ## Run pyroscope-sor (Java 21) tests (requires Docker)
	cd $(SOR) && ./gradlew test

test-sor-11: ## Run pyroscope-sor-java11 tests (requires Docker)
	cd $(SOR11) && ./gradlew test

clean: ## Clean all build artifacts
	@for proj in $(PROJECTS); do \
		echo "Cleaning $$proj..."; \
		cd $$proj && ./gradlew clean && cd ..; \
	done

compile: ## Compile all projects (no tests)
	@for proj in $(PROJECTS); do \
		echo "Compiling $$proj..."; \
		cd $$proj && ./gradlew compileJava compileTestJava && cd ..; \
	done
