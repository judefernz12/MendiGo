FROM ubuntu:22.04

WORKDIR /app

COPY server.x86_64 .
COPY server.pck .

RUN chmod +x server.x86_64

EXPOSE 12345/tcp

# No scene path here: exported binaries can't override the scene from the
# command line. The dedicated-server build boots into Server.tscn on its own
# (see run/main_scene.dedicated_server in project.godot and App.gd).
CMD ["./server.x86_64", "--headless"]
