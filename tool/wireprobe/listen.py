import socket, sys, time, json
port=int(sys.argv[1]); label=sys.argv[2]; out=sys.argv[3]
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',port)); s.listen(1)
print(f"[{label}] listening {port}",flush=True)
c,_=s.accept(); c.settimeout(6)
reads,buf,t0=[],b'',None
try:
    while True:
        d=c.recv(65535)
        if not d: break
        now=time.time()
        if t0 is None: t0=now
        reads.append({'bytes':len(d),'ms':round((now-t0)*1000,1)})
        buf+=d
        if len(buf)>60000: break
except Exception: pass
c.close(); s.close()
recs,i=[],0
while i+5<=len(buf):
    typ=buf[i]; ln=(buf[i+3]<<8)|buf[i+4]
    if typ not in (20,21,22,23): break
    recs.append({'type':typ,'len':ln,'payload':buf[i+5:i+5+ln].hex()})
    i+=5+ln
json.dump({'label':label,'total':len(buf),'reads':reads,'records':recs},open(out,'w'))
print('saved',out,flush=True)
