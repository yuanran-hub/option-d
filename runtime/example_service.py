"""Optional background enrichment. Never called on the instant lookup path."""
import json,re,sqlite3,ssl,time,urllib.request,urllib.parse
from pathlib import Path
_last_request=0

def fetch_example(word, cache):
    global _last_request
    # At most one request every two seconds. Timeout/failure leaves a pending label.
    time.sleep(max(0,2-(time.monotonic()-_last_request)))
    _last_request=time.monotonic()
    url='https://api.dictionaryapi.dev/api/v2/entries/en/'+urllib.parse.quote(word,safe='')
    context=ssl.create_default_context()
    try:
        with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'IELTSLookup/1.3'}),timeout=5,context=context) as response:
            data=json.load(response)
        for entry in data if isinstance(data,list) else []:
            for meaning in entry.get('meanings',[]):
                for definition in meaning.get('definitions',[]):
                    text=definition.get('example','').strip()
                    if 5<=len(text.split())<=25 and re.search(r'\b'+re.escape(word)+r'\b',text,re.I):
                        payload={'text':text,'source':url,'kind':'dictionary','sense':definition.get('definition',''),'license':entry.get('license',{}),'source_urls':entry.get('sourceUrls',[])}
                        with sqlite3.connect(cache,timeout=10) as db:
                            db.execute('CREATE TABLE IF NOT EXISTS examples(lemma TEXT PRIMARY KEY,payload TEXT NOT NULL)')
                            db.execute('INSERT OR IGNORE INTO examples VALUES (?,?)',(word,json.dumps(payload,ensure_ascii=False)))
                        return True
    except Exception:
        return False
    return False
