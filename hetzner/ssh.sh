#!/bin/sh
# Opens an SSH session (or runs a command) on the demo server.
#   ./ssh.sh                              interactive shell
#   ./ssh.sh docker compose ps            run a command
#   ./ssh.sh -L 8000:127.0.0.1:8000       tunnel for the Django admin
set -e
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
# shellcheck disable=SC2046
exec ssh $(ssh_args) "root@$(server_ip)" "$@"
