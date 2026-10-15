Bot models (each bot's model and sub-agent model, read from its config.yaml only: no Hermes start, no Python; '', "" and a missing key are empty):
```
( cd ~/.hermes || exit 1; v() { sed -n "/^$1:/,/^[^ ]/s/^  *$2: *\([^#]*\).*/\1/p" "$F" | head -n 1 | tr -cd 'A-Za-z0-9._:/-' | cut -c1-100; }; L=
for N in default $(ls profiles | grep -E '^[a-z0-9][a-z0-9_-]*$'); do F=profiles/$N/config.yaml; [ "$N" = default ] && F=config.yaml; [ -f "$F" ] || continue
  L="$L${L:+,}{\"name\":\"$N\",\"model\":\"$(v model default)\",\"provider\":\"$(v model provider)\",\"sub_model\":\"$(v delegation model)\",\"sub_provider\":\"$(v delegation provider)\"}"; done
printf '{"op":"models","list":[%s]}\n' "$L" )
```
It prints one JSON line: put exactly that line in your swarmhub block.
