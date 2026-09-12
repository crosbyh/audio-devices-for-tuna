SCHEME := AudioDevicesExtension

.DEFAULT_GOAL := build
.PHONY: build release test install install-restart package logs clean

build:
	@./scripts/tuna-extension build --scheme $(SCHEME)

release:
	@./scripts/tuna-extension build --scheme $(SCHEME) --release

test:
	@./scripts/tuna-extension test --scheme $(SCHEME)

install:
	@./scripts/tuna-extension install --scheme $(SCHEME)

install-restart:
	@./scripts/tuna-extension install --scheme $(SCHEME) --restart

package:
	@./scripts/tuna-extension package --scheme $(SCHEME)

logs:
	@./scripts/tuna-extension logs --last 20m

clean:
	rm -rf ./build ./dist
