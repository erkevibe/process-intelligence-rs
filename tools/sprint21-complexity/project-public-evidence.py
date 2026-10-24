"""Stage-local typed URI additions; all bounded base policy remains pinned."""
import hashlib as _hashlib
import importlib.util as _importlib
from pathlib import Path as _Path
import re as _re

_base = _Path(__file__).absolute().parents[1] / 'sprint21/project-public-evidence.py'
_BASE_SHA = '29576670CB09D054F366B1DEE981CC56305B6B1A0C8AD1BC48600114D9B8109F'
if _hashlib.sha256(_base.read_bytes()).hexdigest().upper() != _BASE_SHA:
    raise ValueError('unchanged_base_policy_pin')
_spec = _importlib.spec_from_file_location('unchanged_s21_base_policy', _base)
_p = _importlib.module_from_spec(_spec)
_spec.loader.exec_module(_p)
_original_uri = _p.relative_uri

def _stage_uri(value, workspace, profile):
    if isinstance(value, str) and _re.fullmatch(r'/(?:setup|project-list/json|projects(?:/project-[0-9a-f]{32}/open)?)', value):
        _p.require('\\' not in value and '?' not in value and '#' not in value and '\r' not in value and '\n' not in value, 'typed_stage_route')
        return value
    return _original_uri(value, workspace, profile)

_p.relative_uri = _stage_uri
for _name in dir(_p):
    if not _name.startswith('__'):
        globals()[_name] = getattr(_p, _name)
if __name__ == '__main__':
    _p.main()