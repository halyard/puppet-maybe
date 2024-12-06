#!/usr/bin/env bash

set -euo pipefail

backupdir="$1"
file="dump_$(date "+%Y%m%d-%H%M%S").sql"

docker exec -t postgres pg_dumpall -c -U maybe_user > "$backupdir/$file"

