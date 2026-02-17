# Pyroscope Services — Test Runner
#
# Prerequisites:
#   - Java 17+ (for compilation; projects target Java 11 or 21)
#   - Docker (for SOR integration tests using Testcontainers)
#
# Usage:
#   make test          — run all tests across all 4 subprojects
#   make test-jvm11    — run all JVM 11 tests
#   make test-jvm21    — run all JVM 21 tests
#   make test-bor      — run BOR tests (both JVM versions)
#   make test-sor      — run SOR tests (both JVM versions, requires Docker)
#   make test-unit     — run unit tests only (no Docker required)
#   make clean         — clean all build artifacts

SHELL := /bin/bash

.PHONY: test test-jvm11 test-jvm21 test-bor test-sor test-unit \
        test-jvm11-bor test-jvm11-sor test-jvm21-bor test-jvm21-sor \
        clean compile help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

test: test-jvm11 test-jvm21 ## Run all tests (requires Docker for SOR)

test-jvm11: test-jvm11-bor test-jvm11-sor ## Run all JVM 11 tests

test-jvm21: test-jvm21-bor test-jvm21-sor ## Run all JVM 21 tests

test-bor: test-jvm11-bor test-jvm21-bor ## Run all BOR tests

test-sor: test-jvm11-sor test-jvm21-sor ## Run all SOR tests (requires Docker)

test-unit: ## Run unit tests only (no Docker)
	./gradlew :faas-jvm11:bor:test --tests '*ProfileTypeTest' --tests '*PyroscopeClientExtractTest' --tests '*TriageRulesTest' --tests '*DiffComputationTest' --tests '*HotspotScorerTest'
	./gradlew :faas-jvm21:bor:test --tests '*ProfileTypeTest' --tests '*PyroscopeClientExtractTest' --tests '*TriageRulesTest' --tests '*DiffComputationTest' --tests '*HotspotScorerTest'
	./gradlew :faas-jvm11:sor:test --tests '*ProfileTypeTest' --tests '*PyroscopeClientExtractTest'
	./gradlew :faas-jvm21:sor:test --tests '*ProfileTypeTest' --tests '*PyroscopeClientExtractTest'

test-jvm11-bor: ## Run JVM 11 BOR tests
	./gradlew :faas-jvm11:bor:test

test-jvm11-sor: ## Run JVM 11 SOR tests (requires Docker)
	./gradlew :faas-jvm11:sor:test

test-jvm21-bor: ## Run JVM 21 BOR tests
	./gradlew :faas-jvm21:bor:test

test-jvm21-sor: ## Run JVM 21 SOR tests (requires Docker)
	./gradlew :faas-jvm21:sor:test

clean: ## Clean all build artifacts
	./gradlew clean

compile: ## Compile all projects (no tests)
	./gradlew compileJava compileTestJava
