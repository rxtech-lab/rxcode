FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
# VERSION is stamped into main.version and surfaced at /healthz. Defaults to
# "dev"; the relay-deploy workflow passes the git release tag on release builds.
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -ldflags "-X main.version=${VERSION}" -o /out/relay .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/relay /relay
EXPOSE 8787
USER nonroot:nonroot
ENTRYPOINT ["/relay"]
