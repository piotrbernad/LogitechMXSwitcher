#!/bin/bash
# Shell scripts must stay pure ASCII. Under a UTF-8 locale bash reads a multibyte
# character next to an expansion as part of the variable name, so "$app..." with a
# typographic ellipsis becomes an unbound variable and `set -u` kills the build.
# That failure is invisible in a C locale, which is exactly how it got shipped.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

status=0
for script in Scripts/*.sh Makefile; do
    if LC_ALL=C grep -n '[^ -~	]' "${script}"; then
        echo "  ^^ ${script} contains non-ASCII bytes, see Scripts/lint.sh" >&2
        status=1
    fi
    case "${script}" in *.sh) bash -n "${script}" || status=1 ;; esac
done

if [ "${status}" -eq 0 ]; then
    echo "shell lint clean"
fi
exit "${status}"
