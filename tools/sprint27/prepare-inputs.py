"""Expand only the prospectively frozen synthetic corpus into bounded local inputs."""
import argparse,hashlib,json,re,xml.etree.ElementTree as ET
from pathlib import Path

def sha(raw):return hashlib.sha256(raw).hexdigest()
def unique(pairs):
    value={}
    for key,item in pairs:
        if key in value:raise ValueError('duplicate JSON key')
        value[key]=item
    return value

def validate(rows):
    assert isinstance(rows,list) and len(rows)<=32
    traces=events=0; variants=set(); labels=set()
    for row in rows:
        assert isinstance(row,dict) and set(row)=={'trace','count'}
        sequence,count=row['trace'],row['count']
        assert isinstance(sequence,list) and len(sequence)<=64 and type(count) is int and 1<=count<=64
        assert all(isinstance(label,str) and 0<len(label.encode())<=200 for label in sequence)
        traces+=count;events+=count*len(sequence);variants.add(tuple(sequence));labels.update(sequence)
    assert traces<=64 and events<=500 and len(variants)<=32 and len(labels)<=6
    return traces,events

def main():
    p=argparse.ArgumentParser();p.add_argument('corpus',type=Path);p.add_argument('output',type=Path);args=p.parse_args()
    assert args.corpus.stat().st_size<=1024*1024
    raw=args.corpus.read_bytes();corpus=json.loads(raw.decode('utf-8-sig'),object_pairs_hook=unique)
    assert corpus['schema_version']==1 and set(corpus)=={'schema_version','purpose','cases'}
    assert args.output.is_dir() and not any(args.output.iterdir())
    manifest={'schema_version':1,'corpus_sha256':sha(raw),'training_only_xes':True,'cases':[]}
    seen=set()
    for case in corpus['cases']:
        assert set(case)<={'id','train','held_out','diagnostic_only','expected'} and {'id','train','held_out'}<=set(case)
        name=case['id'];assert re.fullmatch('[a-z][a-z0-9_]{0,63}',name) and name not in seen;seen.add(name)
        counts={group:validate(case.get(group,[])) for group in ('train','held_out','diagnostic_only')}
        payload={key:case[key] for key in ('id','train','held_out')}
        payload['diagnostic_only']=case.get('diagnostic_only',[])
        data=(json.dumps(payload,sort_keys=True,separators=(',',':'))+'\n').encode()
        target=args.output/(name+'.json');target.write_bytes(data)
        log=ET.Element('log',{'xmlns':'http://www.xes-standard.org/','xes.version':'1.0'})
        ET.SubElement(log,'string',{'key':'concept:name','value':'prospective-'+name})
        index=0
        for variant in case['train']:
            for _ in range(variant['count']):
                trace=ET.SubElement(log,'trace');ET.SubElement(trace,'string',{'key':'concept:name','value':f'train-{index}'});index+=1
                for label in variant['trace']:
                    event=ET.SubElement(trace,'event');ET.SubElement(event,'string',{'key':'concept:name','value':label})
        xes=ET.tostring(log,encoding='utf-8',xml_declaration=True)
        assert len(xes)<=1024*1024
        (args.output/(name+'.xes')).write_bytes(xes)
        manifest['cases'].append({'id':name,'input_file':target.name,'input_sha256':sha(data),'xes_file':name+'.xes','xes_sha256':sha(xes),'counts':counts})
    assert len(seen)==7
    (args.output/'manifest.json').write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'status':'FROZEN_TRAIN_CONTROL_INPUTS_PREPARED','cases':len(seen),'corpus_sha256':sha(raw)}))
if __name__=='__main__':main()
