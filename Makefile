NVIM ?= nvim
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

CONTRACT_TESTS := \
	android-workbench-api.lua \
	android-workbench-health.lua \
	android-workbench-core.lua \
	android-workbench-state.lua \
	android-workbench-device.lua \
	android-workbench-discovery.lua \
	android-workbench-model.lua \
	android-workbench-problems.lua \
	android-workbench-runner.lua \
	android-workbench-adb.lua \
	android-workbench-emulator.lua \
	android-workbench-execution.lua \
	android-workbench-logcat.lua

CONTRACT_TESTS += android-workbench-telescope.lua

.DEFAULT_GOAL := test

.PHONY: test test-contract test-package test-format
test: test-contract test-package

test-contract:
	@set -eu; \
	test_tmp="$$(mktemp -d "$${TMPDIR:-/tmp}/android-workbench-contract.XXXXXX")"; \
	trap 'rm -rf "$$test_tmp"' EXIT HUP INT TERM; \
	for test in $(CONTRACT_TESTS); do \
		echo "==> $$test"; \
		suite="$${test%.lua}"; \
		env \
			ANDROID_WORKBENCH_TEST_ROOT="$(ROOT)" \
			NVIM_APPNAME=android-workbench-test \
			XDG_CONFIG_HOME="$$test_tmp/$$suite/config" \
			XDG_DATA_HOME="$$test_tmp/$$suite/data" \
			XDG_STATE_HOME="$$test_tmp/$$suite/state" \
			XDG_CACHE_HOME="$$test_tmp/$$suite/cache" \
			"$(NVIM)" --headless -u "$(ROOT)/tests/minimal_init.lua" -i NONE \
			"+luafile $(ROOT)/tests/$$test"; \
	done

test-package:
	@set -eu; \
	test_tmp="$$(mktemp -d "$${TMPDIR:-/tmp}/android-workbench-package.XXXXXX")"; \
	trap 'rm -rf "$$test_tmp"' EXIT HUP INT TERM; \
	env \
		ANDROID_WORKBENCH_TEST_ROOT="$(ROOT)" \
		NVIM_APPNAME=android-workbench-test \
		XDG_CONFIG_HOME="$$test_tmp/config" \
		XDG_DATA_HOME="$$test_tmp/data" \
		XDG_STATE_HOME="$$test_tmp/state" \
		XDG_CACHE_HOME="$$test_tmp/cache" \
		"$(NVIM)" --headless -u "$(ROOT)/tests/minimal_init.lua" -i NONE \
		"+luafile $(ROOT)/tests/package-smoke.lua"; \
	env \
		ANDROID_WORKBENCH_TEST_ROOT="$(ROOT)" \
		NVIM_APPNAME=android-workbench-test \
		XDG_CONFIG_HOME="$$test_tmp/collision/config" \
		XDG_DATA_HOME="$$test_tmp/collision/data" \
		XDG_STATE_HOME="$$test_tmp/collision/state" \
		XDG_CACHE_HOME="$$test_tmp/collision/cache" \
		"$(NVIM)" --headless -u "$(ROOT)/tests/collision_init.lua" -i NONE \
		"+luafile $(ROOT)/tests/package-collision-smoke.lua"

test-format:
	stylua --check lua plugin tests
