#!/bin/sh
set -eu

# txctl.sh — single-file Tiny Xboard controller + embedded local server manager.
# Does NOT install or modify mini-sb-agent. When installing an agent, it uses the
# original author's installer: https://raw.githubusercontent.com/ashvvvvv/mini-sb-agent/master/install.sh

TX_DIR="${TX_DIR:-/etc/tiny-xboard}"
TX_RUN="${TX_RUN:-/run/tiny-xboard}"
TX_SERVER="${TX_DIR}/tiny-xboard-server.py"
TX_PID="${TX_RUN}/server.pid"
TX_LOG="${TX_RUN}/server.log"
TX_PROFILE_DIR="${TX_PROFILE_DIR:-${HOME:-/tmp}/.txctl}"
TX_PROFILES="${TX_PROFILE_DIR}/profiles"
DEFAULT_LISTEN="127.0.0.1:8080"
ORIG_AGENT_INSTALL="https://raw.githubusercontent.com/ashvvvvv/mini-sb-agent/master/install.sh"

mkdir -p "$TX_PROFILE_DIR" 2>/dev/null || true
chmod 700 "$TX_PROFILE_DIR" 2>/dev/null || true

say(){ printf '%s\n' "$*"; }
err(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_root(){ [ "$(id -u)" = 0 ] || err "此操作需要 root"; }
have(){ command -v "$1" >/dev/null 2>&1; }
gen_token(){ if have openssl; then openssl rand -hex 24; else od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; fi; }

ensure_python(){
  have python3 && return 0
  err "需要 python3 才能运行嵌入式 Tiny Xboard Server。当前系统没有 python3；请先安装 python3。不会自动修改你的系统软件包。"
}

write_server(){
  ensure_python
  mkdir -p "$TX_DIR" "$TX_RUN"
  cat > "$TX_SERVER" <<'PY'
#!/usr/bin/env python3
import argparse, json, os, secrets, shutil, signal, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

ROOT=os.environ.get('TX_DIR','/etc/tiny-xboard')
MAX_USERS=1000
WRITE_LOCK=threading.Lock()
STATE_LOCK=threading.RLock()

DEFAULT_NODE={
  'id':1,'name':'default-vless','type':'vless','enabled':True,
  'token':'','server':{'listen':'0.0.0.0','port':443},
  'protocol':{'type':'vless','network':'tcp','flow':'xtls-rprx-vision','decryption':'none'},
  'tls':{'enabled':True,'server_name':'','server_port':443,'public_key':'','private_key':'','short_id':'','allow_insecure':False},
  'runtime':{'sync_interval':60,'traffic_flush_interval':300}
}

def paths():
  return {k:os.path.join(ROOT,k) for k in ['nodes.json','users.json','traffic.json','admin.json']}

def atomic_write(path,obj):
  os.makedirs(os.path.dirname(path),exist_ok=True)
  data=json.dumps(obj,separators=(',',':'),ensure_ascii=False).encode()
  fd,tmp=tempfile.mkstemp(prefix='.__tx.',dir=os.path.dirname(path))
  try:
    with os.fdopen(fd,'wb') as f:
      f.write(data); f.flush(); os.fsync(f.fileno())
    os.replace(tmp,path)
    try:
      d=os.open(os.path.dirname(path),os.O_RDONLY)
      os.fsync(d); os.close(d)
    except OSError: pass
  finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass

def load_or_default(path, default):
  if not os.path.exists(path): return default, False
  try:
    with open(path,'r',encoding='utf-8') as f: return json.load(f), True
  except Exception:
    bak=path+'.bak'
    try:
      with open(bak,'r',encoding='utf-8') as f: return json.load(f), True
    except Exception: return default, False

def save(name,obj):
  p=paths()[name]
  with WRITE_LOCK:
    if os.path.exists(p):
      try: shutil.copy2(p,p+'.bak')
      except OSError: pass
    atomic_write(p,obj)

def load_state():
  os.makedirs(ROOT,exist_ok=True)
  ps=paths()
  # nodes
  nd,_=load_or_default(ps['nodes.json'], {'version':1,'nodes':[dict(DEFAULT_NODE)]})
  if not nd.get('nodes'): nd={'version':1,'nodes':[dict(DEFAULT_NODE)]}
  if not nd['nodes'][0].get('token'):
    nd['nodes'][0]['token']=secrets.token_hex(24)
  # users
  us,_=load_or_default(ps['users.json'], {'version':1,'users':[]})
  # traffic
  tr,_=load_or_default(ps['traffic.json'], {'version':1,'updated_at':int(time.time()),'users':{}})
  # admin token
  ad,ok=load_or_default(ps['admin.json'], {'version':1,'token':secrets.token_hex(24)})
  if not ok or not ad.get('token'): ad={'version':1,'token':secrets.token_hex(24)}
  state={'nodes':nd,'users':us,'traffic':tr,'admin':ad,'dirty':False}
  save('nodes.json',nd); save('users.json',us); save('traffic.json',tr); save('admin.json',ad)
  return state

STATE=load_state()

def node_for(params):
  try: nid=int(params.get('node_id',['1'])[0])
  except Exception: return None
  typ=params.get('node_type',['vless'])[0].lower()
  tok=params.get('token',[''])[0]
  with STATE_LOCK:
    for n in STATE['nodes'].get('nodes',[]):
      if int(n.get('id',0))==nid and n.get('enabled',True):
        if n.get('token')==tok and (n.get('type','vless').lower() in (typ,'reality' if typ=='vless' else typ)):
          return n
  return None

def node_config(n):
  typ=n.get('type','vless').lower(); p=n.get('protocol',{}); s=n.get('server',{}); t=n.get('tls',{}); r=n.get('runtime',{})
  out={'protocol':'vless' if typ in ('vless','reality') else 'hysteria','listen_ip':s.get('listen','0.0.0.0'),'server_port':int(s.get('port') or 443)}
  if typ in ('vless','reality'):
    out['network']=p.get('network','tcp'); out['flow']=p.get('flow','xtls-rprx-vision'); out['decryption']=p.get('decryption','none'); out['tls']=2 if t.get('enabled',False) else 0
    ts={k:t[k] for k in ('server_name','server_port','public_key','private_key','short_id','allow_insecure') if k in t and t[k] not in ('',None,False)}
    out['tls_settings']=ts
  else:
    out['version']=2
    if t.get('server_name'): out['server_name']=t['server_name']
    if t.get('allow_insecure'): out['allow_insecure']=True
  interval=int(r.get('sync_interval') or 60); out['base_config']={'push_interval':interval,'pull_interval':interval}
  return out

def enabled_users():
  with STATE_LOCK: return [u for u in STATE['users'].get('users',[]) if u.get('enabled',True)]

def auth_admin(h):
  x=h.get('Authorization','')
  return x==('Bearer '+STATE['admin'].get('token',''))

def read_json(handler, limit=262144):
  n=int(handler.headers.get('Content-Length','0') or 0)
  if n<0 or n>limit: raise ValueError('payload too large')
  raw=handler.rfile.read(n)
  return json.loads(raw.decode('utf-8'))

def write(handler, code, obj):
  b=json.dumps(obj,separators=(',',':'),ensure_ascii=False).encode(); handler.send_response(code); handler.send_header('Content-Type','application/json'); handler.send_header('Content-Length',str(len(b))); handler.end_headers(); handler.wfile.write(b)

class H(BaseHTTPRequestHandler):
  server_version='TinyXboard/1.0'
  def log_message(self,fmt,*args): return
  def route(self):
    return urlparse(self.path), parse_qs(urlparse(self.path).query)
  def uni_auth(self,q): return node_for(q)
  def do_GET(self):
    u,q=self.route(); p=u.path
    if p=='/api/v1/server/UniProxy/user':
      if self.uni_auth(q) is None: return write(self,401,{'error':'invalid_token','message':'invalid token/node'})
      return write(self,200,{'users':enabled_users()})
    if p=='/api/v1/server/UniProxy/config':
      n=self.uni_auth(q)
      if n is None: return write(self,401,{'error':'invalid_token','message':'invalid token/node'})
      return write(self,200,node_config(n))
    if p=='/api/v1/admin/node':
      if not auth_admin(self.headers): return write(self,401,{'error':'unauthorized'})
      with STATE_LOCK: return write(self,200,STATE['nodes'])
    if p=='/api/v1/admin/user':
      if not auth_admin(self.headers): return write(self,401,{'error':'unauthorized'})
      return write(self,200,STATE['users'])
    if p=='/api/v1/admin/traffic':
      if not auth_admin(self.headers): return write(self,401,{'error':'unauthorized'})
      return write(self,200,STATE['traffic'])
    if p=='/healthz': return write(self,200,{'ok':True})
    return write(self,404,{'error':'not_found'})
  def do_POST(self):
    u,q=self.route(); p=u.path
    if p=='/api/v1/server/UniProxy/push':
      if self.uni_auth(q) is None: return write(self,401,{'error':'invalid_token','message':'invalid token/node'})
      try: raw=read_json(self)
      except Exception: return write(self,400,{'message':'invalid payload'})
      accepted=0
      with STATE_LOCK:
        known={int(x['id']) for x in STATE['users'].get('users',[]) if 'id' in x}
        entries=raw.get('traffic') if isinstance(raw,dict) else None
        if isinstance(entries,list):
          for e in entries:
            try: uid=int(e['uid']); up=int(e.get('up',0)); down=int(e.get('down',0))
            except Exception: continue
            if uid not in known or up<0 or down<0: continue
            v=STATE['traffic'].setdefault('users',{}).setdefault(str(uid),{'upload':0,'download':0}); v['upload']+=up; v['download']+=down; accepted+=1
        elif isinstance(raw,dict):
          for k,vv in raw.items():
            try: uid=int(k); pair=list(vv); up=int(pair[0]); down=int(pair[1])
            except Exception: continue
            if uid not in known or up<0 or down<0: continue
            v=STATE['traffic'].setdefault('users',{}).setdefault(str(uid),{'upload':0,'download':0}); v['upload']+=up; v['download']+=down; accepted+=1
        STATE['traffic']['updated_at']=int(time.time()); STATE['dirty']=True
      if STATE.get('dirty'): save('traffic.json',STATE['traffic']); STATE['dirty']=False
      return write(self,200,{'success':True,'accepted':accepted})
    if p=='/api/v1/admin/node':
      if not auth_admin(self.headers): return write(self,401,{'error':'unauthorized'})
      try: n=read_json(self,131072)
      except Exception: return write(self,400,{'error':'invalid_json'})
      with STATE_LOCK:
        ids={int(x.get('id',0)) for x in STATE['nodes'].get('nodes',[])}
        nid=int(n.get('id',0) or 0)
        if nid<=0 or nid in ids: return write(self,409,{'error':'node_exists'})
        n.setdefault('enabled',True); n.setdefault('type','vless'); n.setdefault('token',secrets.token_hex(24)); n.setdefault('name',f'node-{nid}'); n.setdefault('server',{'listen':'0.0.0.0','port':443}); n.setdefault('protocol',{'type':n['type'],'network':'tcp','flow':'xtls-rprx-vision','decryption':'none'}); n.setdefault('tls',{'enabled':True,'server_name':'','server_port':443,'public_key':'','private_key':'','short_id':'','allow_insecure':False}); n.setdefault('runtime',{'sync_interval':60,'traffic_flush_interval':300})
        STATE['nodes'].setdefault('nodes',[]).append(n); save('nodes.json',STATE['nodes'])
      return write(self,201,n)
    if p=='/api/v1/admin/user':
      if not auth_admin(self.headers): return write(self,401,{'error':'unauthorized'})
      try: x=read_json(self,65536)
      except Exception: return write(self,400,{'error':'invalid_json'})
      with STATE_LOCK:
        users=STATE['users'].setdefault('users',[]); ids={int(u.get('id',0)) for u in users}; uid=int(x.get('id',0) or 0)
        if uid<=0 or uid in ids: return write(self,409,{'error':'user_exists'})
        if len(users)>=MAX_USERS: return write(self,409,{'error':'max_users'})
        if not x.get('uuid'): x['uuid']=x.get('password') or str(__import__('uuid').uuid4())
        x.setdefault('name',str(uid)); x.setdefault('password',x['uuid']); x.setdefault('speed_limit',0); x.setdefault('enabled',True); users.append(x); save('users.json',STATE['users'])
      return write(self,201,x)
    return write(self,404,{'error':'not_found'})
  def do_PUT(self):
    u,_=self.route(); p=u.path
    if not auth_admin(self.headers): return write(self,401,{'error':'unauthorized'})
    try: x=read_json(self,131072)
    except Exception: return write(self,400,{'error':'invalid_json'})
    try: ident=int(p.rstrip('/').split('/')[-1])
    except Exception: return write(self,400,{'error':'bad_id'})
    with STATE_LOCK:
      if p.startswith('/api/v1/admin/node/'):
        for i,n in enumerate(STATE['nodes'].get('nodes',[])):
          if int(n.get('id',0))==ident:
            x['id']=ident; x.setdefault('token',n.get('token') or secrets.token_hex(24)); STATE['nodes']['nodes'][i]=x; save('nodes.json',STATE['nodes']); return write(self,200,x)
        return write(self,404,{'error':'node_not_found'})
      if p.startswith('/api/v1/admin/user/'):
        for i,n in enumerate(STATE['users'].get('users',[])):
          if int(n.get('id',0))==ident:
            x['id']=ident; STATE['users']['users'][i]=x; save('users.json',STATE['users']); return write(self,200,x)
        return write(self,404,{'error':'user_not_found'})
    return write(self,404,{'error':'not_found'})
  def do_DELETE(self):
    u,_=self.route(); p=u.path
    if not auth_admin(self.headers): return write(self,401,{'error':'unauthorized'})
    try: ident=int(p.rstrip('/').split('/')[-1])
    except Exception: return write(self,400,{'error':'bad_id'})
    with STATE_LOCK:
      if p.startswith('/api/v1/admin/node/'):
        old=len(STATE['nodes'].get('nodes',[])); STATE['nodes']['nodes']=[n for n in STATE['nodes']['nodes'] if int(n.get('id',0))!=ident]
        if len(STATE['nodes']['nodes'])==old: return write(self,404,{'error':'node_not_found'})
        if not STATE['nodes']['nodes']: return write(self,409,{'error':'cannot_delete_last_node'})
        save('nodes.json',STATE['nodes']); return write(self,200,{'success':True})
      if p.startswith('/api/v1/admin/user/'):
        old=len(STATE['users'].get('users',[])); STATE['users']['users']=[n for n in STATE['users']['users'] if int(n.get('id',0))!=ident]
        if len(STATE['users']['users'])==old: return write(self,404,{'error':'user_not_found'})
        save('users.json',STATE['users']); STATE['traffic'].setdefault('users',{}).pop(str(ident),None); save('traffic.json',STATE['traffic']); return write(self,200,{'success':True})
    return write(self,404,{'error':'not_found'})


def main():
  global ROOT, STATE
  ap=argparse.ArgumentParser(); ap.add_argument('--dir',default=ROOT); ap.add_argument('--listen',default='127.0.0.1:8080'); args=ap.parse_args()
  ROOT=args.dir; STATE=load_state()
  host,port=args.listen.rsplit(':',1); httpd=HTTPServer((host,int(port)),H)
  def stop(*_):
    try: STATE['dirty']=False; save('traffic.json',STATE['traffic'])
    finally: httpd.shutdown()
  signal.signal(signal.SIGTERM,stop); signal.signal(signal.SIGINT,stop)
  print(f'Tiny Xboard listening on {args.listen}',flush=True); httpd.serve_forever()
if __name__=='__main__': main()
PY
chmod 700 "$TX_SERVER"
}

server_is_running(){ [ -f "$TX_PID" ] && kill -0 "$(cat "$TX_PID")" 2>/dev/null; }

start_server(){
  need_root; ensure_python; write_server
  mkdir -p "$TX_DIR" "$TX_RUN"; chmod 700 "$TX_DIR" "$TX_RUN"
  if server_is_running; then say "Tiny Xboard 已运行，PID=$(cat "$TX_PID")"; return 0; fi
  nohup env TX_DIR="$TX_DIR" python3 "$TX_SERVER" --dir "$TX_DIR" --listen "${TX_LISTEN:-$DEFAULT_LISTEN}" >>"$TX_LOG" 2>&1 &
  echo $! > "$TX_PID"
  sleep 0.3
  server_is_running || { cat "$TX_LOG" >&2; rm -f "$TX_PID"; err "Tiny Xboard 启动失败"; }
  say "Tiny Xboard 已启动：${TX_LISTEN:-$DEFAULT_LISTEN}"
}
stop_server(){ need_root; if server_is_running; then kill "$(cat "$TX_PID")"; i=0; while server_is_running && [ $i -lt 20 ]; do sleep .1; i=$((i+1)); done; fi; rm -f "$TX_PID"; say "Tiny Xboard 已停止"; }
status_server(){ if server_is_running; then say "RUNNING PID=$(cat "$TX_PID")"; else say "STOPPED"; fi; }

load_admin(){
  [ -r "$TX_DIR/admin.json" ] || return 1
  if have python3; then ADMIN_TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$TX_DIR/admin.json") || return 1; else return 1; fi
}
admin_base(){ printf "http://%s" "${TX_LISTEN:-127.0.0.1:8080}"; }
admin_get(){ load_admin || err "本机 admin.json 不存在，请先 start-server"; curl -fsS --connect-timeout 5 --max-time 15 -H "Authorization: Bearer $ADMIN_TOKEN" "$1"; }
admin_json(){ load_admin || err "本机 admin.json 不存在，请先 start-server"; curl -fsS --connect-timeout 5 --max-time 15 -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' "$@"; }

api_query(){
  path=$1; url=${TX_URL:-http://127.0.0.1:8080}; tok=${TX_TOKEN:-}; nid=${TX_NODE_ID:-1}; typ=${TX_NODE_TYPE:-vless}
  [ -n "$tok" ] || { [ -r "$TX_DIR/nodes.json" ] && tok=$(python3 -c 'import json,sys; n=json.load(open(sys.argv[1]))["nodes"][0]; print(n.get("token", ""))' "$TX_DIR/nodes.json"); }
  curl -fsS --connect-timeout 5 --max-time 15 --get --data-urlencode "token=$tok" --data-urlencode "node_id=$nid" --data-urlencode "node_type=$typ" "$url/api/v1/server/UniProxy/$path"
}
pretty(){ if have python3; then python3 -m json.tool 2>/dev/null || cat; elif have jq; then jq .; else cat; fi; }

install_service(){
  need_root; ensure_python; write_server; mkdir -p "$TX_RUN"; listen="${TX_LISTEN:-$DEFAULT_LISTEN}"
  if have systemctl && [ -d /run/systemd/system ]; then
    cat > /etc/systemd/system/tiny-xboard.service <<EOF
[Unit]
Description=Tiny Xboard API
After=network.target

[Service]
Type=simple
Environment=TX_DIR=$TX_DIR
ExecStart=/usr/bin/python3 $TX_SERVER --dir $TX_DIR --listen $listen
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable --now tiny-xboard.service
    say "已安装并启动 systemd 服务 tiny-xboard"
  elif have rc-service && [ -d /etc/init.d ]; then
    cat > /etc/init.d/tiny-xboard <<EOF
#!/sbin/openrc-run
name="tiny-xboard"
command="/usr/bin/python3"
command_args="$TX_SERVER --dir $TX_DIR --listen $listen"
command_background=true
pidfile="$TX_RUN/tiny-xboard.pid"
directory="$TX_DIR"
output_log="$TX_RUN/server.log"
error_log="$TX_RUN/server.log"
command_user=root
EOF
    chmod +x /etc/init.d/tiny-xboard; rc-update add tiny-xboard default; rc-service tiny-xboard restart
    say "已安装并启动 OpenRC 服务 tiny-xboard"
  else
    say "未检测到 systemd/OpenRC；将使用 nohup 后台运行，但不会随系统重启自动启动。"
    start_server
  fi
}
uninstall_service(){
  need_root
  if have systemctl && [ -f /etc/systemd/system/tiny-xboard.service ]; then systemctl disable --now tiny-xboard.service 2>/dev/null || true; rm -f /etc/systemd/system/tiny-xboard.service; systemctl daemon-reload 2>/dev/null || true; fi
  if [ -f /etc/init.d/tiny-xboard ]; then rc-service tiny-xboard stop 2>/dev/null || true; rc-update del tiny-xboard default 2>/dev/null || true; rm -f /etc/init.d/tiny-xboard; fi
  say "Tiny Xboard 自启动服务已移除"
}

profile_list(){
  [ -r "$TX_PROFILES" ] || { say "暂无 profile"; return; }
  printf '%-16s %-32s %-8s %-8s\n' NAME URL ID TYPE
  while IFS='|' read -r n u t i y; do [ -n "$n" ] || continue; printf '%-16s %-32s %-8s %-8s\n' "$n" "$u" "$i" "$y"; done < "$TX_PROFILES"
}
profile_add(){
  name=$1; url=$2; token=$3; id=$4; typ=$5; grep -Fq "^$name|" "$TX_PROFILES" 2>/dev/null && err "profile 已存在"; mkdir -p "$TX_PROFILE_DIR"; printf '%s|%s|%s|%s|%s\n' "$name" "$url" "$token" "$id" "$typ" >> "$TX_PROFILES"; chmod 600 "$TX_PROFILES"; say "已保存 profile=$name";
}

install_original_agent(){
  need_root; have curl || err "需要 curl"; url=${TX_AGENT_URL:-http://127.0.0.1:8080}; token=${TX_AGENT_TOKEN:-}; id=${TX_AGENT_NODE_ID:-1}; typ=${TX_AGENT_NODE_TYPE:-vless};
  [ -n "$token" ] || { [ -r "$TX_DIR/nodes.json" ] && token=$(python3 -c 'import json,sys; n=json.load(open(sys.argv[1]))["nodes"][0]; print(n.get("token", ""))' "$TX_DIR/nodes.json"); }
  tmp=/tmp/mini-sb-install.sh.$$; curl -fsSL "$ORIG_AGENT_INSTALL" -o "$tmp" || err "下载原版 mini-sb-agent 安装器失败"; chmod 700 "$tmp";
  say "执行原作者 ashvvvvv/mini-sb-agent 官方安装器。不会使用本项目私改版。";
  exec sh "$tmp" --panel-url "$url" --panel-token "$token" --vless-node-id "$id" --node-mode "$typ" --yes 2>/dev/null || exec sh "$tmp"
}

show_local(){
  say "Tiny Xboard: $(server_is_running && echo RUNNING || echo STOPPED)"; say "data=$TX_DIR"; [ -r "$TX_DIR/admin.json" ] && say "admin token: 已生成（不会在菜单中主动明文显示）"; [ -r "$TX_DIR/nodes.json" ] && { python3 - <<'PY' "$TX_DIR/nodes.json"
import json,sys
x=json.load(open(sys.argv[1])); print('nodes:')
for n in x.get('nodes',[]): print('  id=%s name=%s type=%s token=%s' % (n.get('id'),n.get('name'),n.get('type'),'set' if n.get('token') else 'missing'))
PY
}; }

menu(){
 while :; do
  echo; echo '========== txctl / Tiny Xboard =========='; status_server; echo "数据目录: $TX_DIR"; echo; echo '1) 启动 Tiny Xboard'; echo '2) 停止 Tiny Xboard'; echo '3) 重启 Tiny Xboard'; echo '4) 安装/启用后台服务'; echo '5) 节点列表'; echo '6) 添加节点'; echo '7) 删除节点'; echo '8) 修改节点'; echo '9) 用户列表'; echo '10) 添加用户'; echo '11) 删除用户'; echo '12) 修改用户'; echo '13) 流量统计'; echo '14) 测试 UniProxy API'; echo '15) 添加远程机器 Profile'; echo '16) 原版 mini-sb-agent 安装辅助'; echo '17) 当前信息'; echo 'q) 退出'; printf '选择: '; read -r a || exit 0
  case $a in
   1) start_server;; 2) stop_server;; 3) stop_server || true; start_server;; 4) install_service;;
   5) start_server >/dev/null 2>&1 || true; admin_get "http://${TX_ADMIN_HOST:-127.0.0.1}:${TX_ADMIN_PORT:-8080}/api/v1/admin/node" | pretty;;
   6) start_server >/dev/null 2>&1 || true; echo '请输入节点 JSON（最小：id/name/type/token/server/protocol/tls/runtime）'; read -r j; admin_json -X POST --data "$j" "$(admin_base)/api/v1/admin/node" | pretty;;
   7) printf "Node ID: "; read -r id; admin_json -X DELETE "http://127.0.0.1:8080/api/v1/admin/node/$id" | pretty;;
   8) printf "Node ID: "; read -r id; echo '输入完整的新节点 JSON:'; read -r j; admin_json -X PUT --data "$j" "http://127.0.0.1:8080/api/v1/admin/node/$id" | pretty;;
   9) start_server >/dev/null 2>&1 || true; admin_get "$(admin_base)/api/v1/admin/user" | pretty;;
   10) echo '输入用户 JSON，例如 {"id":1,"uuid":"...","name":"alice","speed_limit":0,"enabled":true}'; read -r j; admin_json -X POST --data "$j" "$(admin_base)/api/v1/admin/user" | pretty;;
   11) printf "User ID: "; read -r id; admin_json -X DELETE "http://127.0.0.1:8080/api/v1/admin/user/$id" | pretty;;
   12) printf "User ID: "; read -r id; echo '输入完整的新用户 JSON:'; read -r j; admin_json -X PUT --data "$j" "http://127.0.0.1:8080/api/v1/admin/user/$id" | pretty;;
   13) admin_get "$(admin_base)/api/v1/admin/traffic" | pretty;;
   14) TX_URL="$(admin_base)" TX_TOKEN=$(python3 -c 'import json;print(json.load(open("/etc/tiny-xboard/nodes.json"))["nodes"][0]["token"])') TX_NODE_ID=1 TX_NODE_TYPE=vless; api_query user | pretty; echo; api_query config | pretty;;
   15) printf 'name: '; read -r n; printf 'url: '; read -r u; printf 'token: '; read -r t; printf 'node id: '; read -r i; printf 'type(vless/hy2): '; read -r y; profile_add "$n" "$u" "$t" "$i" "$y";;
   16) install_original_agent;;
   17) show_local;;
   q|Q) exit 0;; *) say '无效选择';;
  esac
 done
}

case ${1:-menu} in
  start|server-start) start_server;;
  stop|server-stop) stop_server;;
  restart|server-restart) stop_server || true; start_server;;
  service-install) install_service;;
  service-uninstall) uninstall_service;;
  status|server-status) status_server;;
  node-list) start_server >/dev/null 2>&1 || true; admin_get "$(admin_base)/api/v1/admin/node" | pretty;;
  user-list) start_server >/dev/null 2>&1 || true; admin_get "$(admin_base)/api/v1/admin/user" | pretty;;
  traffic) start_server >/dev/null 2>&1 || true; admin_get "$(admin_base)/api/v1/admin/traffic" | pretty;;
  install-agent) install_original_agent;;
  profile-list) profile_list;;
  *) menu;;
esac
