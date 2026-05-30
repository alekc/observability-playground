# syntax=docker/dockerfile:1

###############################################################################
# Build stage
###############################################################################
FROM golang:1.25-alpine AS build

WORKDIR /src

# Cache module downloads independently of source changes.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# Static, stripped binary. CGO off so it runs on distroless/scratch.
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath -ldflags="-s -w" \
    -o /out/app .

###############################################################################
# Runtime stage
#
# distroless/static:nonroot ships no shell and runs as uid 65532, which keeps
# the attack surface minimal. Swap for scratch if you want zero base layers,
# distroless is chosen here because it carries CA certs and /etc/passwd.
###############################################################################
FROM gcr.io/distroless/static:nonroot

WORKDIR /
COPY --from=build /out/app /app

USER nonroot:nonroot
EXPOSE 8080

ENTRYPOINT ["/app"]
