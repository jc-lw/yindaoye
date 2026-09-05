
# mo.sh 14.0.0 — 基于用户提供的 mo_v12.sh 优化；打印结果，不上传或回传网站。
# 默认把完整 SOCKS5 流水线放到后台，与项目准备及 Vertex Key 提取并发运行。
# 保留：旧 AQ 优先、无组织项目补建、VM-first、VPC/防火墙兜底、有界重试。
# bash mo.sh | bash mo.sh --background | --status | --logs | --results | --json | --stop
# Linux + Bash >=4.3，gcloud 已登录；首次运行需要能下载原 test.sh。
# test.sh 的 API/IAM/SA/AQ 操作保持原函数接口，不声称突破权限、账单或配额限制。
set -uo pipefail
umask 077
(( BASH_VERSINFO[0]>4 || (BASH_VERSINFO[0]==4 && BASH_VERSINFO[1]>=3) )) || { printf '需要 Bash >=4.3\n' >&2; exit 1; }
VERSION=14.0.0
TESTSH_URL="${TESTSH_URL:-https://raw.githubusercontent.com/jc-lw/yindaoye/refs/heads/main/test.sh}"
NEED_PROJECTS="${NEED_PROJECTS:-2}"
REUSE_PROXY="${REUSE_PROXY:-1}"
REUSE_KEYS="${REUSE_KEYS:-1}"
PARALLEL_PROXY="${PARALLEL_PROXY:-1}"
BILLING_SCAN_JOBS="${BILLING_SCAN_JOBS:-4}"
KEY_SCAN_JOBS="${KEY_SCAN_JOBS:-2}"
KEY_JOBS="${KEY_JOBS:-2}"
PROXY_SCAN_JOBS="${PROXY_SCAN_JOBS:-3}"
PROXY_SCAN_LIMIT="${PROXY_SCAN_LIMIT:-0}" # 0=全部可访问的 ACTIVE 项目
PROXY_PORT="${PROXY_PORT:-1080}"
PROXY_ZONE_TRIES="${PROXY_ZONE_TRIES:-8}"
PROXY_PROJECT_TRIES="${PROXY_PROJECT_TRIES:-2}"
PROXY_WAIT_SECONDS="${PROXY_WAIT_SECONDS:-180}"
PROXY_REUSE_GRACE_SECONDS="${PROXY_REUSE_GRACE_SECONDS:-20}"
PROXY_REPAIR_WAIT_SECONDS="${PROXY_REPAIR_WAIT_SECONDS:-60}"
PROXY_ZONES_PER_PROJECT="${PROXY_ZONES_PER_PROJECT:-3}"
PROXY_SHUFFLE_ZONES="${PROXY_SHUFFLE_ZONES:-1}"
PROXY_CHECK_TIMEOUT="${PROXY_CHECK_TIMEOUT:-8}"
PROXY_POLL_SECONDS="${PROXY_POLL_SECONDS:-3}"
PROXY_RESET_ON_FAILURE="${PROXY_RESET_ON_FAILURE:-1}"
DELETE_FAILED_VM="${DELETE_FAILED_VM:-1}" # 仅限本次明确创建、ID 与 mo-run 标签匹配的 VM
PROXY_TEST_URL="${PROXY_TEST_URL:-https://www.google.com/generate_204}"
PROXY_TEST_URL_FALLBACK="${PROXY_TEST_URL_FALLBACK:-https://api.ipify.org}"
PROXY_SOURCE_RANGES="${PROXY_SOURCE_RANGES:-0.0.0.0/0}"
GCLOUD_TIMEOUT="${GCLOUD_TIMEOUT:-90}"
BILLING_TIMEOUT="${BILLING_TIMEOUT:-30}"
KEY_SCAN_TIMEOUT="${KEY_SCAN_TIMEOUT:-90}"
KEY_TIMEOUT="${KEY_TIMEOUT:-900}"
CREATE_TIMEOUT="${CREATE_TIMEOUT:-600}"
VM_CREATE_TIMEOUT="${VM_CREATE_TIMEOUT:-240}"
PROXY_CANDIDATE_WAIT_SECONDS="${PROXY_CANDIDATE_WAIT_SECONDS:-720}"
TESTSH_CACHE_TTL="${TESTSH_CACHE_TTL:-3600}"
export PROJECT_SUBMIT_GAP="${PROJECT_SUBMIT_GAP:-1}"
export PROJECT_CREATE_GAP="${PROJECT_CREATE_GAP:-1}"
# 让 API 修复有充分时间；提速来自并发/复用，不削减 SA/IAM 传播等待。
export API_BATCH_GAP="${API_BATCH_GAP:-1}"
export API_REPAIR_ROUNDS="${API_REPAIR_ROUNDS:-4}"
export API_REPAIR_SLEEP="${API_REPAIR_SLEEP:-5}"
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

mo_data() {
  python3 - "$@" <<'MO_DATA'
import sys, os, json, re, time, pathlib, hashlib, secrets, urllib.parse, signal, ipaddress
a=sys.argv[1:]; op=a.pop(0)
def read(p):
    return json.loads(pathlib.Path(p).read_text())
def atomic(p, value, raw=False):
    p=pathlib.Path(p); t=p.with_name(p.name+'.tmp.'+str(os.getpid()))
    t.write_text(value if raw else json.dumps(value, ensure_ascii=False, indent=2)+'\n')
    os.chmod(t, 0o600); os.replace(t,p)
def obj(v):
    return v[0] if isinstance(v,list) and v else v
_pid_index=None
def pid_index():
    # 某些容器挂载的是外层 /proc；把宿主 PID 映射回本进程所在的 PID namespace。
    global _pid_index
    if _pid_index is not None: return _pid_index
    proc_pid=int(pathlib.Path('/proc/self/stat').read_text().split(' ',1)[0])
    if proc_pid==os.getpid(): _pid_index={}; return _pid_index
    own_ns=os.readlink('/proc/self/ns/pid'); found={}
    for f in pathlib.Path('/proc').iterdir():
        if not f.name.isdigit(): continue
        try:
            if os.readlink(f/'ns/pid')!=own_ns: continue
            line=next(x for x in (f/'status').read_text().splitlines() if x.startswith('NSpid:'))
            found[int(line.split()[-1])]=int(f.name)
        except (OSError,StopIteration,ValueError): continue
    _pid_index=found
    return _pid_index
def pinfo(pid):
    try:
        idx=pid_index(); actual=idx.get(int(pid),int(pid)) if not idx else idx[int(pid)]
        t=pathlib.Path('/proc/'+str(actual)+'/stat').read_text().rsplit(')',1)[1].split()
        reverse={v:k for k,v in idx.items()}
        parent=reverse.get(int(t[1]),0) if idx else int(t[1])
        return {'pid':int(pid),'ppid':parent,'start':t[19],'state':t[0],
                'boot':pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()}
    except (OSError,ValueError,IndexError,KeyError): return None
def same(p):
    q=pinfo(p['pid'])
    return bool(q and q['start']==p['start'] and q['boot']==p['boot'] and q['state']!='Z')
def proxy(d):
    port=int(d.get('port',1080)); host=str(d.get('host',''))
    if not host or not 1<=port<=65535 or not d.get('user') or not d.get('password'):
        raise ValueError('代理地址或认证信息不完整')
    h='['+host+']' if ':' in host else host
    q=lambda x:urllib.parse.quote(str(x),safe='')
    d['port']=port; d['url']=f"socks5://{q(d['user'])}:{q(d['password'])}@{h}:{port}"
    d['adspower']=f"{host}:{port}:{d['user']}:{d['password']}"
    return d
def cquote(v): return '"'+str(v).replace('\\','\\\\').replace('"','\\"').replace('\n','\\n').replace('\r','\\r')+'"'
if op=='pid':
    p=pinfo(a[1])
    if not p: raise RuntimeError('无法读取任务进程信息，需要可读的 Linux /proc')
    atomic(a[0],p)
elif op=='alive':
    sys.exit(0 if same(read(a[0])) else 1)
elif op=='stop':
    p=read(a[0])
    if same(p): os.kill(p['pid'],signal.SIGTERM)
    else: sys.exit(1)
elif op=='children-stop':
    root=int(a[0]); records={}
    idx=pid_index()
    candidates=list(idx) if idx else [int(f.name) for f in pathlib.Path('/proc').iterdir() if f.name.isdigit()]
    for pid in candidates:
        p=pinfo(pid)
        if p: records[p['pid']]=p
    selected={root}
    while True:
        more={pid for pid,p in records.items() if p['ppid'] in selected}
        if more<=selected: break
        selected|=more
    selected.discard(root); selected.discard(os.getpid())
    for sig in (signal.SIGTERM,signal.SIGKILL):
        for pid in selected:
            try:
                if same(records[pid]): os.kill(pid,sig)
            except ProcessLookupError: pass
        if sig==signal.SIGTERM: time.sleep(.25)
elif op=='validate':
    ranges={'NEED_PROJECTS':(1,50),'BILLING_SCAN_JOBS':(1,8),'KEY_SCAN_JOBS':(1,8),'KEY_JOBS':(1,8),
      'PROXY_SCAN_JOBS':(1,8),'PROXY_SCAN_LIMIT':(0,10000),'PROXY_PORT':(1,65535),
      'PROXY_ZONE_TRIES':(1,50),'PROXY_PROJECT_TRIES':(1,50),'PROXY_ZONES_PER_PROJECT':(1,20),'PROXY_WAIT_SECONDS':(1,1800),
      'PROXY_REUSE_GRACE_SECONDS':(0,300),'PROXY_REPAIR_WAIT_SECONDS':(1,600),
      'PROXY_CHECK_TIMEOUT':(1,60),'PROXY_POLL_SECONDS':(1,30),'GCLOUD_TIMEOUT':(5,600),
      'BILLING_TIMEOUT':(5,120),'KEY_SCAN_TIMEOUT':(1,600),'KEY_TIMEOUT':(1,7200),
      'CREATE_TIMEOUT':(5,7200),'VM_CREATE_TIMEOUT':(5,900),'PROXY_CANDIDATE_WAIT_SECONDS':(1,7200),
      'TESTSH_CACHE_TTL':(0,604800)}
    for name,(lo,hi) in ranges.items():
        v=os.environ[name]
        if not re.fullmatch(r'0|[1-9][0-9]*',v) or not lo<=int(v)<=hi: raise ValueError(name+' 数值无效')
    for name in ('REUSE_PROXY','REUSE_KEYS','PARALLEL_PROXY','PROXY_SHUFFLE_ZONES','PROXY_RESET_ON_FAILURE','DELETE_FAILED_VM'):
        if os.environ[name] not in ('0','1'): raise ValueError(name+' 只能为 0/1')
    for name in ('TESTSH_URL','PROXY_TEST_URL','PROXY_TEST_URL_FALLBACK'):
        u=urllib.parse.urlsplit(os.environ[name])
        if u.scheme!='https' or not u.hostname or u.username or u.password or '\n' in u.geturl(): raise ValueError(name+' 必须是 HTTPS 地址')
    for x in os.environ['PROXY_SOURCE_RANGES'].split(','): ipaddress.ip_network(x,strict=False)
    for name in ('PROJECT_IDS','PROXY_PROJECT'):
        for p in re.split(r'[\s,]+',os.environ.get(name,'').strip()):
            if p and not re.fullmatch(r'[a-z][a-z0-9-]{4,28}[a-z0-9]',p): raise ValueError(name+' 项目 ID 无效')
elif op=='hash': print(hashlib.sha256(a[0].encode()).hexdigest()[:20])
elif op=='fresh': sys.exit(0 if pathlib.Path(a[0]).is_file() and time.time()-os.stat(a[0]).st_mtime<int(a[1]) else 1)
elif op=='library':
    raw=pathlib.Path(a[0]).read_bytes(); wanted=os.environ.get('TESTSH_SHA256','').lower()
    if wanted and (not re.fullmatch('[0-9a-f]{64}',wanted) or hashlib.sha256(raw).hexdigest()!=wanted): raise ValueError('test.sh SHA256 不匹配')
    s=raw.decode('utf-8-sig').replace('\r\n','\n')
    pat=r'(?m)^([ \t]*)main(?:[ \t]+(?:"\$@"|"\$\{@\}"|\$@))?[ \t]*;?[ \t]*(?:#[^\n]*)?$'
    s,n=re.subn(pat,lambda m:m.group(1)+': # mo: main disabled',s)
    if n==0: raise ValueError('test.sh 的 main 入口形式不兼容；请提供匹配的 TESTSH_FILE')
    atomic(a[1],s,True)
elif op=='projects':
    rows=read(a[0]); allp=[p['projectId'] for p in rows if p.get('lifecycleState')=='ACTIVE']
    noorg=[p['projectId'] for p in rows if p.get('lifecycleState')=='ACTIVE' and not p.get('parent')]
    explicit=[x for x in re.split(r'[\s,]+',os.environ.get('PROJECT_IDS','').strip()) if x]
    if explicit: noorg=list(dict.fromkeys(explicit))
    for p in noorg:
        if p not in allp: allp.append(p)
    default=os.environ.get('MO_DEFAULT_PROJECT','')
    if default in allp: allp.remove(default); allp.insert(0,default)
    root=pathlib.Path(a[1])
    atomic(root/'projects.all',''.join(p+'\n' for p in allp),True)
    atomic(root/'projects.noorg',''.join(p+'\n' for p in noorg),True)
elif op=='billing':
    d=read(a[0]); acct=d.get('billingAccountName',''); enabled=d.get('billingEnabled')
    if type(enabled) is not bool or not isinstance(acct,str): raise ValueError('账单返回字段不完整')
    atomic(a[1],{'account':(acct[len('billingAccounts/'):] if acct.startswith('billingAccounts/') else acct),'enabled':enabled})
elif op=='billing-select':
    root=pathlib.Path(a[0]); preferred=a[1]; candidates=[]; errors=0
    for pid in (root/'projects.noorg').read_text().splitlines():
        f=root/'billing'/(pid+'.json')
        if not f.exists(): errors+=1; continue
        d=read(f)
        if d['account']: candidates.append((pid,d))
    candidates.sort(key=lambda p:(p[1]['account']!=preferred, not p[1]['enabled']))
    atomic(root/'key-candidates.txt',''.join(pid+'\n' for pid,_ in candidates),True)
    atomic(root/'billing-unknown.txt',str(errors)+'\n',True)
    print(len(candidates),errors)
elif op=='proxy-billing-select':
    root=pathlib.Path(a[0]); projects=pathlib.Path(a[1]).read_text().splitlines(); candidates=[]; errors=0
    for pid in projects:
        f=root/'proxy'/'billing'/(pid+'.json')
        if not f.exists(): errors+=1; continue
        try: d=read(f)
        except (OSError,ValueError,json.JSONDecodeError): errors+=1; continue
        if d.get('enabled') is True and d.get('account'): candidates.append(pid)
    atomic(root/'proxy-projects.billed',''.join(pid+'\n' for pid in candidates),True)
    print(len(candidates),errors)
elif op=='keys':
    s=pathlib.Path(a[0]).read_text(); found=list(dict.fromkeys(k for k in re.findall(r'(?<![A-Za-z0-9_.-])AQ\.[A-Za-z0-9_.-]{20,}',s) if not k.endswith('.')))
    if not found: sys.exit(1)
    # 与 mo v12 一致：完整读完 stdout 后取第一个有效 AQ，不用 head 提前切断上游管道。
    atomic(a[1],found[0]+'\n',True)
elif op=='proxy-list':
    root=pathlib.Path(a[2])
    for x in read(a[0]):
        if not x.get('name','').startswith('socks5-node') or x.get('status')!='RUNNING': continue
        md={m['key']:m.get('value','') for m in x.get('metadata',{}).get('items',[])}
        try:
            nic=x['networkInterfaces'][0]
            d=proxy({'project':a[1],'instance':x['name'],'zone':x['zone'].split('/')[-1],
              'host':nic['accessConfigs'][0]['natIP'],'port':md.get('kn-proxy-port',1080),
              'user':md.get('kn-proxy-user'),'password':md.get('kn-proxy-pass'),
              'network':nic.get('network','').split('/')[-1],'instance_id':str(x.get('id','')),'source':'existing'})
            atomic(root/(a[1]+'.'+x['name']+'.json'),d)
        except (KeyError,IndexError,TypeError,ValueError): continue
elif op=='proxy-fields':
    d=read(a[0])
    for k in ('project','instance','zone','host','port','network','user','password','instance_id'): print(d.get(k,''))
elif op=='proxy-input':
    u=urllib.parse.urlsplit(os.environ['PROXY_URL'])
    if u.scheme not in ('socks5','socks5h') or not u.hostname or u.path not in ('','/') or u.query or u.fragment: raise ValueError('PROXY_URL 格式无效')
    atomic(a[0],proxy({'host':u.hostname,'port':u.port or 1080,'user':urllib.parse.unquote(u.username or ''),
        'password':urllib.parse.unquote(u.password or ''),'project':'','instance':'','zone':'','network':'','source':'provided'}))
elif op=='proxy-new':
    root=pathlib.Path(a[1]); d={'project':a[0],'instance':'socks5-node-'+str(int(time.time()))+'-'+secrets.token_hex(3),
      'zone':'','host':'','port':int(os.environ['PROXY_PORT']),'user':'usr'+secrets.token_hex(4),'password':secrets.token_hex(12),
      'network':'','source':'created','created_run':os.environ['MO_RUN_TAG'],'instance_id':''}
    atomic(root/'candidate.json',d)
    for k,v in [('user',d['user']),('password',d['password']),('port',str(d['port']))]: atomic(root/(k+'.txt'),v,True)
elif op=='proxy-zone':
    d=read(a[0]);d['zone']=a[1];d['host']='';d['instance_id']='';d['network']='';d.pop('url',None);d.pop('adspower',None);atomic(a[0],d)
elif op=='proxy-fill':
    d=read(a[0]);x=obj(read(a[1]));nic=x['networkInterfaces'][0]
    d['host']=nic.get('accessConfigs',[{}])[0].get('natIP','');d['network']=nic.get('network','').split('/')[-1]
    d['zone']=x.get('zone',d['zone']).split('/')[-1];d['instance_id']=str(x.get('id',d.get('instance_id','')))
    if d['host']: d=proxy(d)
    atomic(a[0],d)
    sys.exit(0 if d['host'] and d['network'] else 1)
elif op=='proxy-check-config':
    d=proxy(read(a[0]));url=a[2]
    atomic(a[1],'proxy = '+cquote(d['url'].replace('socks5://','socks5h://',1))+'\nnoproxy = ""\nurl = '+cquote(url)+'\n',True)
elif op=='owned':
    d=read(a[0]);x=obj(read(a[1]))
    good=(d.get('created_run')==os.environ['MO_RUN_TAG'] and x.get('labels',{}).get('mo-run')==os.environ['MO_RUN_TAG']
      and d.get('instance_id') and str(x.get('id',''))==d['instance_id'] and x.get('name')==d['instance'])
    sys.exit(0 if good else 1)
elif op=='firewall':
    d=obj(read(a[0]));network=a[1];port=int(a[2])
    def allows(rule):
        if rule.get('IPProtocol') not in ('tcp','6','all'): return False
        if not rule.get('ports'): return True
        for v in rule['ports']:
            lo,_,hi=v.partition('-')
            if int(lo)<=port<=int(hi or lo):return True
        return False
    valid=(not d.get('disabled',False) and d.get('direction','INGRESS')=='INGRESS' and d.get('network','').split('/')[-1]==network
      and 'socks5-proxy' in d.get('targetTags',[]) and any(allows(x) for x in d.get('allowed',[]))
      and set(d.get('sourceRanges',[]))==set(os.environ['PROXY_SOURCE_RANGES'].split(',')))
    sys.exit(0 if valid else 1)
elif op=='context':
    atomic(a[0],{'account':a[1],'target_count':int(a[2]),'started_at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())})
elif op=='result':
    root=pathlib.Path(a[0]);rc=int(a[1]);valid=a[2]=='1';ctx=read(root/'context.json');keys=[];mapping=[]
    ids=(root/'key-projects.txt').read_text().splitlines() if (root/'key-projects.txt').exists() else []
    ids+=sorted(f.stem for f in (root/'keys').glob('*.key') if f.stem not in ids)
    for p in ids:
        f=root/'keys'/(p+'.key')
        if f.exists():
            for k in f.read_text().splitlines():
                if k not in keys:keys.append(k);mapping.append({'project':p,'key':k})
    keys=keys[:ctx['target_count']];mapping=mapping[:ctx['target_count']]
    px=read(root/'proxy.json') if valid and (root/'proxy.json').exists() else None
    phase=(root/'phase.txt').read_text().strip() if (root/'phase.txt').exists() else 'starting'
    status='running' if a[3]=='running' else ('completed' if rc==0 else 'cancelled' if rc in (129,130,143) else 'failed')
    d={**ctx,'status':status,'phase':phase,'exit_code':rc,'keys':keys,'key_count':len(keys),'key_projects':mapping,
       'proxy':px,'proxy_verified':bool(px),'run_dir':str(root),'elapsed_seconds':int(a[4])}
    atomic(root/'result.json',d);atomic(root/'keys.txt',''.join(k+'\n' for k in keys),True)
    final='\n================ FINAL RESULT ================\n'+(px['url'] if px else 'SOCKS5_FAILED')+'\n\n'+'\n'.join(keys)+'\n'
    atomic(root/'result.txt',final,True)
elif op=='status':
    root=pathlib.Path(a[0]);d=read(root/'result.json') if (root/'result.json').exists() else {}
    alive=(root/'pid.json').exists() and same(read(root/'pid.json'))
    phase=(root/'phase.txt').read_text().strip() if (root/'phase.txt').exists() else 'starting'
    label='运行中' if alive else '已完成' if d.get('status')=='completed' else '失败或已中断'
    print(f"状态: {label}\n阶段: {phase}\nKey 数: {d.get('key_count',0)}\n目录: {root}")
else: raise ValueError('未知操作 '+op)
MO_DATA
}

mo_log() {
  local line elapsed=$((SECONDS-${MO_STARTED_SECONDS:-0}))
  (( elapsed<0 )) && elapsed=0
  printf -v line '[%(%H:%M:%S)T (+%ss)] [mo] %s' -1 "$elapsed" "$*"
  printf '%s\n' "$line"
  [[ -n ${MO_RUN:-} ]] && printf '%s\n' "$line" >> "$MO_RUN/run.log"
  return 0
}
mo_phase() { printf '%s\n' "$1" > "$MO_RUN/phase.txt"; mo_log "$2"; }
mo_need() { local c; for c in "$@"; do command -v "$c" >/dev/null || { printf '缺少依赖: %s\n' "$c" >&2; return 1; }; done; }
mo_gc() { local budget=$1; shift; timeout --kill-after=8 "$budget" gcloud "$@" --quiet; }
mo_copy() { cp -- "$1" "$2.tmp.${BASHPID}" && mv -f -- "$2.tmp.${BASHPID}" "$2"; }
mo_proxy_fields() {
  local -a f=()
  mapfile -t f < <(mo_data proxy-fields "$1")
  (( ${#f[@]}==9 )) || return 1
  MO_CPROJ=${f[0]} MO_CNAME=${f[1]} MO_CZONE=${f[2]} MO_CHOST=${f[3]} MO_CPORT=${f[4]}
  MO_CNETWORK=${f[5]} MO_CUSER=${f[6]} MO_CPASS=${f[7]} MO_CID=${f[8]}
}
mo_usage() {
  cat <<'HELP'
mo.sh 14.0.0 — 完整 SOCKS5 任务与项目/Key 流程并发；结尾打印 SOCKS5 + AQ，不上传网站。
  bash mo.sh                    前台运行
  bash mo.sh --background       后台启动（先保存为本地文件）
  bash mo.sh --status [目录]     查看状态
  bash mo.sh --logs [目录]       实时查看日志，Ctrl+C 只停止查看
  bash mo.sh --results [目录]    再次打印“代理 + Key”
  bash mo.sh --json [目录]       查看包含账号、项目映射、AdsPower 格式的完整 JSON
  bash mo.sh --stop [目录]       停止本地子进程并保存结果；不因停止而删除云资源

常用环境变量（写在 bash 前，或先 export）：
  NEED_PROJECTS=2               需要的不同 AQ Key 数量
  BILLING_ID=xxx                优先使用该账单已关联项目；补建时绑定该账单
  REUSE_KEYS=0                  跳过控制器的已有 AQ 快速复用，执行原 API/IAM/提取函数
                               是否创建全新密钥仍由 test.sh 的提取函数决定
  PARALLEL_PROXY=1             默认从开头后台建代理，与项目创建/Key 提取重叠
  PARALLEL_PROXY=0             改成 Key 足量后才开始代理任务（更保守但更慢）
  REUSE_PROXY=0                 明确要求新建代理，忽略旧代理和创建记录
  PROJECT_IDS='项目1 项目2'      固定 Key 项目，数量应等于 NEED_PROJECTS
  PROXY_PROJECT=项目ID           限定代理项目；默认全账号复用，默认项目/Key 项目优先新建
  PROXY_URL='socks5://u:p@IP:端口' 使用给定认证代理，不创建 VM
  BILLING_SCAN_JOBS=4 KEY_SCAN_JOBS=2 KEY_JOBS=2 PROXY_SCAN_JOBS=3
  PROXY_SCAN_LIMIT=0            0=扫描全部可访问的 ACTIVE 项目；正整数=显式限制数量
  PROXY_WAIT_SECONDS=180        新 VM 首次等待的真实墙钟预算
  PROXY_REUSE_GRACE_SECONDS=20  旧代理统一宽限预算，未到期就绪会提前结束
  PROXY_REPAIR_WAIT_SECONDS=60  本次新 VM 重置后复检预算
  PROXY_PROJECT_TRIES=2         最多尝试多少个代理项目
  PROXY_ZONE_TRIES=8 PROXY_ZONES_PER_PROJECT=3 PROXY_SHUFFLE_ZONES=1
  PROXY_CANDIDATE_WAIT_SECONDS=720 等待并发项目流程提供新项目的最长时间
  PROXY_ZONES='us-west1-a us-central1-a'  自定义候选区域
  PROXY_RESET_ON_FAILURE=0      关闭本次新建 VM 的重置兜底
  DELETE_FAILED_VM=0           保留失败的新 VM 并停止本次建机；默认仅清理本次确认创建的失败 VM
  TESTSH_FILE=/path/test.sh     使用本地函数库；仍须提供原 mo v12 使用的 6 个函数
  TESTSH_SHA256=64位摘要        可选内容校验
  TESTSH_CACHE_TTL=3600         函数库缓存秒数，0=每次下载
  MO_STATE_DIR=/path           默认 ~/.local/state/mo；任务结果文件权限 600

最终结果固定为：FINAL RESULT 标题 → 一条 SOCKS5 URL/失败标志 → 空行 → 每行一个完整 AQ。
遇到部分失败也保留已得到的 Key；退出码非零。--results/--json 不进行任何云端操作。
并发模式下若 Key 最终失败，代理 VM 可能已经创建；资源信息保存在任务目录的 resources.json。
首次运行需 gcloud 已登录且当前账号具有相应权限、有效账单与配额。
Cloud Shell 的后台进程仍受平台会话限制；nohup 不会使它永久运行。
HELP
}

mo_make_worker() {
  declare -f mo_data > "$MO_RUN/upstream-worker.sh"
  cat >> "$MO_RUN/upstream-worker.sh" <<'WORKER'
readonly MO_ABI_MODE="$1" MO_ABI_LIB="$2" MO_ABI_OUT="$3"
shift 3
readonly MO_ABI_ARG1="${1:-}" MO_ABI_ARG2="${2:-}"
# 必须在独立 Bash 的顶层 source，保留 test.sh 的全局关联数组语义。
source "$MO_ABI_LIB" || exit 70
set +e +E
set -u -o pipefail
trap - ERR EXIT INT TERM HUP
umask 077
for MO_ABI_CACHE in BILLING_BLOCKED_APIS PERMISSION_BLOCKED_APIS; do
  if ! declare -p "$MO_ABI_CACHE" 2>/dev/null | grep -q '^declare -A'; then
    unset "$MO_ABI_CACHE"
    declare -gA "$MO_ABI_CACHE"
  fi
done
case "$MO_ABI_MODE" in
  check)
    for MO_ABI_FN in billing_accounts_tsv project_billing_enabled create_projects_exact ensure_vertex_key_apis v27_setup_and_extract_aq_key find_authorization_key_string; do
      declare -F "$MO_ABI_FN" >/dev/null || { printf '缺少上游函数: %s\n' "$MO_ABI_FN" >&2; exit 71; }
    done
    [[ -n ${SERVICE_ACCOUNT_NAME:-} ]] || { printf '上游未定义 SERVICE_ACCOUNT_NAME\n' >&2; exit 71; } ;;
  billing) billing_accounts_tsv > "$MO_ABI_OUT" ;;
  create)
    MO_ABI_CREATED=()
    create_projects_exact "$MO_ABI_ARG1" "$MO_ABI_ARG2" MO_ABI_CREATED 'mo-stage1'
    MO_ABI_RC=$?
    printf '%s\n' "${MO_ABI_CREATED[@]}" > "$MO_ABI_OUT"
    exit "$MO_ABI_RC" ;;
  lookup)
    find_authorization_key_string "$MO_ABI_ARG1" "${SERVICE_ACCOUNT_NAME}@${MO_ABI_ARG1}.iam.gserviceaccount.com" > "$MO_ABI_OUT.stdout"
    MO_ABI_RC=$?
    (( MO_ABI_RC==0 )) || exit "$MO_ABI_RC"
    mo_data keys "$MO_ABI_OUT.stdout" "$MO_ABI_OUT" ;;
  key)
    ensure_vertex_key_apis "$MO_ABI_ARG1" 'mo-Vertex' || exit 72
    v27_setup_and_extract_aq_key "$MO_ABI_ARG1" 1 > "$MO_ABI_OUT.stdout"
    MO_ABI_RC=$?
    (( MO_ABI_RC==0 )) || exit "$MO_ABI_RC"
    mo_data keys "$MO_ABI_OUT.stdout" "$MO_ABI_OUT" ;;
  *) exit 73 ;;
esac
WORKER
}
mo_prepare_library() {
  local raw="$MO_RUN/test.raw.sh" lib="$MO_RUN/test.lib.sh" cache
  cache="$MO_STATE/cache/test-$(mo_data hash "$TESTSH_URL|${TESTSH_SHA256:-}").sh"
  if [[ -n ${TESTSH_FILE:-} ]]; then cp -- "$TESTSH_FILE" "$raw" || return 1
  elif mo_data fresh "$cache" "$TESTSH_CACHE_TTL"; then mo_copy "$cache" "$raw" || return 1
  elif ! curl --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 \
      "$TESTSH_URL" -o "$raw" 2> "$MO_RUN/logs/download.log"; then
    [[ -s $cache ]] || { mo_log '下载 test.sh 失败，可用 TESTSH_FILE 指定本地文件'; return 1; }
    mo_log '下载失败，使用此前校验过的同源缓存'; mo_copy "$cache" "$raw" || return 1
  fi
  mo_data library "$raw" "$lib" > "$MO_RUN/logs/library-build.log" 2>&1 || { mo_log 'test.sh 入口/摘要不匹配，见 logs/library-build.log'; return 1; }
  bash -n "$lib" 2>> "$MO_RUN/logs/library-build.log" || return 1
  timeout --kill-after=8 60 bash "$MO_RUN/upstream-worker.sh" check "$lib" '' \
    > "$MO_RUN/logs/library-check.log" 2>&1 < /dev/null || { mo_log 'test.sh 初始化/接口检查失败，见 logs/library-check.log'; return 1; }
  [[ -n ${TESTSH_FILE:-} ]] || mo_copy "$raw" "$cache" || return 1
  : > "$MO_RUN/library.ready"
}
mo_wait_library() {
  [[ ${MO_LIB_JOINED:-0} == 1 ]] && [[ -f $MO_RUN/library.ready ]] && return 0
  wait "$MO_LIB_PID"; local rc=$?; MO_LIB_JOINED=1
  (( rc==0 )) && [[ -f $MO_RUN/library.ready ]]
}
mo_billing_cached_one() {
  local p=$1 out=$2 fd rc=1 base="$MO_RUN/billing-cache/$1" tmp
  exec {fd}> "$base.lock" || return 1
  flock "$fd" || return 1
  if [[ ! -s $base.status ]];then
    if mo_gc "$BILLING_TIMEOUT" billing projects describe "$p" --format=json \
      > "$base.raw.json" 2> "$MO_RUN/logs/billing-shared-$p.log" && \
      mo_data billing "$base.raw.json" "$base.json" 2>> "$MO_RUN/logs/billing-shared-$p.log";then rc=0;fi
    tmp="$base.status.tmp.${BASHPID}"
    printf '%s\n' "$rc" > "$tmp" && mv -f -- "$tmp" "$base.status" || rc=1
  fi
  read -r rc < "$base.status"
  if [[ $rc == 0 && -s $base.json ]];then mo_copy "$base.json" "$out" || rc=1;else rc=1;fi
  flock -u "$fd" || true
  exec {fd}>&-
  return "$rc"
}
mo_billing_one() { mo_billing_cached_one "$1" "$MO_RUN/billing/$1.json"; }
mo_proxy_billing_one() { mo_billing_cached_one "$1" "$MO_RUN/proxy/billing/$1.json"; }
mo_prepare_proxy_projects() {
  local p i n unknown tmp="$MO_RUN/proxy-projects.scan.tmp.${BASHPID}"
  local -a all=() jobs=()
  mkdir -p "$MO_RUN/proxy/billing" || return 1
  if [[ -n ${PROXY_PROJECT:-} ]]; then all=("$PROXY_PROJECT")
  else mapfile -t all < "$MO_RUN/projects.all";fi
  (( PROXY_SCAN_LIMIT>0 )) && all=("${all[@]:0:PROXY_SCAN_LIMIT}")
  printf '%s\n' "${all[@]}" | awk NF > "$tmp" || return 1
  mv -f -- "$tmp" "$MO_RUN/proxy-projects.scan" || return 1
  mo_log "[代理] 扫描账户下 ${#all[@]} 个候选项目的账单状态，并发 $PROXY_SCAN_JOBS"
  for ((i=0;i<${#all[@]};i+=PROXY_SCAN_JOBS)); do
    jobs=()
    for p in "${all[@]:i:PROXY_SCAN_JOBS}"; do mo_proxy_billing_one "$p" & jobs+=("$!"); done
    for p in "${jobs[@]}"; do wait "$p" || true; done
  done
  mo_data proxy-billing-select "$MO_RUN" "$MO_RUN/proxy-projects.scan" > "$MO_RUN/proxy-billing-summary.txt" || return 1
  read -r n unknown < "$MO_RUN/proxy-billing-summary.txt"
  mo_log "[代理] 已绑定账单候选项目: $n 个；查询失败: $unknown 个"
}
mo_select_projects() {
  local p i n rc bid=${BILLING_ID:-} unknown=0 needed missing key
  local -a noorg=() jobs=() candidates=() chosen=() work=() created=()
  local -A seenkey=() selected=()
  mapfile -t noorg < "$MO_RUN/projects.noorg"
  if [[ -n ${PROJECT_IDS:-} && ${#noorg[@]} -ne $NEED_PROJECTS ]]; then mo_log 'PROJECT_IDS 数量必须等于 NEED_PROJECTS'; return 1; fi
  mo_log "账单状态每项目只读一次，并发上限 $BILLING_SCAN_JOBS"
  for ((i=0;i<${#noorg[@]};i+=BILLING_SCAN_JOBS)); do
    jobs=()
    for p in "${noorg[@]:i:BILLING_SCAN_JOBS}"; do mo_billing_one "$p" & jobs+=("$!"); done
    for p in "${jobs[@]}"; do wait "$p" || true; done
  done
  mo_wait_library || return 1
  bid=${bid#billingAccounts/}
  if [[ -z $bid ]]; then
    timeout --kill-after=8 60 bash "$MO_RUN/upstream-worker.sh" billing "$MO_RUN/test.lib.sh" "$MO_RUN/billing-accounts.tsv" \
      > "$MO_RUN/logs/billing-accounts.log" 2>&1 < /dev/null || true
    bid=$(awk -F'\t' 'NF { sub(/^billingAccounts\//,"",$1); print $1; exit }' "$MO_RUN/billing-accounts.tsv" 2>/dev/null)
  fi
  MO_BILLING_ID=$bid
  [[ -z $bid ]] || mo_log "优先账单: $bid"
  mo_data billing-select "$MO_RUN" "$bid" > "$MO_RUN/billing-summary.txt" || return 1
  read -r n unknown < "$MO_RUN/billing-summary.txt"
  mapfile -t candidates < "$MO_RUN/key-candidates.txt"
  mo_log "可用关联项目 $n 个；查询失败 $unknown 个（不把查询失败当作未绑定）"
  if [[ $REUSE_KEYS == 1 ]]; then
    for ((i=0;i<${#candidates[@]};i+=KEY_SCAN_JOBS)); do
      jobs=()
      for p in "${candidates[@]:i:KEY_SCAN_JOBS}"; do
        timeout --kill-after=8 "$KEY_SCAN_TIMEOUT" bash "$MO_RUN/upstream-worker.sh" lookup "$MO_RUN/test.lib.sh" "$MO_RUN/lookup/$p.key" "$p" \
          > "$MO_RUN/logs/lookup-$p.log" 2>&1 < /dev/null & jobs+=("$!")
      done
      for p in "${jobs[@]}"; do wait "$p" || true; done
      for p in "${candidates[@]:i:KEY_SCAN_JOBS}"; do
        [[ -s $MO_RUN/lookup/$p.key ]] || continue
        read -r key < "$MO_RUN/lookup/$p.key"
        [[ -n ${seenkey[$key]:-} ]] && continue
        seenkey["$key"]=1; selected["$p"]=1; chosen+=("$p")
        mo_copy "$MO_RUN/lookup/$p.key" "$MO_RUN/keys/$p.key" || return 1
        mo_log "复用已有 AQ: $p"
        (( ${#chosen[@]}>=NEED_PROJECTS )) && break
      done
      (( ${#chosen[@]}>=NEED_PROJECTS )) && break
    done
  fi
  needed=$((NEED_PROJECTS-${#chosen[@]}))
  for p in "${candidates[@]}"; do
    (( ${#work[@]}>=needed )) && break
    [[ -n ${selected[$p]:-} ]] && continue
    work+=("$p"); selected["$p"]=1
  done
  missing=$((needed-${#work[@]}))
  if (( missing>0 )); then
    printf '%s\n' "${chosen[@]}" "${work[@]}" | awk NF > "$MO_RUN/key-projects.txt"
    if (( unknown>0 )) || [[ -n ${PROJECT_IDS:-} ]]; then mo_log '项目不足且存在未确认状态/固定项目约束，未自动补建'; return 1; fi
    [[ -n $bid ]] || { mo_log '已有项目不足，且无法获得可用账单；未补建'; return 1; }
    mo_log "复用项目槽位不足，补建 $missing 个项目"
    timeout --kill-after=10 "$CREATE_TIMEOUT" bash "$MO_RUN/upstream-worker.sh" create "$MO_RUN/test.lib.sh" "$MO_RUN/new-projects.txt" "$missing" "$bid" \
      > "$MO_RUN/logs/create-projects.log" 2>&1 < /dev/null
    rc=$?
    (( rc==0 )) || mo_log "项目创建返回 $rc；只接收已返回的项目，不重复提交"
    [[ -s $MO_RUN/new-projects.txt ]] && mapfile -t created < "$MO_RUN/new-projects.txt"
    for p in "${created[@]}"; do
      [[ $p =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ && -z ${selected[$p]:-} ]] || continue
      work+=("$p");selected["$p"]=1
      (( ${#work[@]}>=needed )) && break
    done
  fi
  MO_KEY_PROJECTS=("${chosen[@]}" "${work[@]}")
  printf '%s\n' "${MO_KEY_PROJECTS[@]}" | awk NF > "$MO_RUN/key-projects.txt"
  (( ${#MO_KEY_PROJECTS[@]}==NEED_PROJECTS )) || { mo_log '未获得足够 Key 项目，保留已有结果并停止'; return 1; }
  mo_log "最终 Key 项目: ${MO_KEY_PROJECTS[*]}"
}
mo_extract_keys() {
  local i p rc failed=0 count
  local -a jobs=() names=()
  for ((i=0;i<${#MO_KEY_PROJECTS[@]};i+=KEY_JOBS)); do
    jobs=();names=()
    for p in "${MO_KEY_PROJECTS[@]:i:KEY_JOBS}"; do
      [[ -s $MO_RUN/keys/$p.key ]] && continue
      mo_log "API/IAM/SA/AQ 处理: $p"
      timeout --kill-after=10 "$KEY_TIMEOUT" bash "$MO_RUN/upstream-worker.sh" key "$MO_RUN/test.lib.sh" "$MO_RUN/keys/$p.key" "$p" \
        > "$MO_RUN/logs/key-$p.log" 2>&1 < /dev/null & jobs+=("$!"); names+=("$p")
    done
    for ((p=0;p<${#jobs[@]};p++)); do
      wait "${jobs[p]}";rc=$?
      if (( rc==0 )) && [[ -s $MO_RUN/keys/${names[p]}.key ]]; then mo_log "AQ 就绪: ${names[p]}"
      else failed=$((failed+1));mo_log "AQ 失败: ${names[p]}，退出码 $rc，详见对应 logs/key-*.log";fi
    done
    mo_data result "$MO_RUN" 0 0 running "$((SECONDS-${MO_STARTED_SECONDS:-0}))" || return 1
  done
  count=$(wc -l < "$MO_RUN/keys.txt")
  if (( failed>0 || count<NEED_PROJECTS )); then
    mo_log "只得到 $count/$NEED_PROJECTS 个不同 AQ；停止主任务。并发代理可能已创建资源，记录会保留"
    return 1
  fi
  mo_log "Key 已足量: $count/$NEED_PROJECTS"
}

# 认证 + 远端 DNS + HTTPS，显式清空 NO_PROXY，避免环境变量绕过代理造成假成功。
mo_proxy_test() {
  local f=$1 budget=${2:-$((PROXY_CHECK_TIMEOUT*2))} end=$((SECONDS+${2:-$((PROXY_CHECK_TIMEOUT*2))})) url remaining seconds
  local cfg="$1.probe.curl"
  for url in "$PROXY_TEST_URL" "$PROXY_TEST_URL_FALLBACK"; do
    remaining=$((end-SECONDS)); (( remaining>0 )) || return 1
    seconds=$PROXY_CHECK_TIMEOUT; (( seconds>remaining )) && seconds=$remaining
    mo_data proxy-check-config "$f" "$cfg" "$url" 2>/dev/null || return 1
    remaining=$((end-SECONDS)); (( remaining>0 )) || return 1
    (( seconds>remaining )) && seconds=$remaining
    if curl -4 --config "$cfg" --silent --show-error --fail --connect-timeout "$seconds" --max-time "$seconds" \
      --output /dev/null 2> "$cfg.log"; then return 0; fi
  done
  return 1
}
mo_save_proxy() {
  mo_copy "$1" "$MO_RUN/proxy.json" || return 1
  [[ ${2:-cache} == provided ]] || mo_copy "$1" "$MO_PROXY_CACHE" || return 1
  mo_log 'SOCKS5 认证、远端 DNS 与 HTTPS 请求已通过'
}
mo_wait_proxy() {
  local f=$1 budget=${2:-$PROXY_WAIT_SECONDS} end remaining nap last=$SECONDS
  end=$((SECONDS+budget))
  while (( SECONDS<end )); do
    remaining=$((end-SECONDS))
    if mo_proxy_test "$f" "$remaining"; then mo_save_proxy "$f"; return $?; fi
    if (( SECONDS-last>=15 )); then mo_log "等待代理就绪，剩余 $((end-SECONDS>0 ? end-SECONDS : 0))s";last=$SECONDS;fi
    remaining=$((end-SECONDS));nap=$PROXY_POLL_SECONDS;(( nap>remaining )) && nap=$remaining
    (( nap>0 )) && sleep "$nap"
  done
  return 1
}
mo_proxy_list_one() {
  local p=$1
  if mo_gc 20 compute instances list --project="$p" --filter='name~socks5-node AND status=RUNNING' --format=json \
    > "$MO_RUN/proxy/list-$p.json" 2> "$MO_RUN/logs/proxy-list-$p.log"; then
    mo_data proxy-list "$MO_RUN/proxy/list-$p.json" "$p" "$MO_RUN/proxy/candidates" \
      2>> "$MO_RUN/logs/proxy-list-$p.log"
  fi
}
mo_scan_proxy() {
  local p f i rc
  local -a all=() jobs=() found=()
  if [[ -n ${PROXY_URL:-} ]]; then
    mo_data proxy-input "$MO_RUN/proxy/provided.json" || return 1
    mo_proxy_test "$MO_RUN/proxy/provided.json" || return 1
    mo_save_proxy "$MO_RUN/proxy/provided.json" provided; return $?
  fi
  if [[ $REUSE_PROXY == 1 && -s $MO_PROXY_CACHE ]]; then
    mo_copy "$MO_PROXY_CACHE" "$MO_RUN/proxy/candidates/000-cached.json" || return 1
    f="$MO_RUN/proxy/candidates/000-cached.json"
    if mo_proxy_fields "$f" && { [[ -z ${PROXY_PROJECT:-} ]] || [[ $PROXY_PROJECT == "$MO_CPROJ" ]]; }; then
      if mo_proxy_test "$f"; then mo_log '缓存代理仍可用，跳过全账号扫描';mo_save_proxy "$f";return $?;fi
      if [[ -n $MO_CPROJ && -n $MO_CNAME && -n $MO_CZONE ]]; then
        if mo_gc 30 compute instances describe "$MO_CNAME" --project="$MO_CPROJ" --zone="$MO_CZONE" --format=json \
          > "$MO_RUN/proxy/cache-instance.json" 2> "$MO_RUN/logs/cache-instance.log"; then
          mo_data proxy-fill "$f" "$MO_RUN/proxy/cache-instance.json" 2>> "$MO_RUN/logs/cache-instance.log" || : > "$MO_RUN/proxy.uncertain"
          if mo_proxy_test "$f"; then mo_save_proxy "$f";return $?;fi
        elif [[ -z $MO_CHOST ]] || ! grep -qiE 'not found|NOT_FOUND' "$MO_RUN/logs/cache-instance.log"; then
          : > "$MO_RUN/proxy.uncertain"
        else rm -f -- "$f";fi
      fi
    else rm -f -- "$f";fi
  fi
  mo_prepare_proxy_projects || return 1
  [[ $REUSE_PROXY == 1 ]] || return 1
  mapfile -t all < "$MO_RUN/proxy-projects.billed"
  mo_log "[代理] 扫描 ${#all[@]} 个已绑账单项目中的现有 SOCKS5，并发 $PROXY_SCAN_JOBS"
  for ((i=0;i<${#all[@]};i+=PROXY_SCAN_JOBS)); do
    jobs=()
    for p in "${all[@]:i:PROXY_SCAN_JOBS}"; do mo_proxy_list_one "$p" & jobs+=("$!");done
    for p in "${jobs[@]}";do wait "$p" || true;done
    shopt -s nullglob;found=("$MO_RUN/proxy/candidates/"*.json);shopt -u nullglob
    for f in "${found[@]}";do
      [[ -f $f.checked ]] && continue
      : > "$f.checked"
      if mo_proxy_test "$f";then mo_save_proxy "$f";return $?;fi
    done
  done
  return 1
}
mo_recheck_old_proxy() {
  local end=$((SECONDS+PROXY_REUSE_GRACE_SECONDS)) f remaining nap
  local -a found=()
  shopt -s nullglob;found=("$MO_RUN/proxy/candidates/"*.json);shopt -u nullglob
  (( ${#found[@]}>0 )) || return 1
  while (( SECONDS<end ));do
    for f in "${found[@]}";do
      remaining=$((end-SECONDS));(( remaining>0 )) || break
      if mo_proxy_test "$f" "$remaining";then mo_save_proxy "$f";return $?;fi
    done
    remaining=$((end-SECONDS));nap=$PROXY_POLL_SECONDS;(( nap>remaining )) && nap=$remaining
    (( nap>0 )) && sleep "$nap"
  done
  # 后台代理任务可尝试修复一台有完整元数据的旧代理入口，不重置/删除旧 VM。
  f=${found[0]}
  if mo_proxy_fields "$f" && [[ -n $MO_CNETWORK && -n $MO_CPROJ && -n $MO_CNAME && -n $MO_CZONE ]];then
    mo_log '旧代理仍不可用，尝试修复其防火墙和实例标签'
    if mo_ensure_firewall "$MO_CPROJ" "$MO_CNETWORK" "$MO_CPORT" && \
      mo_gc 45 compute instances add-tags "$MO_CNAME" --project="$MO_CPROJ" --zone="$MO_CZONE" --tags=socks5-proxy \
        > "$MO_RUN/logs/old-proxy-tags.log" 2>&1;then
      if mo_proxy_test "$f";then mo_save_proxy "$f";return $?;fi
    fi
  fi
  return 1
}
mo_ensure_network() {
  local project=$1 net
  for net in default kn-proxy-net;do
    if mo_gc 30 compute networks describe "$net" --project="$project" --format=json \
      > "$MO_RUN/proxy/network-$net.json" 2> "$MO_RUN/logs/network-$net.log";then printf '%s\n' "$net";return 0;fi
    grep -qiE 'not found|NOT_FOUND' "$MO_RUN/logs/network-$net.log" || return 1
  done
  mo_log "[$project] 创建 kn-proxy-net 自动模式网络" >&2
  if mo_gc "$GCLOUD_TIMEOUT" compute networks create kn-proxy-net --project="$project" --subnet-mode=auto --bgp-routing-mode=regional --format=json \
    > "$MO_RUN/proxy/network-kn-proxy-net.json" 2> "$MO_RUN/logs/network-create.log";then printf 'kn-proxy-net\n';return 0;fi
  # 请求可能已成功，重新确认同名网络，不另建名字。
  mo_gc 30 compute networks describe kn-proxy-net --project="$project" --format=json \
    > "$MO_RUN/proxy/network-kn-proxy-net.json" 2>> "$MO_RUN/logs/network-create.log" || return 1
  printf 'kn-proxy-net\n'
}
mo_ensure_firewall() {
  local project=$1 network=$2 port=$3 name n rc
  name="mo-socks5-${port}-$(mo_data hash "$network")"
  for n in 1 2 3;do
    if mo_gc 30 compute firewall-rules describe "$name" --project="$project" --format=json \
      > "$MO_RUN/proxy/firewall.json" 2> "$MO_RUN/logs/firewall.log";then
      mo_data firewall "$MO_RUN/proxy/firewall.json" "$network" "$port" && return 0
      # 独立规则按网络命名，不删除或覆盖旧版 kn/mo 的其他规则。
      mo_gc "$GCLOUD_TIMEOUT" compute firewall-rules update "$name" --project="$project" --allow="tcp:$port" \
        --source-ranges="$PROXY_SOURCE_RANGES" --target-tags=socks5-proxy --priority=1000 --no-disabled \
        > "$MO_RUN/logs/firewall-update.log" 2>&1 || true
    elif grep -qiE 'not found|NOT_FOUND' "$MO_RUN/logs/firewall.log";then
      mo_gc "$GCLOUD_TIMEOUT" compute firewall-rules create "$name" --project="$project" --network="$network" \
        --direction=INGRESS --priority=1000 --action=ALLOW --rules="tcp:$port" --source-ranges="$PROXY_SOURCE_RANGES" \
        --target-tags=socks5-proxy --format=json > "$MO_RUN/proxy/firewall.json" 2> "$MO_RUN/logs/firewall-create.log"
      rc=$?
      if (( rc==0 )) && mo_data firewall "$MO_RUN/proxy/firewall.json" "$network" "$port";then return 0;fi
    fi
    if mo_gc 30 compute firewall-rules describe "$name" --project="$project" --format=json \
      > "$MO_RUN/proxy/firewall.json" 2>> "$MO_RUN/logs/firewall.log" && \
      mo_data firewall "$MO_RUN/proxy/firewall.json" "$network" "$port";then return 0;fi
    (( n<3 )) && sleep "$((2**n))"
  done
  return 1
}
mo_make_startup_script() {
  local path=$1 port=$2 user=$3 pass=$4
  cat > "$path" <<'VM'
#!/bin/bash
set -Eeuo pipefail
umask 077
exec >>/var/log/mo-microsocks-startup.log 2>&1
export DEBIAN_FRONTEND=noninteractive
MO_BUILD_DIR=''
trap '[[ -z $MO_BUILD_DIR ]] || rm -rf -- "$MO_BUILD_DIR"' EXIT
retry() {
  local n
  for n in 1 2 3;do
    "$@" && return 0
    (( n<3 )) && sleep "$((n*2))"
  done
  return 1
}
BIN=$(command -v microsocks || true)
[[ -n $BIN ]] || { [[ ! -x /usr/local/bin/microsocks ]] || BIN=/usr/local/bin/microsocks; }
if [[ -z $BIN ]];then
  if retry apt-get -o Acquire::Retries=2 update && \
     retry apt-get -o Acquire::Retries=2 -o DPkg::Lock::Timeout=120 install -y --no-install-recommends ca-certificates microsocks;then
    BIN=$(command -v microsocks)
  else
    # 保留 mo v12 的源码回退；任一步失败就退出，避免打印虚假的安装成功。
    retry apt-get -o Acquire::Retries=2 update
    retry apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends ca-certificates build-essential git
    MO_BUILD_DIR=$(mktemp -d /tmp/mo-microsocks-build.XXXXXX)
    git clone --depth 1 https://github.com/rofl0r/microsocks.git "$MO_BUILD_DIR/src"
    make -C "$MO_BUILD_DIR/src"
    install -m 0755 "$MO_BUILD_DIR/src/microsocks" /usr/local/bin/microsocks
    BIN=/usr/local/bin/microsocks
  fi
fi
[[ -x $BIN ]]
install -d -m 700 /etc/mo-microsocks
cat > /etc/mo-microsocks/auth.env <<'AUTH'
PROXY_USER=__USER__
PROXY_PASS=__PASS__
AUTH
chmod 600 /etc/mo-microsocks/auth.env
cat > /etc/systemd/system/microsocks.service <<SERVICE
[Unit]
Description=MicroSocks SOCKS5 Proxy
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=nobody
Group=nogroup
EnvironmentFile=/etc/mo-microsocks/auth.env
ExecStart=${BIN} -i 0.0.0.0 -p __PORT__ -u \${PROXY_USER} -P \${PROXY_PASS}
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
systemctl enable microsocks
systemctl restart microsocks
systemctl is-active --quiet microsocks
VM
  # 新凭据由 secrets.token_hex 生成，仅字母/数字；不会进入 sed 替换元字符。
  sed -i -e "s/__PORT__/$port/g" -e "s/__USER__/$user/g" -e "s/__PASS__/$pass/g" "$path"
}
mo_vm_call() {
  local f=$1 network=$2
  local -a netarg=()
  mo_proxy_fields "$f" || return 1
  [[ -z $network ]] || netarg=("--network=$network")
  mo_gc "$VM_CREATE_TIMEOUT" compute instances create "$MO_CNAME" --project="$MO_CPROJ" --zone="$MO_CZONE" \
    --machine-type=e2-micro --image-family=debian-12 --image-project=debian-cloud --tags=socks5-proxy \
    --labels="mo-run=$MO_RUN_TAG" "${netarg[@]}" \
    --metadata-from-file="startup-script=$MO_RUN/proxy/startup.sh,kn-proxy-user=$MO_RUN/proxy/user.txt,kn-proxy-pass=$MO_RUN/proxy/password.txt,kn-proxy-port=$MO_RUN/proxy/port.txt" \
    --format=json > "$MO_RUN/proxy/instance.json" 2> "$MO_RUN/logs/vm-last.log"
}
mo_vm_owned() {
  mo_proxy_fields "$1" || return 1
  mo_gc 30 compute instances describe "$MO_CNAME" --project="$MO_CPROJ" --zone="$MO_CZONE" --format=json \
    > "$MO_RUN/proxy/owned-instance.json" 2> "$MO_RUN/logs/owned-instance.log" || return 1
  mo_data owned "$1" "$MO_RUN/proxy/owned-instance.json"
}
mo_delete_failed_vm() {
  local f=$1
  [[ $DELETE_FAILED_VM == 1 ]] || { : > "$MO_RUN/proxy.uncertain";mo_log '保留失败 VM，停止继续建机；资源信息已保存';return 1; }
  mo_vm_owned "$f" || { : > "$MO_RUN/proxy.uncertain";mo_log '无法确认 VM 属于本次创建，不删除，也不继续建机';return 1; }
  mo_log "清理本次确认创建的失败 VM: $MO_CPROJ / $MO_CNAME / $MO_CZONE"
  if ! mo_gc "$GCLOUD_TIMEOUT" compute instances delete "$MO_CNAME" --project="$MO_CPROJ" --zone="$MO_CZONE" --delete-disks=all \
    > "$MO_RUN/logs/vm-delete.log" 2>&1;then
    : > "$MO_RUN/proxy.uncertain";mo_log '删除未确认成功，停止继续建机；见 logs/vm-delete.log';return 1
  fi
  rm -f -- "$MO_PROXY_CACHE"
}
mo_show_serial_tail() {
  local f=$1
  mo_proxy_fields "$f" || return 1
  mo_gc 30 compute instances get-serial-port-output "$MO_CNAME" --project="$MO_CPROJ" --zone="$MO_CZONE" --port=1 \
    > "$MO_RUN/logs/vm-serial.log" 2>&1 || true
  mo_log '启动诊断已保存到 logs/vm-serial.log'
}
build_proxy() {
  local project zone f="$MO_RUN/proxy/candidate.json" network rc total=0 per delay end
  local -a projects=("$@") zones=()
  if [[ -s $MO_RUN/proxy-attempts.count ]];then
    read -r total < "$MO_RUN/proxy-attempts.count"
    [[ $total =~ ^[0-9]+$ ]] || total=0
  fi
  for project in "${projects[@]}";do
    (( total<PROXY_ZONE_TRIES )) || break
    mo_data proxy-new "$project" "$MO_RUN/proxy" || return 1
    mo_proxy_fields "$f" || return 1
    mo_make_startup_script "$MO_RUN/proxy/startup.sh" "$MO_CPORT" "$MO_CUSER" "$MO_CPASS" || return 1
    mapfile -t zones < <(printf '%s\n' "${PROXY_ZONES:-us-west1-a us-west1-b us-west1-c us-central1-a us-central1-b us-central1-c us-east1-b us-east1-c us-east1-d us-east4-a us-east4-b us-east4-c us-west2-a us-west2-b us-west2-c us-west3-a us-west3-b us-west3-c us-west4-a us-west4-b us-west4-c us-south1-a us-south1-b us-south1-c}" | tr ' ,' '\n\n' | awk NF)
    if [[ $PROXY_SHUFFLE_ZONES == 1 ]];then mapfile -t zones < <(printf '%s\n' "${zones[@]}" | shuf);fi
    per=0;network=''
    for zone in "${zones[@]}";do
      (( total<PROXY_ZONE_TRIES && per<PROXY_ZONES_PER_PROJECT )) || break
      total=$((total+1));per=$((per+1))
      printf '%s\n' "$total" > "$MO_RUN/proxy-attempts.count.tmp.${BASHPID}" && \
        mv -f -- "$MO_RUN/proxy-attempts.count.tmp.${BASHPID}" "$MO_RUN/proxy-attempts.count" || return 1
      mo_data proxy-zone "$f" "$zone" || return 1
      mo_copy "$f" "$MO_RUN/resources.json" || return 1
      mo_copy "$f" "$MO_PROXY_CACHE" || return 1
      mo_log "[$project] 直接创建 VM: $zone（总 $total/$PROXY_ZONE_TRIES，本项目 $per/$PROXY_ZONES_PER_PROJECT）"
      mo_vm_call "$f" "$network";rc=$?
      if (( rc!=0 )) && grep -qiE 'SERVICE_DISABLED|has not been used in project .* before or it is disabled' "$MO_RUN/logs/vm-last.log";then
        mo_log "[$project] Compute 未启用，开启后按 2/4/8/16 秒间隔重试同一 VM，成功即结束等待"
        mo_gc 180 services enable compute.googleapis.com --project="$project" > "$MO_RUN/logs/compute-enable.log" 2>&1 || true
        for delay in 2 4 8 16;do
          sleep "$delay"
          mo_vm_call "$f" "$network";rc=$?
          (( rc==0 )) && break
          grep -qiE 'SERVICE_DISABLED|has not been used in project .* before or it is disabled' "$MO_RUN/logs/vm-last.log" || break
        done
      fi
      if (( rc!=0 )) && grep -qiE 'default network.*not found|network.*default.*not found|resource.*default.*not found' "$MO_RUN/logs/vm-last.log";then
        network=$(mo_ensure_network "$project") || { mo_log '默认/备用网络无法确认，停止本次建机';return 1; }
        mo_vm_call "$f" "$network";rc=$?
      fi
      cp -- "$MO_RUN/logs/vm-last.log" "$MO_RUN/logs/vm-$project-$zone.log"
      if (( rc!=0 ));then
        mo_proxy_fields "$f" || return 1
        # 所有非零返回先核对同名实例，避免 timeout/响应丢失后换区多建。
        if mo_gc 30 compute instances describe "$MO_CNAME" --project="$project" --zone="$zone" --format=json \
          > "$MO_RUN/proxy/instance.json" 2> "$MO_RUN/logs/vm-reconcile.log";then
          rc=0
        elif grep -qiE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|resource pool exhausted' "$MO_RUN/logs/vm-last.log";then
          rm -f -- "$MO_PROXY_CACHE";mo_log "[$project] $zone 明确库存不足，换区";continue
        elif grep -qiE 'PERMISSION_DENIED|AUTH_PERMISSION_DENIED|QUOTA_EXCEEDED|quota.*exceeded|UREQ_PROJECT_BILLING_NOT_OPEN|UREQ_PROJECT_BILLING_NOT_FOUND|billing.*disabled|billing.*not.*enabled|billing.*must be enabled|Required .* permission|permission.*denied|SERVICE_DISABLED' "$MO_RUN/logs/vm-last.log";then
          rm -f -- "$MO_PROXY_CACHE";mo_log "[$project] 被权限/账单/配额/API 状态明确拒绝，尝试下一个候选项目";break
        else
          : > "$MO_RUN/proxy.uncertain"
          mo_log '创建结果不确定，保留创建记录并停止；不会自动换区重复建机';return 1
        fi
      fi
      mo_log "[$project] VM 已存在，读取公网 IP 和实际网络"
      end=$((SECONDS+30))
      while ! mo_data proxy-fill "$f" "$MO_RUN/proxy/instance.json" 2> "$MO_RUN/logs/vm-info.log";do
        (( SECONDS<end )) || break
        sleep 2
        mo_proxy_fields "$f" || return 1
        mo_gc 30 compute instances describe "$MO_CNAME" --project="$project" --zone="$zone" --format=json \
          > "$MO_RUN/proxy/instance.json" 2>> "$MO_RUN/logs/vm-info.log" || true
      done
      mo_proxy_fields "$f" || return 1
      mo_copy "$f" "$MO_RUN/resources.json" || return 1
      mo_copy "$f" "$MO_PROXY_CACHE" || return 1
      if [[ -z $MO_CHOST || -z $MO_CNETWORK ]];then
        mo_log '本次 VM 没有完整公网 IP/网络信息';mo_show_serial_tail "$f"
        mo_delete_failed_vm "$f" || return 1;continue
      fi
      mo_ensure_firewall "$project" "$MO_CNETWORK" "$MO_CPORT" || mo_log '防火墙配置未确认，继续进行实际连通性检查'
      if mo_wait_proxy "$f" "$PROXY_WAIT_SECONDS";then return 0;fi
      mo_log '首次代理检查失败，修复防火墙；仅允许重置本次创建且身份匹配的 VM'
      mo_ensure_firewall "$project" "$MO_CNETWORK" "$MO_CPORT" || true
      if [[ $PROXY_RESET_ON_FAILURE == 1 ]] && mo_vm_owned "$f";then
        if mo_gc "$GCLOUD_TIMEOUT" compute instances reset "$MO_CNAME" --project="$project" --zone="$MO_CZONE" \
          > "$MO_RUN/logs/vm-reset.log" 2>&1;then
          if mo_wait_proxy "$f" "$PROXY_REPAIR_WAIT_SECONDS";then return 0;fi
        fi
      fi
      mo_show_serial_tail "$f"
      mo_delete_failed_vm "$f" || return 1
    done
  done
  mo_log '候选项目/区域的有限次数尝试已用尽，未得到可用代理'
  return 1
}

mo_proxy_task() {
  local p attempted=0 made=0 deadline=$((SECONDS+PROXY_CANDIDATE_WAIT_SECONDS)) last=$SECONDS
  local -a candidates=() add=()
  local -A seen=()
  mo_log '[代理] 完整后台任务已启动：查账单 → 复用/创建 VM → 部署并验证 SOCKS5'
  if mo_scan_proxy;then
    mo_log '[代理] 已复用并验证现有 SOCKS5'
    return 0
  fi
  if [[ -n ${PROXY_URL:-} ]];then
    mo_log '[代理] 传入的 PROXY_URL 未通过验证，不创建 VM'
    return 1
  fi
  if [[ $REUSE_PROXY == 1 ]] && mo_recheck_old_proxy;then
    mo_log '[代理] 旧 SOCKS5 经宽限/修复后已可用'
    return 0
  fi
  if [[ -f $MO_RUN/proxy.uncertain && $REUSE_PROXY == 1 ]];then
    mo_log '[代理] 旧 VM 状态不确定，为避免重复收费未继续创建；确认不存在后可用 REUSE_PROXY=0 重试'
    return 1
  fi
  while (( SECONDS<deadline ));do
    candidates=()
    if [[ -n ${PROXY_PROJECT:-} ]];then
      candidates=("$PROXY_PROJECT")
    else
      for p in "$MO_RUN/proxy-projects.billed" "$MO_RUN/new-projects.txt" "$MO_RUN/key-projects.txt";do
        if [[ -s $p ]];then mapfile -t add < "$p";candidates+=("${add[@]}");fi
      done
    fi
    made=0
    for p in "${candidates[@]}";do
      [[ $p =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || continue
      [[ -z ${seen[$p]:-} ]] || continue
      (( attempted<PROXY_PROJECT_TRIES )) || break 2
      seen["$p"]=1;attempted=$((attempted+1));made=1
      mo_log "[代理] 尝试项目 $p（第 $attempted/$PROXY_PROJECT_TRIES 个项目）"
      if build_proxy "$p";then
        mo_log "[代理] 项目 $p 的 SOCKS5 已就绪"
        return 0
      fi
      [[ -f $MO_RUN/proxy.uncertain ]] && return 1
    done
    (( attempted<PROXY_PROJECT_TRIES )) || break
    if [[ -f $MO_RUN/project-selection.done ]];then
      (( made==1 )) && continue
      break
    fi
    if (( SECONDS-last>=15 ));then
      mo_log '[代理] 等待并发项目任务提供新的已绑账单项目...'
      last=$SECONDS
    fi
    sleep 1
  done
  mo_log "[代理] 候选项目尝试结束（已尝试 $attempted/$PROXY_PROJECT_TRIES），未得到可用 SOCKS5"
  return 1
}

emit_final() {
  [[ ${MO_FINAL_PRINTED:-0} == 1 ]] && return 0
  MO_FINAL_PRINTED=1
  # 不读取代理文件来重新设置验证标志；最后一次失败不会被旧结果覆盖。
  cat "$MO_RUN/result.txt"
  cat "$MO_RUN/result.txt" >> "$MO_RUN/run.log"
}
on_exit() {
  local rc=$? elapsed=$((SECONDS-${MO_STARTED_SECONDS:-0}))
  trap - EXIT INT TERM HUP
  if (( rc!=0 ));then
    mo_data children-stop "$$" 2>/dev/null || true
    mo_log "任务未完整成功，退出码 $rc；保留已提取 Key 和资源记录"
  fi
  if mo_data result "$MO_RUN" "$rc" "${MO_PROXY_VALID:-0}" final "$elapsed" 2> "$MO_RUN/logs/finalize.log";then
    printf '%s\n' "$rc" > "$MO_RUN/exit.code"
    mo_log "本次耗时 ${elapsed}s；结果: $MO_RUN/result.txt"
    emit_final
  else
    printf '结果汇总失败；原始 Key 文件仍在 %s/keys/\n' "$MO_RUN" >&2
    (( rc!=0 )) || rc=1
    printf '%s\n' "$rc" > "$MO_RUN/exit.code"
  fi
  exit "$rc"
}
mo_run() {
  MO_RUN=$1;export MO_RUN
  MO_STARTED_SECONDS=$SECONDS
  mo_need python3 timeout flock curl gcloud awk sed shuf || return 1
  exec {MO_LOCK_FD}> "$MO_STATE/run.lock" || return 1
  flock -n "$MO_LOCK_FD" || { mo_log '已有 mo 任务运行，使用 --status/--logs 查看';return 2; }
  mkdir -p "$MO_RUN/logs" "$MO_RUN/keys" "$MO_RUN/lookup" "$MO_RUN/billing" "$MO_RUN/billing-cache" "$MO_RUN/proxy/candidates" || return 1
  mo_data context "$MO_RUN/context.json" '' "$NEED_PROJECTS" || return 1
  mo_data pid "$MO_RUN/pid.json" "$$" || return 1
  printf '%s\n' "$MO_RUN" > "$MO_STATE/current.tmp" && mv -f "$MO_STATE/current.tmp" "$MO_STATE/current" || return 1
  MO_PROXY_VALID=0;MO_FINAL_PRINTED=0
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  : > "$MO_RUN/started"
  mo_phase starting "mo $VERSION 启动"
  local account proxy_rc=1
  local MO_PROXY_PID=''
  account=$(mo_gc 40 auth list --filter=status:ACTIVE --format='value(account)' 2> "$MO_RUN/logs/account.log") || return 1
  [[ -n $account && $account != *$'\n'* ]] || { mo_log '请先登录 gcloud 并选择一个活动账号';return 1; }
  export CLOUDSDK_CORE_ACCOUNT="$account"
  MO_DEFAULT_PROJECT=$(mo_gc 20 config get-value project 2> "$MO_RUN/logs/default-project.log") || MO_DEFAULT_PROJECT=''
  [[ $MO_DEFAULT_PROJECT != '(unset)' ]] || MO_DEFAULT_PROJECT=''
  export MO_DEFAULT_PROJECT
  mo_data context "$MO_RUN/context.json" "$account" "$NEED_PROJECTS" || return 1
  mo_log "当前账号: $account"
  MO_PROXY_CACHE="$MO_STATE/cache/proxy-$(mo_data hash "$account").json"
  MO_RUN_TAG="r-$(basename "$MO_RUN" | tr '[:upper:]' '[:lower:]')"
  export MO_PROXY_CACHE MO_RUN_TAG
  mo_make_worker || return 1
  mo_prepare_library & MO_LIB_PID=$!
  if ! mo_gc "$GCLOUD_TIMEOUT" projects list --filter='lifecycleState=ACTIVE' --format=json \
    > "$MO_RUN/projects.json" 2> "$MO_RUN/logs/projects.log";then
    mo_log '无法读取项目列表，未继续建项目或 VM';return 1
  fi
  mo_data projects "$MO_RUN/projects.json" "$MO_RUN" || return 1
  if [[ $PARALLEL_PROXY == 1 ]];then
    mo_phase parallel '启动【完整 SOCKS5】后台任务，同时准备项目并提取 Vertex Key'
    ( mo_proxy_task; proxy_rc=$?; printf '%s\n' "$proxy_rc" > "$MO_RUN/proxy-task.exit"; exit "$proxy_rc" ) &
    MO_PROXY_PID=$!
  fi
  mo_phase projects '阶段 1：并发账单查询、旧 AQ 优先、仅补足项目槽位'
  if ! mo_select_projects;then
    : > "$MO_RUN/project-selection.failed"
    return 1
  fi
  : > "$MO_RUN/project-selection.done"
  mo_phase keys '阶段 2：复用已有 AQ，其他项目并发执行原 API/IAM/SA/AQ 流程'
  mo_extract_keys || return 2
  if [[ $PARALLEL_PROXY == 0 ]];then
    mo_phase proxy '阶段 3：启动完整 SOCKS5 任务（PARALLEL_PROXY=0 顺序模式）'
    ( mo_proxy_task; proxy_rc=$?; printf '%s\n' "$proxy_rc" > "$MO_RUN/proxy-task.exit"; exit "$proxy_rc" ) &
    MO_PROXY_PID=$!
  else
    mo_phase proxy '阶段 3：Key 已足量，等待后台 SOCKS5 任务收尾'
  fi
  wait "$MO_PROXY_PID";proxy_rc=$?
  [[ -s $MO_RUN/proxy-task.exit ]] && read -r proxy_rc < "$MO_RUN/proxy-task.exit"
  if (( proxy_rc!=0 ));then mo_log "后台 SOCKS5 任务失败，退出码 $proxy_rc";return 1;fi
  # 必须保留最后一次真实验证；失败时绝不从旧结果文件“恢复成功”。
  if [[ -s $MO_RUN/proxy.json ]] && mo_proxy_test "$MO_RUN/proxy.json";then MO_PROXY_VALID=1
  else MO_PROXY_VALID=0;mo_log '最后一次代理验证失败；结尾将输出 SOCKS5_FAILED，Key 仍保留';return 1;fi
  mo_phase completed '处理完成；即将输出代理 URL 和完整 AQ Key'
  return 0
}
mo_main() {
  local mode=${1:-run} selected=${2:-} newrun source_file child n
  [[ $mode == --help || $mode == -h ]] && { mo_usage;return 0; }
  mo_need python3 || return 1
  MO_STATE=${MO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/mo}
  MO_STATE=$(python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$MO_STATE") || return 1
  export MO_STATE
  case "$mode" in
    --status|--logs|--results|--json|--stop)
      if [[ -z $selected && -f $MO_STATE/current ]];then read -r selected < "$MO_STATE/current";fi
      [[ -n $selected && -d $selected ]] || { printf '没有任务结果。\n';return 1; }
      case "$mode" in
        --status) mo_data status "$selected" ;;
        --logs) tail -n 80 -F "$selected/run.log" ;;
        --results) cat "$selected/result.txt" ;;
        --json) cat "$selected/result.json" ;;
        --stop)
          if mo_data stop "$selected/pid.json";then
            printf '已请求停止本地任务，正在保存结果。\n'
            for n in 1 2 3 4 5 6 7 8;do mo_data alive "$selected/pid.json" || break;sleep 1;done
            mo_data status "$selected"
          else printf '此任务已不在运行。\n';fi ;;
      esac
      return $? ;;
    run|--background|--_run) : ;;
    *) mo_usage >&2;return 2 ;;
  esac
  export TESTSH_URL NEED_PROJECTS REUSE_PROXY REUSE_KEYS PARALLEL_PROXY BILLING_SCAN_JOBS KEY_SCAN_JOBS KEY_JOBS
  export PROXY_SCAN_JOBS PROXY_SCAN_LIMIT PROXY_PORT PROXY_ZONE_TRIES PROXY_PROJECT_TRIES PROXY_WAIT_SECONDS PROXY_REUSE_GRACE_SECONDS
  export PROXY_REPAIR_WAIT_SECONDS PROXY_ZONES_PER_PROJECT PROXY_SHUFFLE_ZONES PROXY_CHECK_TIMEOUT PROXY_POLL_SECONDS
  export PROXY_RESET_ON_FAILURE DELETE_FAILED_VM PROXY_TEST_URL PROXY_TEST_URL_FALLBACK PROXY_SOURCE_RANGES
  export GCLOUD_TIMEOUT BILLING_TIMEOUT KEY_SCAN_TIMEOUT KEY_TIMEOUT CREATE_TIMEOUT VM_CREATE_TIMEOUT PROXY_CANDIDATE_WAIT_SECONDS TESTSH_CACHE_TTL
  mo_data validate || return 1
  # gcloud metadata-from-file 用逗号分隔字段，避免含分隔符的自定义工作路径产生错误解析。
  [[ $MO_STATE != *','* && $MO_STATE != *$'\n'* ]] || { printf 'MO_STATE_DIR 不能包含逗号或换行。\n';return 1; }
  mkdir -p "$MO_STATE/runs" "$MO_STATE/cache" || return 1
  chmod 700 "$MO_STATE" "$MO_STATE/runs" "$MO_STATE/cache" || return 1
  if [[ $mode == --_run ]];then [[ -d $selected ]] || return 1;mo_run "$selected";return $?;fi
  if [[ $mode == --background ]];then
    mo_need bash nohup setsid || return 1
    source_file=${BASH_SOURCE[0]}
    [[ -f $source_file ]] || { printf '请先保存为 mo.sh，再执行 bash mo.sh --background。\n';return 1; }
  fi
  newrun=$(mktemp -d "$MO_STATE/runs/$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 1
  if [[ $mode == --background ]];then
    cp -- "$source_file" "$newrun/mo.sh" || return 1
    nohup setsid bash "$newrun/mo.sh" --_run "$newrun" > "$newrun/launcher.log" 2>&1 < /dev/null & child=$!
    for ((n=0;n<50;n++));do
      if [[ -f $newrun/started ]];then
        if [[ -f $newrun/exit.code && $(cat "$newrun/exit.code") != 0 ]];then cat "$newrun/launcher.log";return 1;fi
        printf '后台任务已启动。\n目录: %s\n查看日志: bash mo.sh --logs\n完成后查看代理和 Key: bash mo.sh --results\n' "$newrun";return 0
      fi
      if ! kill -0 "$child" 2>/dev/null;then wait "$child";cat "$newrun/launcher.log";return 1;fi
      sleep .1
    done
    printf '启动尚未确认，请查看 %s/launcher.log\n' "$newrun";return 1
  fi
  mo_run "$newrun"
}
mo_main "$@"
