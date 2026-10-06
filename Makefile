.PHONY: build test test-shell test-native-install vet

build:
	go build -trimpath -o bin/sspanel-hy2-adapter ./cmd/sspanel-hy2-adapter

test:
	go test ./...

test-shell:
	./scripts/test-sync-panel-port.sh
	sh ./scripts/test-native-manager.sh

vet:
	go vet ./...

test-native-install:
	sh scripts/test-install-anytls.sh
