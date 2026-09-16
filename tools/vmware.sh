#!/bin/sh

set -eu

. "$(dirname "$0")/common.sh"

find_python
exec "$python" "$(native_path "$project/tools/vmware.py")" "$@"
