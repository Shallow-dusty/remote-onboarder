# Multi-stage build: the receiver is compiled from this directory, so a docker
# build needs no manually prepared binary. The previous single-stage Dockerfile
# copied "log-receiver" from a context that only contains the sources, so the
# documented docker deployment could not build at all.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go dashboard.html ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/log-receiver .

FROM scratch
COPY --from=build /out/log-receiver /log-receiver
ENTRYPOINT ["/log-receiver", "-addr=:8080", "-data=/data"]
