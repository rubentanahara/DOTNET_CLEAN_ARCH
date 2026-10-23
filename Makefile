ifeq ($(CODEX_SANDBOX),seatbelt)
$(error The Codex sandbox blocks the local sockets dotnet needs, so this would hang. Run the same make command again with escalated permissions. .codex/rules/dotnet.rules allows make outside the sandbox once the project is trusted)
endif

SOLUTION := $(firstword $(wildcard *.slnx))
API_PROJECT := $(firstword $(wildcard src/*.Api/*.Api.csproj))
LOGS := .agent
SMOKE_BIND_URL := http://127.0.0.1:0
SMOKE_TIMEOUT_SECONDS := 30

.PHONY: check setup build test lint format smoke hooks skills agents harness packages run clean

check: hooks skills agents harness packages build lint test smoke
	@echo "CHECK PASSED: hooks, skills, agents, harness, packages, build, format, tests, smoke"

setup:
	dotnet tool restore
	dotnet husky install
	dotnet restore $(SOLUTION)
	@command -v gitleaks >/dev/null || echo "WARNING: gitleaks is not installed; the pre-commit hook needs it."
	@command -v jq >/dev/null || echo "WARNING: jq is not installed; make check and the scripts in scripts/agent need it."

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
	@dotnet run --project $(API_PROJECT) --no-build --urls $(SMOKE_BIND_URL) > $(LOGS)/smoke.log 2>&1 & pid=$$!; \
	for i in $$(seq $(SMOKE_TIMEOUT_SECONDS)); do \
		url=$$(grep -oE 'Now listening on: http://[0-9.:]+' $(LOGS)/smoke.log | head -1 | cut -d' ' -f4); \
		[ -n "$$url" ] && curl -fsS $$url/health > /dev/null 2>&1 && { kill $$pid; exit 0; }; \
		kill -0 $$pid 2>/dev/null || break; sleep 1; \
	done; \
	kill $$pid 2>/dev/null; tail -20 $(LOGS)/smoke.log; \
	echo "CHECK FAILED at smoke. The API did not answer /health on the port it logged after 'Now listening on:'. Startup output above, full log in $(LOGS)/smoke.log."; \
	exit 1

hooks:
	@jq -n -e --slurpfile claude .claude/settings.json --slurpfile codex .codex/hooks.json '$$claude[0].hooks != null and $$claude[0].hooks == $$codex[0].hooks' > /dev/null || { \
		echo "CHECK FAILED at hooks. .codex/hooks.json differs from the hooks in .claude/settings.json. Edit .claude/settings.json, then run: jq '{hooks}' .claude/settings.json > .codex/hooks.json"; \
		exit 1; }

skills:
	@diff -r .agents/skills .claude/skills > /dev/null || { \
		echo "CHECK FAILED at skills. .claude/skills differs from .agents/skills. Edit .agents/skills, then run: rm -rf .claude/skills && cp -R .agents/skills .claude/skills"; \
		exit 1; }

agents:
	@generated=$$(mktemp -d); \
	bash scripts/agent/sync-agents.sh .claude/agents $$generated/agents && diff -r $$generated/agents .codex/agents > /dev/null; drift=$$?; \
	rm -rf $$generated; \
	[ $$drift -eq 0 ] || { \
		echo "CHECK FAILED at agents. .codex/agents differs from .claude/agents. Edit .claude/agents, then run: bash scripts/agent/sync-agents.sh"; \
		exit 1; }

harness:
	@mkdir -p $(LOGS)
	@{ bash scripts/agent/feature.test.sh && bash scripts/agent/run.test.sh && bash scripts/agent/github-sync.test.sh && bash scripts/agent/sync-agents.test.sh; } > $(LOGS)/harness.log 2>&1 || { \
		cat $(LOGS)/harness.log; \
		echo "CHECK FAILED at harness. A script in scripts/agent broke a rule its tests pin down. Fix the script, not the test, unless the rule changed."; \
		exit 1; }

packages:
	@unused=$$(grep -oE 'PackageVersion Include="[^"]+"' Directory.Packages.props | cut -d'"' -f2 | while read -r package; do \
		git grep -q --untracked "PackageReference Include=\"$$package\"" -- '*.csproj' '*.props' || printf ' %s' "$$package"; done); \
	[ -z "$$unused" ] || { \
		echo "CHECK FAILED at packages. Directory.Packages.props pins versions that no project references:$$unused. Remove them, or add the PackageReference that needs them."; \
		exit 1; }

format:
	dotnet format $(SOLUTION)

run:
	dotnet run --project $(API_PROJECT)

clean:
	rm -rf artifacts $(LOGS)
