#!/bin/sh
printf '\033c\033]0;%s\a' MendiGo
base_path="$(dirname "$(realpath "$0")")"
"$base_path/server.x86_64" "$@"
