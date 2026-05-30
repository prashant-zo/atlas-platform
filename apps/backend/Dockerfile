FROM golang:1.24-alpine AS build

WORKDIR /src

COPY go.mod go.sum ./

RUN go mod download

COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-w -s" \
    -o /out/atlas-backend .

FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /

COPY --from=build /out/atlas-backend /atlas-backend

USER nonroot:nonroot

EXPOSE 5678

ENTRYPOINT ["/atlas-backend"]
