FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/sh tunnel \
    && echo 'tunnel:tunnel-fixture' | chpasswd \
    && install -d -m 0755 /run/sshd \
    && install -d -m 0700 -o tunnel -g tunnel /home/tunnel/.ssh
COPY sshd_config /etc/ssh/sshd_config
COPY start.sh /usr/local/bin/start-fixture
ENTRYPOINT ["/bin/sh", "/usr/local/bin/start-fixture"]
