Coding tools and logins (SwarmHub's Accounts sheet runs these; it fills <tool> = claude, codex or chatgpt, and its press is Konrad's yes). Never print a token, an auth file, an email or a login code. Accounts status:
```
( export PATH="$HOME/.local/bin:$PATH"; node -e 'const{execSync:x}=require("child_process"),f=require("fs"),H=process.env.HOME,v=c=>{try{return(x(c+" --version 2>/dev/null",{timeout:20000,stdio:["ignore","pipe","pipe"]})+"").match(/\d+\.\d+[\w.-]*/)?.[0]||"?"}catch(e){return null}},s=p=>{try{return f.statSync(p).size>0}catch(e){return false}},t=a=>typeof a=="string"?Date.parse(a)/1e3:a;let P=[];try{P=JSON.parse(f.readFileSync(H+"/.hermes/auth.json")).credential_pool["openai-codex"]||[]}catch(e){}P.sort((a,b)=>(a.priority||0)-(b.priority||0));const n=Date.now()/1e3,b=P.map(e=>{const u=e.last_status=="exhausted"?(t(e.last_error_reset_at)||t(e.last_status_at)+3600):0;return u>n?new Date(u*1e3).toISOString().slice(0,19)+"Z":null}),c=v("claude"),d=v("codex");console.log(JSON.stringify({op:"accounts",claude:{installed:!!c,version:c,logged_in:!!c&&s(H+"/.hermes/swarmhub/claude.token")},codex:{installed:!!d,version:d,logged_in:!!d&&s((process.env.CODEX_HOME||H+"/.codex")+"/auth.json")},chatgpt:{count:P.length,labels:P.map((e,i)=>/@/.test(e.label||"@")?"account "+(i+1):String(e.label).slice(0,40)),benched_until:b}}))' )
```
Install claude and codex (no root; start it as a background process, wait for it, then run Accounts status):
```
mkdir -p ~/.hermes/swarmhub; PATH="$HOME/.local/bin:$PATH" npm install -g --prefix ~/.local @anthropic-ai/claude-code @openai/codex > ~/.hermes/swarmhub/install.log 2>&1; echo "EXIT $?" >> ~/.hermes/swarmhub/install.log
```
Log in, step 1 (start it as a background process; it waits for Konrad):
```
T=<tool>; D=~/.hermes/swarmhub; export PATH="$HOME/.local/bin:$PATH"; mkdir -p $D; chmod 700 $D; umask 077; case $T in claude) $D/bin/swarmhub-claude-login start ;; codex) F=$(codex login --help 2>&1 | grep -oE -- '--device[a-z-]*' | head -n 1); codex login "${F:---device-auth}" ;; chatgpt) HERMES_HOME=~/.hermes hermes auth add openai-codex ;; esac > $D/$T-login.out 2>&1; echo "EXIT $?" >> $D/$T-login.out
```
Log in, step 2 (prints the link and code):
```
( T=<tool>; D=~/.hermes/swarmhub; U=; C=; i=0; while [ $i -lt 40 ]; do sleep 1; i=$((i+1)); O=$(tr -d '\033\r' < $D/$T-login.out 2>/dev/null | sed 's/\[[0-9;?]*[A-Za-z]//g'); if [ $T = claude ]; then U=$(cat $D/claude-login.url 2>/dev/null); else U=$(echo "$O" | grep -oE 'https://[^] "<>)]+' | head -n 1); C=$(echo "$O" | grep -oE '[A-Z0-9]{4,}-[A-Z0-9]{4,}' | head -n 1); fi; [ -n "$U" ] && { [ $T = claude ] || [ -n "$C" ]; } && break; echo "$O" | grep -q '^EXIT' && break; done
  if [ -n "$U" ]; then printf '{"op":"login_link","tool":"%s","url":"%s","code":"%s"}\n' $T "$U" "$C"; else printf '{"op":"login_done","tool":"%s","ok":false}\n' $T; fi )
```
Check a login (waits up to 2 minutes):
```
( T=<tool>; F=~/.hermes/swarmhub/$T-login.out; i=0; while ! grep -q '^EXIT' $F 2>/dev/null && [ $i -lt 120 ]; do sleep 2; i=$((i+2)); done; case $(sed -n 's/^EXIT //p' $F 2>/dev/null) in 0) R=true ;; "") R='false,"pending":true' ;; *) R=false ;; esac; printf '{"op":"login_done","tool":"%s","ok":%s}\n' $T "$R" )
```
Claude's one-time code (SwarmHub fills <code>; never repeat it):
```
( R=$(~/.hermes/swarmhub/bin/swarmhub-claude-login code '<code>'); [ "$R" = ok ] && R=true || R=false; printf '{"op":"login_done","tool":"claude","ok":%s}\n' $R )
```
Log out (claude or codex), then run Accounts status:
```
case <tool> in claude) rm -f ~/.hermes/swarmhub/claude.token ;; codex) PATH="$HOME/.local/bin:$PATH" codex logout > /dev/null 2>&1 ;; esac
```
Each prints one JSON line (Install and Log out: the status line): put exactly that line in your swarmhub block.
