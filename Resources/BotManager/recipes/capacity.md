Box capacity (reads only; the coding-job log loses bot and agent):
```
( D=~/.hermes/swarmhub; S=$(sed -n 's/^SLOTS=\([0-9][0-9]*\)[[:space:]]*$/\1/p' $D/coding.conf 2>/dev/null | tail -n 1)
J=$(tail -n 200 $D/coding-jobs.log 2>/dev/null | awk -F '\t' '$1 ~ /^[0-9][0-9T:Z-]*$/ && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+$/ && $7 ~ /^-?[0-9]+$/ { printf "%s[\"%s\",%s,%s,%s,%s]", (n++ ? "," : ""), $1, $4, $5, $6, $7 }')
M=$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { printf "%d,\"mem_avail_mb\":%d", t / 1024, a / 1024 }' /proc/meminfo)
printf '{"op":"box_capacity","cpus":%s,"mem_total_mb":%s,"disk_free_mb":%s,"load1":"%s","slots":%s,"jobs":[%s]}\n' "$(nproc)" "$M" "$(df -Pm ~ | awk 'NR == 2 { print $4 }')" "$(cut -d ' ' -f 1 /proc/loadavg)" "${S:-null}" "$J" )
```
Set the coding job limit (SwarmHub fills <slots>; running jobs keep going, the next job uses it), then run Box capacity:
```
( N=<slots>; D=~/.hermes/swarmhub; F=$D/coding.conf; case $N in ''|0*|*[!0-9]*) exit 1 ;; esac; umask 077; mkdir -p $D
{ grep -v '^SLOTS=' $F 2>/dev/null; echo "SLOTS=$N"; } > $F.swarmhub-new && mv $F.swarmhub-new $F && chmod 600 $F )
```
Box capacity prints one JSON line (also after Set): put exactly that line in your swarmhub block.
