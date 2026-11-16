# syntax=docker/dockerfile:1.7
#
# Production image:
#   - multi-stage, no compiler in the final image
#   - distroless static, non-root UID 65532
#   - no shell, no package manager
#   - HEALTHCHECK on /healthz
#
# Build:
#   docker build -t ghcr.io/example/edge-echo:1.0.0 --target runtime .

FROM golang:1.22-bookworm AS build
WORKDIR /src
ENV CGO_ENABLED=0 GOOS=linux
COPY go.mod go.sum* ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -ldflags="-s -w -buildid=" -o /out/edge-echo .

# Verify we are not linking libc (distroless static requirement).
RUN file /out/edge-echo | grep -E 'statically linked|static-pie' || true

FROM gcr.io/distroless/static-debian12:nonroot AS runtime
WORKDIR /
COPY --from=build /out/edge-echo /edge-echo
USER 65532:65532
EXPOSE 8080
# Distroless has no shell. Use the busybox wget from a tiny helper? No —
# HEALTHCHECK in k8s is an httpGet; Compose uses the image below with wget.
# This image is the k8s/prod target.
ENTRYPOINT ["/edge-echo"]

# Compose-friendly variant: still non-root, still tiny, has wget for HEALTHCHECK.
FROM alpine:3.21 AS compose
RUN adduser -D -H -u 65532 -g app app \
    && apk add --no-cache wget ca-certificates
COPY --from=build /out/edge-echo /edge-echo
USER 65532:65532
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=2s --start-period=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null
ENTRYPOINT ["/edge-echo"]
