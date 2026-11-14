.DEFAULT_GOAL := help
export VERSION

.PHONY: help build run release release-check release-verify
help:
	@echo 'make build                         Build and verify the locally signed app'
	@echo 'make run                           Build, verify and open the local app'
	@echo 'make release                       Publish the next patch after the highest local or origin vX.Y.Z tag'
	@echo 'make release VERSION=X.Y.Z         Publish a specific version from this Mac'
	@echo 'make release-check VERSION=X.Y.Z   Test and sign locally without publishing'
	@echo 'make release-verify VERSION=X.Y.Z  Verify the current public update'

build:
	@Scripts/build-local.sh

run:
	@Scripts/build-local.sh --run

release:
	@Scripts/release.sh local "$$VERSION"

release-check:
	@Scripts/release.sh prepare "$$VERSION"

release-verify:
	@Scripts/release.sh verify "$$VERSION"
