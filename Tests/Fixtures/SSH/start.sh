set -eu
install -m 0600 /run/fixture-host-key /run/sshd/fixture_host_key
install -m 0600 -o tunnel -g tunnel /run/fixture-client.pub /home/tunnel/.ssh/authorized_keys
exec /usr/sbin/sshd -D -e
