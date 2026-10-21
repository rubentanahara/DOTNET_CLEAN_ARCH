SOLUTION := $(firstword $(wildcard *.slnx))
API_PROJECT := $(firstword $(wildcard src/*.Api/*.Api.csproj))
LOGS := .agent
SMOKE_URL := http://127.0.0.1:5098
SMOKE_TIMEOUT_SECONDS := 30

.PHONY: check setup build test lint format smoke run clean

check: build lint test smoke
	@echo "CHECK PASSED: build, format, tests, smoke"

setup:
	dotnet tool restore
	dotnet husky install
	dotnet restore $(SOLUTION)
	@command -v gitleaks >/dev/null || echo "WARNING: gitleaks is not installed; the pre-commit hook needs it."
	@command -v jq >/dev/null || echo "WARNING: jq is not installed; scripts/agent/feature.sh needs it."

build:
	@mkdir -p $(LOGS)
	@dotnet build $(SOLUTION) -nologo -v q > $(LOGS)/build.log 2>&1 || { \
		grep -E ": (error|warning) " $(LOGS)/build.log | sed "s|$(CURDIR)/||g; s| \[.*\]$$||" | sort -u | head -20; \
		echo "CHECK FAILED at build. Errors above, full log in $(LOGS)/build.log. Warnings are errors here. Fix them, then run make check."; \
		exit 1; }

lint:
	@mkdir -p $(LOGS)
	@dotnet format $(SOLUTION) --verify-no-changes > $(LOGS)/lint.log 2>&1 || { \
		grep -E "(error|warning) " $(LOGS)/lint.log | sed "s|$(CURDIR)/||g; s| \[.*\]$$||" | sort -u | head -20; \
		echo "CHECK FAILED at format. Run make format to fix it automatically, then run make check."; \
		exit 1; }

test: build
	@dotnet test $(SOLUTION) --no-build > $(LOGS)/test.log 2>&1 || { \
		grep -E -A3 "^ +Failed |error " $(LOGS)/test.log | head -40; \
		echo "CHECK FAILED at tests. Failing tests above, full log in $(LOGS)/test.log. Fix the code, not the test, unless the test is wrong."; \
		exit 1; }

smoke: build
	@dotnet run --project $(API_PROJECT) --no-build --urls $(SMOKE_URL) > $(LOGS)/smoke.log 2>&1 & pid=$$!; \
	for i in $$(seq $(SMOKE_TIMEOUT_SECONDS)); do \
		curl -fsS $(SMOKE_URL)/health > /dev/null 2>&1 && { kill $$pid; exit 0; }; \
		kill -0 $$pid 2>/dev/null || break; sleep 1; \
	done; \
	kill $$pid 2>/dev/null; tail -20 $(LOGS)/smoke.log; \
	echo "CHECK FAILED at smoke. The API did not answer $(SMOKE_URL)/health. Startup output above, full log in $(LOGS)/smoke.log."; \
	exit 1

format:
	dotnet format $(SOLUTION)

run:
	dotnet run --project $(API_PROJECT)

clean:
	rm -rf artifacts $(LOGS)
