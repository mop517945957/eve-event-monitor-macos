"""Build the offline map from CCP's official JSONL SDE ZIP (no runtime API)."""
import json, sys, zipfile, hashlib
from pathlib import Path
archive = Path(sys.argv[1])
with zipfile.ZipFile(archive) as z:
    meta = json.loads(z.read('_sde.jsonl').splitlines()[0])
    systems = {s['_key']: {'id': s['_key'], 'name': s['name']['en'],
               'aliases': sorted(set(s['name'].values())), 'neighbors': []}
               for s in map(json.loads, z.read('mapSolarSystems.jsonl').splitlines())}
    for gate in map(json.loads, z.read('mapStargates.jsonl').splitlines()):
        a, b = gate['solarSystemID'], gate['destination']['solarSystemID']
        assert a in systems and b in systems
        systems[a]['neighbors'].append(b)
    for s in systems.values():
        s['neighbors'] = sorted(set(s['neighbors']))
        for n in s['neighbors']: assert s['id'] in systems[n]['neighbors']
    result = {'build': str(meta['buildNumber']), 'date': meta['releaseDate'],
              'source': 'https://developers.eveonline.com/static-data/',
              'archiveSHA256': hashlib.sha256(archive.read_bytes()).hexdigest(),
              'systems': sorted(systems.values(), key=lambda s:s['id'])}
    out = Path('ScreenAlarm/Resources/IntelMap.json')
    out.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')))
    print(len(systems), 'systems;', sum(len(s['neighbors']) for s in systems.values())//2, 'gate links;', out.stat().st_size, 'bytes; build',result['build'])
