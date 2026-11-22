#!/usr/bin/env bash
# Uptime + broken-asset check for jaipandhoh.com. Prints problems; exits 1 if any.
set -uo pipefail
SITE="${SITE:-https://jaipandhoh.com}"
CURL=(curl -sS --max-time 30 --retry 3 --retry-delay 5 --retry-all-errors -A "site-uptime-check")
TMP="$(mktemp -d)"; FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
ok()   { echo "ok:   $*"; }

# 1. Homepage
code=$("${CURL[@]}" -o "$TMP/index.html" -w '%{http_code}' "$SITE/") || code=000
if [ "$code" != 200 ]; then fail "homepage returned HTTP $code"; echo; exit 1; fi
grep -q "<title>Jai Pandhoh" "$TMP/index.html" && ok "homepage 200 with expected title" || fail "homepage title missing (wrong content served?)"

# 2. JS/CSS bundles referenced by index.html
bundles=$(grep -oE '(src|href)="/assets/[^"]+\.(js|css)"' "$TMP/index.html" | sed -E 's/^[a-z]+="//; s/"$//')
[ -n "$bundles" ] || fail "no JS/CSS bundles found in index.html"
for b in $bundles; do
  code=$("${CURL[@]}" -o "$TMP/$(basename "$b")" -w '%{http_code}' "$SITE$b") || code=000
  [ "$code" = 200 ] && ok "bundle $b" || fail "bundle $b returned HTTP $code"
done

# 3. Every image/video/PDF the app references
cat "$TMP"/*.js 2>/dev/null \
  | grep -oE '[`"'"'"'](\./)?/?(assets|about|intro|press|reels|resume|weekly-vlog)/[^`"'"'"']+\.(jpg|jpeg|png|webp|gif|svg|pdf|mp4|mov|webm|avif)[`"'"'"']' \
  | sed -E 's/^.//; s/.$//; s#^\./##; s#^/##' | sort -u > "$TMP/assets.txt"
total=$(wc -l < "$TMP/assets.txt" | tr -d ' ')
sed 's/ /%20/g' "$TMP/assets.txt" \
  | SITE="$SITE" xargs -P 8 -n 1 sh -c 'c=$(curl -sS -o /dev/null -I --max-time 30 --retry 2 --retry-all-errors -w "%{http_code}" "$SITE/$1" || echo 000); [ "$c" = 200 ] || echo "$c /$1"' _ \
  > "$TMP/broken.txt" 2>&1 || fail "asset check could not run"
[ "$total" -gt 0 ] || fail "no media assets found in JS bundle (checker or build changed?)"
broken=$(cat "$TMP/broken.txt")
if [ -n "$broken" ]; then fail "$(echo "$broken" | wc -l | tr -d ' ') of $total assets broken:"; echo "$broken" | sed 's/^/      /'; else ok "all $total referenced assets load"; fi

# 4. www and http redirects
code=$("${CURL[@]}" -L -o /dev/null -w '%{http_code} %{url_effective}' "https://www.jaipandhoh.com/") || code=000
[[ "$code" == 200* ]] && ok "www.jaipandhoh.com -> $code" || fail "www.jaipandhoh.com: $code"
code=$("${CURL[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "http://jaipandhoh.com/") || code=000
[[ "$code" == 30*" https://"* ]] && ok "http redirects to https" || fail "http not redirecting to https: $code"

# 5. TLS certificate expiry
end=$(echo | openssl s_client -servername jaipandhoh.com -connect jaipandhoh.com:443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -z "$end" ]; then fail "could not read TLS certificate"; else
  days=$(( ( $(date -d "$end" +%s 2>/dev/null || date -j -f "%b %e %T %Y %Z" "$end" +%s) - $(date +%s) ) / 86400 ))
  [ "$days" -ge 14 ] && ok "TLS cert valid for $days more days" || fail "TLS cert expires in $days days ($end)"
fi

rm -rf "$TMP"; exit $FAIL
