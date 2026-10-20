Bots made before SwarmHub (every command reads or writes files only; SwarmHub fills <names>, <name>, <backup>, and Konrad's press there is his yes). List every bot:
```
( cd ~/.hermes || exit 1; L=; for N in default $(ls profiles | grep -E '^[a-z0-9][a-z0-9_-]*$'); do F=profiles/$N/.env; [ "$N" = default ] && F=.env; H=false; grep -q '^API_SERVER_KEY=.' "$F" 2>/dev/null && H=true; L="$L${L:+,}{\"name\":\"$N\",\"has_key\":$H}"; done
P=; for F in $(ls -t swarmhub/reports/*.json 2>/dev/null | head -5); do case $(head -c 8 "$F") in '{"id":"r') [ "$(wc -l < "$F")" -le 1 ] && P="$P${P:+,}$(cat "$F")" ;; esac; done
printf '{"op":"bots","list":[%s],"reports":[%s]}\n' "$L" "$P" )
```
Connect bots (backs up each .env 0600, then sets its own derived key; never `default` or `coder_2`):
```
( MK=$(grep '^API_SERVER_KEY=' ~/.hermes/profiles/coder_2/.env | cut -d= -f2-); S=$(date -u +%Y%m%dT%H%M%SZ); R=; umask 077; cd ~/.hermes/profiles || exit 1
for N in <names>; do B=; ok=false
  case $N in default|coder_2|*[!a-z0-9_-]*|[!a-z0-9]*) ;; *) if [ -d "$N" ] && [ -n "$MK" ]; then E=$N/.env
    if [ -f "$E" ]; then B=.env.swarmhub-bak-$S; [ ! -e "$N/$B" ] && cp -p "$E" "$N/$B" && chmod 600 "$N/$B" || B=; fi
    if [ -n "$B" ] || [ ! -f "$E" ]; then K=$(printf '%s' "swarmhub-bot-key:v1:$N" | openssl dgst -sha256 -hmac "$MK" -r | cut -c1-64)
      { grep -v '^API_SERVER_KEY=' "$E" 2>/dev/null; printf 'API_SERVER_KEY=%s\n' "$K"; } > "$E.swarmhub-new" && mv "$E.swarmhub-new" "$E" && chmod 600 "$E" && ok=true; fi; fi ;; esac
  R="$R${R:+,}{\"name\":\"$N\",\"ok\":$ok,\"backup\":\"$B\"}"; done; unset MK K; printf '{"op":"bots_adopted","results":[%s]}\n' "$R" )
```
Restore a connected bot's old key:
```
( N=<name>; B=<backup>; ok=false; umask 077
  case $N in default|coder_2|*[!a-z0-9_-]*|[!a-z0-9]*) ;; *) cd ~/.hermes/profiles/"$N" 2>/dev/null && case $B in .env.swarmhub-bak-*[!0-9TZ]*) ;;
    .env.swarmhub-bak-*) [ -f "$B" ] && cp -p "$B" .env.swarmhub-new && mv .env.swarmhub-new .env && ok=true ;;
    "") grep -v '^API_SERVER_KEY=' .env > .env.swarmhub-new 2>/dev/null; if [ -s .env.swarmhub-new ]; then mv .env.swarmhub-new .env; else rm -f .env .env.swarmhub-new; fi; ok=true ;; esac ;; esac
  printf '{"op":"key_restored","name":"%s","ok":%s}\n' "$N" "$ok" )
```
Close reports (SwarmHub sent or dismissed them; Konrad pressed it):
```
( cd ~/.hermes/swarmhub/reports || exit 1; S=; D=
for I in <sent>; do case $I in *[!A-Za-z0-9_-]*) continue ;; esac; [ -f "$I.json" ] && mv "$I.json" "$I.sent"; [ -f "$I.sent" ] && S="$S${S:+,}\"$I\""; done
for I in <deleted>; do case $I in *[!A-Za-z0-9_-]*) continue ;; esac; rm -f "$I.json"; D="$D${D:+,}\"$I\""; done
printf '{"op":"reports_closed","sent":[%s],"deleted":[%s]}\n' "$S" "$D" )
```
Each prints one JSON line: put exactly that line in your swarmhub block.
