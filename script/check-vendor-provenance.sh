#!/usr/bin/env bash
#
# check-vendor-provenance.sh - prove that lib/ still matches its upstreams.
#
# For every dependency in lib/VENDOR-MANIFEST.json this script materialises the
# pinned upstream (shallow git fetch of the pinned commit, or the pinned npm
# tarball verified against its recorded sha512), applies the manifest's declared
# prunes and declared local modifications, and then diffs it against the
# vendored tree.
#
# Exit codes:
#   0  every dependency matches its pin
#   1  at least one dependency diverges (every divergent path is printed)
#   2  the check could not be performed (missing tool, bad manifest, network)
#
# Usage:
#   script/check-vendor-provenance.sh              # check everything
#   script/check-vendor-provenance.sh --dep NAME   # check one dependency
#   script/check-vendor-provenance.sh --keep       # keep the scratch dir
#
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="$REPO_ROOT/lib/VENDOR-MANIFEST.json"
ONLY_DEP=""
KEEP=0
MAX_DIFF_LINES=200

while [ $# -gt 0 ]; do
    case "$1" in
        --dep)
            ONLY_DEP="${2:-}"
            shift 2
            ;;
        --keep)
            KEEP=1
            shift
            ;;
        -h | --help)
            sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

die() {
    echo "ERROR: $*" >&2
    exit 2
}

for tool in git curl tar python3 diff openssl; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/vendor-provenance.XXXXXX")
cleanup() {
    if [ "$KEEP" -eq 1 ]; then
        echo "scratch dir kept: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# ---------------------------------------------------------------- manifest ---

dep_count=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["dependencies"]))' \
    "$MANIFEST") || die "cannot parse $MANIFEST"

dep_get() {
    # dep_get <index> <dotted.path> -> scalar ("" when absent)
    python3 - "$MANIFEST" "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["dependencies"][int(sys.argv[2])]
cur = d
for part in sys.argv[3].split("."):
    cur = cur.get(part) if isinstance(cur, dict) else None
    if cur is None:
        break
if isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print("" if cur is None else cur)
PY
}

dep_compare() {
    # dep_compare <index> -> "<upstream>\t<local>" per line
    python3 - "$MANIFEST" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["dependencies"][int(sys.argv[2])]
for pair in d.get("compare", []):
    print("%s\t%s" % (pair["upstream"], pair["local"]))
PY
}

dep_pruned() {
    python3 - "$MANIFEST" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["dependencies"][int(sys.argv[2])]
for p in d.get("pruned", []):
    print(p)
PY
}

dep_lmods() {
    # dep_lmods <index> -> "<path>\t<local_sha256>\t<reason>" per line
    python3 - "$MANIFEST" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["dependencies"][int(sys.argv[2])]
for mod in d.get("local_modifications", []):
    print("%s\t%s\t%s" % (mod["path"], mod.get("local_sha256", ""), mod.get("reason", "")))
PY
}

all_local_paths() {
    python3 - "$MANIFEST" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["dependencies"]:
    print(d["local_path"])
PY
}

# --------------------------------------------------------------- reporting ---

FAILED_DEPS=()

report() {
    echo "       $*"
}

normalize() {
    # Rewrite scratch/absolute prefixes into readable, repo-relative names.
    sed -e "s|$1/|upstream:|g" -e "s|$REPO_ROOT/||g"
}

# ---------------------------------------------------------- materialisation ---

materialize_git() {
    # materialize_git <dest> <repo> <ref> <submodules:true|false>
    local dest="$1" repo="$2" ref="$3" submodules="$4"
    mkdir -p "$dest" || return 1
    git -C "$dest" init -q || return 1
    git -C "$dest" remote add origin "$repo" || return 1
    # Shallow, single-commit fetch of the pinned sha: GitHub serves arbitrary
    # reachable SHAs, so neither a full clone nor a tag lookup is needed.
    git -C "$dest" fetch -q --depth 1 origin "$ref" || return 1
    git -C "$dest" checkout -q FETCH_HEAD || return 1
    if [ "$submodules" = "true" ]; then
        git -C "$dest" submodule update --init --recursive --depth 1 -q || return 1
    fi
    # Vendored copies carry no VCS metadata; drop it so the trees line up.
    find "$dest" -name .git -print0 | xargs -0 rm -rf
    return 0
}

materialize_npm() {
    # materialize_npm <dest> <tarball-url> <integrity> <name>
    local dest="$1" url="$2" want="$3" name="$4"
    local tgz="$WORK/$name.tgz"
    curl -fsSL "$url" -o "$tgz" || return 1
    local got
    got="sha512-$(openssl dgst -sha512 -binary "$tgz" | openssl base64 | tr -d '\n')"
    if [ "$got" != "$want" ]; then
        report "npm tarball integrity mismatch"
        report "expected $want"
        report "actual   $got"
        return 2
    fi
    mkdir -p "$dest" || return 1
    # npm tarballs are rooted at package/.
    tar -xzf "$tgz" -C "$dest" --strip-components=1 || return 1
    return 0
}

# -------------------------------------------------------------- main sweep ---

echo "vendor provenance check"
echo "  manifest: lib/VENDOR-MANIFEST.json ($dep_count dependencies)"
echo

checked=0
i=0
while [ "$i" -lt "$dep_count" ]; do
    name=$(dep_get "$i" name)
    local_path=$(dep_get "$i" local_path)
    stype=$(dep_get "$i" source.type)

    if [ -n "$ONLY_DEP" ] && [ "$ONLY_DEP" != "$name" ]; then
        i=$((i + 1))
        continue
    fi
    checked=$((checked + 1))

    local_root="$REPO_ROOT/$local_path"
    up="$WORK/up-$name"
    dep_failed=0

    if [ ! -d "$local_root" ]; then
        echo "FAIL   $name: vendored path missing"
        report "$local_path (declared in manifest, absent from the tree)"
        FAILED_DEPS+=("$name")
        i=$((i + 1))
        continue
    fi

    case "$stype" in
        git)
            repo=$(dep_get "$i" source.repo)
            ref=$(dep_get "$i" source.ref)
            submodules=$(dep_get "$i" source.submodules)
            pin_desc="git $repo @ ${ref:0:12}"
            if ! materialize_git "$up" "$repo" "$ref" "$submodules"; then
                die "$name: could not fetch $repo at $ref"
            fi
            ;;
        npm)
            pkg=$(dep_get "$i" source.package)
            version=$(dep_get "$i" source.version)
            tarball=$(dep_get "$i" source.tarball)
            integrity=$(dep_get "$i" source.integrity)
            pin_desc="npm $pkg @ $version"
            materialize_npm "$up" "$tarball" "$integrity" "$name"
            rc=$?
            if [ "$rc" -eq 2 ]; then
                echo "FAIL   $name  <-  $pin_desc  (tarball does not match pinned integrity)"
                FAILED_DEPS+=("$name")
                i=$((i + 1))
                continue
            elif [ "$rc" -ne 0 ]; then
                die "$name: could not download $tarball"
            fi
            ;;
        *)
            die "$name: unsupported source type '$stype'"
            ;;
    esac

    # Declared prunes: paths deliberately not vendored. Remove them upstream so
    # they cannot be reported as divergences.
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        rm -rf "${up:?}/$p"
    done < <(dep_pruned "$i")

    # Declared local modifications: verify the vendored file still hashes to the
    # recorded value, then stage that exact content upstream, so the tree diff
    # covers everything except the recorded, pinned divergence.
    while IFS=$'\t' read -r mpath msha mreason; do
        [ -z "$mpath" ] && continue
        if [ ! -f "$local_root/$mpath" ]; then
            dep_failed=1
            report "$local_path/$mpath (declared local modification, file missing)"
            continue
        fi
        actual=$(sha256_of "$local_root/$mpath")
        if [ "$actual" != "$msha" ]; then
            dep_failed=1
            report "$local_path/$mpath (declared local modification changed: expected sha256 $msha, got $actual)"
            continue
        fi
        report "note: expected local modification $local_path/$mpath - $mreason"
        mkdir -p "$(dirname "$up/$mpath")"
        cp "$local_root/$mpath" "$up/$mpath"
    done < <(dep_lmods "$i")

    # Coverage: every vendored file must fall under a declared compare pair,
    # otherwise a file smuggled into an uncompared subdirectory stays invisible.
    compare_locals=()
    while IFS=$'\t' read -r u l; do
        [ -z "$u" ] && continue
        compare_locals+=("$l")
    done < <(dep_compare "$i")

    while IFS= read -r f; do
        rel="${f#"$local_root"/}"
        covered=0
        for cl in "${compare_locals[@]}"; do
            if [ "$cl" = "." ] || [ "$rel" = "$cl" ]; then
                covered=1
                break
            fi
            case "$rel" in
                "$cl"/*)
                    covered=1
                    break
                    ;;
            esac
        done
        if [ "$covered" -eq 0 ]; then
            dep_failed=1
            report "$local_path/$rel (undeclared: not covered by any manifest compare entry)"
        fi
    done < <(find "$local_root" -type f)

    # The tree diff itself.
    while IFS=$'\t' read -r u l; do
        [ -z "$u" ] && continue
        up_side="$up"
        [ "$u" != "." ] && up_side="$up/$u"
        local_side="$local_root"
        [ "$l" != "." ] && local_side="$local_root/$l"

        if [ ! -e "$up_side" ]; then
            dep_failed=1
            report "$local_path/$l (upstream has no such path at the pinned ref)"
            continue
        fi

        brief=$(diff -qr "$up_side" "$local_side" 2>&1)
        if [ -n "$brief" ]; then
            dep_failed=1
            echo "$brief" | normalize "$up" | sed 's/^/       /'
            diff -r "$up_side" "$local_side" 2>&1 | normalize "$up" >>"$WORK/$name.diff"
        fi
    done < <(dep_compare "$i")

    if [ "$dep_failed" -eq 0 ]; then
        n_files=$(find "$local_root" -type f | wc -l | tr -d ' ')
        echo "OK     $name  <-  $pin_desc  ($n_files files verified)"
    else
        echo "FAIL   $name  <-  $pin_desc  (divergent paths listed above)"
        if [ -s "$WORK/$name.diff" ]; then
            echo "       ---- full diff (first $MAX_DIFF_LINES lines) ----"
            head -n "$MAX_DIFF_LINES" "$WORK/$name.diff" | sed 's/^/       /'
            total=$(wc -l <"$WORK/$name.diff" | tr -d ' ')
            if [ "$total" -gt "$MAX_DIFF_LINES" ]; then
                echo "       ---- truncated, $total lines total ----"
            fi
        fi
        FAILED_DEPS+=("$name")
    fi

    i=$((i + 1))
done

if [ "$checked" -eq 0 ]; then
    die "no dependency named '$ONLY_DEP' in the manifest"
fi

# Nothing may live under lib/ without being accounted for by the manifest.
if [ -z "$ONLY_DEP" ]; then
    declared=()
    while IFS= read -r line; do
        [ -n "$line" ] && declared+=("$line")
    done < <(all_local_paths)

    stray=0
    while IFS= read -r f; do
        rel="${f#"$REPO_ROOT"/}"
        [ "$rel" = "lib/VENDOR-MANIFEST.json" ] && continue
        covered=0
        for d in "${declared[@]}"; do
            case "$rel" in
                "$d"/*)
                    covered=1
                    break
                    ;;
            esac
        done
        if [ "$covered" -eq 0 ]; then
            if [ "$stray" -eq 0 ]; then
                echo
                echo "FAIL   lib/: files not covered by any manifest dependency"
                stray=1
            fi
            echo "       $rel"
        fi
    done < <(find "$REPO_ROOT/lib" -type f)
    if [ "$stray" -eq 1 ]; then
        FAILED_DEPS+=("lib-root")
    fi
fi

echo
if [ "${#FAILED_DEPS[@]}" -eq 0 ]; then
    echo "PASS: $checked/$dep_count vendored dependencies match their pins."
    exit 0
fi

echo "FAIL: ${#FAILED_DEPS[@]} divergent entry/entries: ${FAILED_DEPS[*]}"
echo "If a change under lib/ is intentional, update lib/VENDOR-MANIFEST.json in the same commit."
exit 1
