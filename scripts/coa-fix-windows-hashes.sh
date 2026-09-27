#!/usr/bin/env bash
# One-time step after importing a database produced on Windows (the repack dump), before the first worldserver start.
# Windows hashes SQL updates after converting CRLF to LF; Linux hashes the raw bytes. For every update file with CRLF
# line endings whose recorded hash matches its LF form, record the Linux hash so worldserver does not re-apply it.
# Usage: coa-fix-windows-hashes.sh <source-dir>    (e.g. /opt/coa/releases/<id>/source). Uses ~/.my.cnf.
set -euo pipefail

SOURCE="${1:?usage: $0 <source-dir>}"
[[ -d "$SOURCE/data/sql" ]] || { echo "error: $SOURCE/data/sql not found" >&2; exit 1; }

sha1_upper() { sha1sum | cut -c1-40 | tr 'a-f' 'A-F'; }

fixed=0
for db in auth characters world; do
    while IFS= read -r file; do
        grep -q $'\r' "$file" || continue
        name="$(basename "$file")"
        recorded="$(mysql -N -B -e "SELECT hash FROM acore_$db.updates WHERE name = '$name'")"
        [[ -n "$recorded" ]] || continue
        linux="$(sha1_upper < "$file")"
        windows="$(sed 's/\r$//' "$file" | sha1_upper)"
        if [[ "$recorded" == "$windows" && "$recorded" != "$linux" ]]; then
            mysql -e "UPDATE acore_$db.updates SET hash = '$linux' WHERE name = '$name' AND hash = '$recorded'"
            echo "acore_$db: $name ${recorded:0:7} -> ${linux:0:7}"
            fixed=$((fixed + 1))
        fi
    done < <(find "$SOURCE/data/sql" "$SOURCE/modules" -type f -name '*.sql' \
                 \( -path "*db_$db/*" -o -path "*db-$db/*" \) 2>/dev/null)
done
echo "$fixed hash(es) converted"
