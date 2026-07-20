FROM ubuntu:22.04

WORKDIR /app

COPY server.x86_64 .
COPY server.pck .

RUN chmod +x server.x86_64

EXPOSE 12345/tcp

CMD ["./server.x86_64", "--headless", "res://scenes/game/Server.tscn"]
