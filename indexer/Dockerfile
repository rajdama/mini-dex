FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /indexer ./cmd/indexer

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /indexer /indexer
EXPOSE 8080
ENTRYPOINT ["/indexer"]
