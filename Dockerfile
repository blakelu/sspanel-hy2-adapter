ARG GO_VERSION=1.23
FROM golang:${GO_VERSION}-alpine AS build

ARG VERSION=dev
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -X main.version=${VERSION}" \
    -o /out/sspanel-hy2-adapter ./cmd/sspanel-hy2-adapter

FROM alpine:3.21
RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -S adapter \
    && adduser -S -G adapter adapter \
    && mkdir -p /etc/sspanel-hy2-adapter /app/data \
    && chown -R adapter:adapter /app/data
COPY --from=build /out/sspanel-hy2-adapter /usr/local/bin/sspanel-hy2-adapter
WORKDIR /app
USER adapter
VOLUME ["/app/data"]
ENTRYPOINT ["/usr/local/bin/sspanel-hy2-adapter"]
CMD ["-config", "/etc/sspanel-hy2-adapter/config.yaml"]
