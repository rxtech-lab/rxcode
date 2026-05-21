SWIFTLINT ?= swiftlint

.PHONY: lint lint-ci

lint:
	$(SWIFTLINT) lint --config .swiftlint.yml --quiet --no-cache

lint-ci:
	$(SWIFTLINT) lint --config .swiftlint.yml --reporter github-actions-logging --quiet --no-cache
