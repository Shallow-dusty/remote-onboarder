FROM scratch
COPY log-receiver /log-receiver
ENTRYPOINT ["/log-receiver", "-addr=:8080", "-data=/data"]
