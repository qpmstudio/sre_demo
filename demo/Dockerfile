# Stage 1: build
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -o /demo-app .

# Stage 2: run
FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=builder /demo-app /demo-app
EXPOSE 8080
ENTRYPOINT ["/demo-app"]
