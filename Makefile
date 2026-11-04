.DEFAULT_GOAL := help
export VERSION

.PHONY: help release release-check release-verify
help:
	@echo 'make release VERSION=X.Y.Z         Test, sign and publish from this Mac'
	@echo 'make release-check VERSION=X.Y.Z   Test and sign locally without publishing'
	@echo 'make release-verify VERSION=X.Y.Z  Verify the current public update'

release:
	@Scripts/release.sh local "$$VERSION"

release-check:
	@Scripts/release.sh prepare "$$VERSION"

release-verify:
	@Scripts/release.sh verify "$$VERSION"
