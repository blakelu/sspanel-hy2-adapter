.PHONY: build test test-shell vet

build:
	go build -trimpath -o bin/sspanel-hy2-adapter ./cmd/sspanel-hy2-adapter

test:
	go test ./...

test-shell:
	./scripts/test-sync-panel-port.sh

vet:
	go vet ./...
