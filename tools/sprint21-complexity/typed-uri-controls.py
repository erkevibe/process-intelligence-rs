"""Finite positive and negative typed-URI privacy controls; no HTTP or product."""
import importlib.util
import json
from pathlib import Path

spec=importlib.util.spec_from_file_location('typed_stage_policy',Path(__file__).with_name('project-public-evidence.py'))
p=importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
project='0123456789abcdef0123456789abcdef'
allowed=['/setup','/project-list/json','/projects','/projects/project-'+project+'/open','/conversions/jobs/job-2/payload','/health']
denied=['/etc/passwd','C:/Windows/not-a-route','file:///C:/Windows/not-a-route','//remote/setup','/setup?q=x','/projects/project-'+project+'/open?q=x','/projects/project-'+project.upper()+'/open','/projects/project-123/open','/projects/project-'+project+'/delete','/projects/project-'+project+'/open/extra','/projects/../setup','/projects/project-%2e%2e/open','/setup\n']
for route in allowed:
    assert p.relative_uri(route,Path.cwd(),Path.home()) == route
for route in denied:
    try:
        p.relative_uri(route,Path.cwd(),Path.home())
    except ValueError:
        continue
    raise AssertionError('unapproved route accepted')
print(json.dumps({'status':'TYPED_STAGE_URI_POSITIVE_AND_NEGATIVE_CONTROLS_PASS','accepted':len(allowed),'rejected':len(denied),'network_or_product_executed':False}))