"""Owned finite process-restart fixture; SQL lock only, no product test hooks."""
import hashlib, importlib.util, json, os, pathlib, queue, subprocess, threading, time
spec=importlib.util.spec_from_file_location('quality_http', pathlib.Path(__file__).with_name('quality-http.py'))
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
psql=pathlib.Path(os.environ['S26_PSQL'])
assert hashlib.sha256(psql.read_bytes()).hexdigest().upper()==os.environ['S26_PSQL_SHA']
assert os.environ['S26_RESTART_DB']=='pi_s25_quality_test_s26_browser02'
args=[str(psql),'-X','-q','-t','-A','-w','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','55449','-U','pi_s21_admin','-d',os.environ['S26_RESTART_DB']]
env=dict(os.environ,PGCONNECT_TIMEOUT='5',PGOPTIONS='-c statement_timeout=60000 -c lock_timeout=5000 -c idle_in_transaction_session_timeout=60000')
p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1,env=env,creationflags=subprocess.CREATE_NO_WINDOW)
q=queue.Queue(); lines=[]
def reader():
    total=0
    for line in p.stdout:
        total+=len(line)
        if total>65536: p.kill();q.put(RuntimeError('psql output cap'));return
        lines.append(line);q.put(line.strip())
thread=threading.Thread(target=reader,daemon=True);thread.start()
def sql(value): p.stdin.write(value+'\n');p.stdin.flush()
def until(marker,seconds=10):
    end=time.monotonic()+seconds; result=[]
    while time.monotonic()<end:
        value=q.get(timeout=max(.01,end-time.monotonic()))
        if isinstance(value,Exception):raise value
        if value==marker:return result
        if value:result.append(value)
    raise AssertionError('psql marker timeout')
try:
    sql("SELECT 'connected';");until('connected')
    jar=h.http.cookiejar.LWPCookieJar(str(h.STATE.with_suffix('.cookies')));jar.load(ignore_discard=True,ignore_expires=True)
    client=h.Client(jar); state=json.loads(h.STATE.read_text())
    stable=client.request('GET','/quality/jobs/'+state['stable_id']+'/report')[2]
    assert h.digest(stable)==state['stable_sha256']
    captured=None
    for attempt in range(3):
        form=h.new_form(client); accepted=h.submit(client,form); job=accepted['snapshot']['id']
        sql("BEGIN; LOCK TABLE public.pi_projects IN SHARE MODE; SELECT document->'quality_jobs'->'"+job+"' FROM public.pi_projects WHERE document->'quality_jobs' ? '"+job+"'; SELECT 'locked';")
        rows=until('locked'); assert len(rows)==1, rows
        meta=json.loads(rows[0])
        if meta['snapshot']['state'] not in ('completed','failed','cancelled'):
            captured=dict(job=job,meta=meta,form=form,stable_id=state['stable_id'],stable_sha256=state['stable_sha256'],psql_pid=p.pid,attempt=attempt+1)
            h.write('ready.json',captured);break
        sql("ROLLBACK; SELECT 'released';");until('released')
        client.request('POST','/quality/jobs/'+job+'/delete',{})
    assert captured, 'no nonterminal task captured in three bounded attempts'
    deadline=time.monotonic()+45
    while not (h.OUT/'app-killed.json').exists():
        assert time.monotonic()<deadline,'app kill signal timeout';time.sleep(.05)
    sql("ROLLBACK; SELECT 'released';");until('released')
    sql('\\q'); p.wait(timeout=5);thread.join(timeout=2)
    assert p.returncode==0
    h.write('lock-proof.json',dict(status='NONTERMINAL_COMMITTED_TASK_CAPTURED_THEN_APP_KILLED',job=captured['job'],psql_exit=p.returncode,output_sha256=h.digest(''.join(lines).encode())))
finally:
    if p.poll() is None:
        try:sql('ROLLBACK;\n\\q');p.wait(timeout=5)
        except Exception:p.kill();p.wait(timeout=5)
    (h.OUT/'psql-output.txt').write_text(''.join(lines),encoding='utf-8')
