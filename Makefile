.PHONY: build test vet

build:
	go build -trimpath -o bin/sspanel-hy2-adapter ./cmd/sspanel-hy2-adapter

test:
	go test ./...

vet:
	go vet ./...
