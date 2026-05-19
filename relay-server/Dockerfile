FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/relay .

FROM gcr.io/distroless/static
COPY --from=build /out/relay /relay
EXPOSE 8787
ENTRYPOINT ["/relay"]
