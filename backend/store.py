"""SQLite persistence and strictly scoped local vector retrieval for 知会."""
from contextlib import contextmanager
from datetime import datetime
import hashlib
import json
import math
from pathlib import Path
import re
import sqlite3
import threading
import time
from urllib.parse import unquote, urlsplit
import uuid

from .documents import chunks, extract_text, MAX_FILE_BYTES

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FORESIGHT_DB = Path.home()/'Library/Application Support/com.google.AIEdgeForesight/database.sqlite'
DEFAULT_ATTACHMENTS_DB = Path.home()/'Library/Application Support/foresight-zh/meeting-files.sqlite'


def now():
    return time.time()


def check_cancel(event):
    if event is not None and event.is_set():
        raise InterruptedError('操作已取消。')


def title_value(title):
    if not isinstance(title, str):
        raise ValueError('会议名称必须是文字。')
    title = title.strip()
    if not 1 <= len(title) <= 100 or any(ord(x) < 32 or ord(x) == 127 for x in title):
        raise ValueError('会议名称需为 1–100 个字，不能包含换行或控制字符。')
    return title


def vector_value(vector):
    if not isinstance(vector, (list, tuple)) or not vector:
        raise ValueError('本地 embedding 返回了空向量。')
    values = [float(x) for x in vector]
    if any(not math.isfinite(x) for x in values) or not any(values):
        raise ValueError('本地 embedding 返回了无效向量。')
    return values


def cosine(a, b):
    if len(a) != len(b):
        raise ValueError('embedding 模型维度发生变化，请重新建立索引。')
    return sum(x*y for x, y in zip(a, b)) / (math.sqrt(sum(x*x for x in a))*math.sqrt(sum(x*x for x in b)))


class Store:
    def __init__(self, data_dir, models):
        self.data_dir = Path(data_dir).expanduser().resolve()
        self.data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.data_dir.chmod(0o700)
        self.db_path = self.data_dir/'database.sqlite'
        self.models = models
        self.lock = threading.RLock()
        with self.db() as conn:
            conn.executescript('''
              PRAGMA journal_mode=WAL;
              CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY,title TEXT NOT NULL,note TEXT NOT NULL DEFAULT '',
                summary TEXT NOT NULL DEFAULT '',created_at REAL NOT NULL,updated_at REAL NOT NULL,
                deleted_at REAL,origin_event_id TEXT,origin_timestamp INTEGER,
                content_version INTEGER NOT NULL DEFAULT 0,
                UNIQUE(origin_event_id,origin_timestamp));
              CREATE TABLE IF NOT EXISTS segments (
                id TEXT PRIMARY KEY,meeting_id TEXT NOT NULL REFERENCES meetings(id),
                text TEXT NOT NULL,start_seconds REAL NOT NULL DEFAULT 0,end_seconds REAL NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,deleted_at REAL,audio_path TEXT,request_id TEXT,
                UNIQUE(meeting_id,request_id));
              CREATE TABLE IF NOT EXISTS sources (
                id TEXT PRIMARY KEY,meeting_id TEXT REFERENCES meetings(id),
                segment_id TEXT REFERENCES segments(id),kind TEXT NOT NULL,
                logical_key TEXT UNIQUE,filename TEXT NOT NULL,path TEXT NOT NULL DEFAULT '',
                original_path TEXT NOT NULL DEFAULT '',text TEXT NOT NULL DEFAULT '',
                extraction_note TEXT NOT NULL DEFAULT '',status TEXT NOT NULL DEFAULT 'indexing',
                created_at REAL NOT NULL,deleted_at REAL,file_hash TEXT,
                revision INTEGER NOT NULL DEFAULT 0);
              CREATE UNIQUE INDEX IF NOT EXISTS unique_file_scope ON sources(COALESCE(meeting_id,''),file_hash) WHERE kind='file' AND file_hash IS NOT NULL;
              CREATE TABLE IF NOT EXISTS chunks (
                id TEXT PRIMARY KEY,source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,text TEXT NOT NULL,embedding TEXT NOT NULL);
              CREATE INDEX IF NOT EXISTS chunks_source ON chunks(source_id);
              CREATE INDEX IF NOT EXISTS sources_meeting ON sources(meeting_id);
              CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY,kind TEXT NOT NULL,request_key TEXT,
                state TEXT NOT NULL,progress REAL NOT NULL DEFAULT 0,message TEXT NOT NULL DEFAULT '',
                partial TEXT NOT NULL DEFAULT '',result TEXT,error TEXT,
                created_at REAL NOT NULL,updated_at REAL NOT NULL);
              CREATE INDEX IF NOT EXISTS jobs_request ON jobs(request_key);
            ''')
        self.db_path.chmod(0o600)

    @contextmanager
    def db(self):
        conn = sqlite3.connect(self.db_path, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute('PRAGMA foreign_keys=ON')
        try:
            yield conn
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
        finally:
            conn.close()

    @staticmethod
    def _meeting(conn, meeting_id, live=False):
        row = conn.execute('SELECT * FROM meetings WHERE id=?', (meeting_id,)).fetchone()
        if not row:
            raise KeyError('会议不存在。')
        if live and row['deleted_at'] is not None:
            raise ValueError('会议已移入回收站，请先恢复。')
        return row

    @staticmethod
    def _meeting_public(conn, row):
        result = {k: row[k] for k in ('id','title','created_at','updated_at','deleted_at','summary')}
        result['segment_count'] = conn.execute('SELECT COUNT(*) FROM segments WHERE meeting_id=? AND deleted_at IS NULL', (row['id'],)).fetchone()[0]
        result['attachment_count'] = conn.execute("SELECT COUNT(*) FROM sources WHERE meeting_id=? AND kind='file' AND deleted_at IS NULL", (row['id'],)).fetchone()[0]
        return result

    @staticmethod
    def _segment_public(row):
        return {k: row[k] for k in ('id','text','start_seconds','end_seconds','created_at','deleted_at')}

    @staticmethod
    def _source_public(conn, row):
        result = {k: row[k] for k in ('id','meeting_id','filename','path','text','extraction_note','status','created_at')}
        result['chunk_count'] = conn.execute('SELECT COUNT(*) FROM chunks WHERE source_id=?', (row['id'],)).fetchone()[0]
        result['deleted_at'] = row['deleted_at']
        return result

    def create_meeting(self, title=None):
        title = title_value(title) if title is not None else datetime.now().strftime('会议 %Y-%m-%d %H:%M')
        meeting_id, stamp = str(uuid.uuid4()), now()
        with self.db() as conn:
            conn.execute('INSERT INTO meetings(id,title,created_at,updated_at) VALUES(?,?,?,?)', (meeting_id,title,stamp,stamp))
        return self.get_meeting(meeting_id, detail=False)

    def list_meetings(self, trash=False):
        with self.db() as conn:
            rows = conn.execute('SELECT * FROM meetings WHERE deleted_at IS '+('NOT NULL' if trash else 'NULL')+' ORDER BY created_at DESC').fetchall()
            return [self._meeting_public(conn, row) for row in rows]

    def get_meeting(self, meeting_id, detail=True):
        with self.db() as conn:
            row = self._meeting(conn, meeting_id)
            result = self._meeting_public(conn, row)
            if detail:
                result['note'] = row['note']
                result['segments'] = [self._segment_public(s) for s in conn.execute('SELECT * FROM segments WHERE meeting_id=? AND deleted_at IS NULL ORDER BY start_seconds,created_at,id', (meeting_id,))]
                result['attachments'] = [self._source_public(conn,s) for s in conn.execute("SELECT * FROM sources WHERE meeting_id=? AND kind='file' AND deleted_at IS NULL ORDER BY created_at", (meeting_id,))]
            return result

    @staticmethod
    def _invalidate_summary(conn, meeting_id):
        conn.execute("UPDATE meetings SET summary='',content_version=content_version+1,updated_at=? WHERE id=?", (now(),meeting_id))
        conn.execute("DELETE FROM chunks WHERE source_id IN (SELECT id FROM sources WHERE meeting_id=? AND kind='summary')", (meeting_id,))
        conn.execute("UPDATE sources SET text='',status='unreadable',revision=revision+1 WHERE meeting_id=? AND kind='summary'", (meeting_id,))

    def _text_source(self, conn, meeting_id, kind, text, *, segment_id=None, filename=None):
        key = f'{kind}:{segment_id or meeting_id}'
        source = conn.execute('SELECT id FROM sources WHERE logical_key=?', (key,)).fetchone()
        source_id = source['id'] if source else str(uuid.uuid4())
        name = filename or {'note':'会议笔记','summary':'会议摘要','transcript':'会议转写'}[kind]
        conn.execute('''INSERT INTO sources(id,meeting_id,segment_id,kind,logical_key,filename,text,created_at)
                        VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(logical_key) DO UPDATE SET
                        text=excluded.text,filename=excluded.filename,status='indexing',revision=sources.revision+1''',
                     (source_id,meeting_id,segment_id,kind,key,name,text,now()))
        conn.execute('DELETE FROM chunks WHERE source_id=?', (source_id,))
        return source_id

    def patch_meeting(self, meeting_id, changes):
        if not isinstance(changes, dict) or not any(k in changes for k in ('title','note')):
            raise ValueError('请提供会议名称或笔记。')
        values = {}
        if 'title' in changes:
            values['title'] = title_value(changes['title'])
        if 'note' in changes:
            if not isinstance(changes['note'], str) or len(changes['note']) > 500_000:
                raise ValueError('会议笔记需为文字，最多 50 万字。')
            values['note'] = changes['note']
        source_id = None
        with self.lock, self.db() as conn:
            self._meeting(conn, meeting_id, live=True)
            conn.execute('UPDATE meetings SET '+','.join(k+'=?' for k in values)+',updated_at=? WHERE id=?', (*values.values(),now(),meeting_id))
            if 'title' in values:
                conn.execute('UPDATE meetings SET content_version=content_version+1 WHERE id=?',(meeting_id,))
            if 'note' in values:
                self._invalidate_summary(conn, meeting_id)
                source_id = self._text_source(conn, meeting_id, 'note', values['note'])
        if source_id:
            self.index_source(source_id)
        return self.get_meeting(meeting_id, detail=False)

    def meeting_trash(self, meeting_id, trash):
        with self.lock, self.db() as conn:
            self._meeting(conn, meeting_id)
            conn.execute('UPDATE meetings SET deleted_at=?,updated_at=?,content_version=content_version+1 WHERE id=?', (now() if trash else None,now(),meeting_id))

    def add_segment(self, meeting_id, text, start_seconds=0, end_seconds=None, *, audio_path=None, request_id=None, created_at=None,cancel_event=None):
        if not isinstance(text,str) or not text.strip() or len(text) > 500_000:
            raise ValueError('转写文字不能为空，最多 50 万字。')
        if isinstance(start_seconds,bool) or isinstance(end_seconds,bool):
            raise ValueError('转写时间必须是秒数。')
        try:
            start_seconds = float(start_seconds)
            end_seconds = start_seconds if end_seconds is None else float(end_seconds)
        except (TypeError,ValueError):
            raise ValueError('转写时间必须是秒数。') from None
        if not math.isfinite(start_seconds) or not math.isfinite(end_seconds) or start_seconds < 0 or end_seconds < start_seconds:
            raise ValueError('转写时间范围无效。')
        segment_id = str(uuid.uuid4())
        with self.lock, self.db() as conn:
            check_cancel(cancel_event)
            self._meeting(conn, meeting_id, live=True)
            if request_id:
                previous = conn.execute('SELECT * FROM segments WHERE meeting_id=? AND request_id=?',(meeting_id,request_id)).fetchone()
                if previous:
                    return self._segment_public(previous)
            self._invalidate_summary(conn, meeting_id)
            conn.execute('INSERT INTO segments(id,meeting_id,text,start_seconds,end_seconds,created_at,audio_path,request_id) VALUES(?,?,?,?,?,?,?,?)', (segment_id,meeting_id,text.strip(),start_seconds,end_seconds,created_at or now(),audio_path,request_id))
            source_id = self._text_source(conn, meeting_id, 'transcript', text.strip(), segment_id=segment_id)
        self.index_source(source_id)
        with self.db() as conn:
            return self._segment_public(conn.execute('SELECT * FROM segments WHERE id=?', (segment_id,)).fetchone())

    def list_segments(self, meeting_id, trash=False):
        with self.db() as conn:
            self._meeting(conn, meeting_id)
            rows = conn.execute('SELECT * FROM segments WHERE meeting_id=? AND deleted_at IS '+('NOT NULL' if trash else 'NULL')+' ORDER BY start_seconds,created_at', (meeting_id,)).fetchall()
            return [self._segment_public(row) for row in rows]

    def edit_segment(self, meeting_id, segment_id, text):
        if not isinstance(text,str) or not text.strip() or len(text)>500_000:
            raise ValueError('转写文字不能为空，最多 50 万字。')
        with self.lock,self.db() as conn:
            self._meeting(conn,meeting_id,live=True)
            row = conn.execute('SELECT * FROM segments WHERE id=? AND meeting_id=?',(segment_id,meeting_id)).fetchone()
            if not row:
                raise KeyError('该会议中的转写片段不存在。')
            if row['deleted_at'] is not None:
                raise ValueError('片段已移入回收站，请先恢复。')
            conn.execute('UPDATE segments SET text=? WHERE id=? AND meeting_id=?',(text.strip(),segment_id,meeting_id))
            self._invalidate_summary(conn,meeting_id)
            source_id = self._text_source(conn,meeting_id,'transcript',text.strip(),segment_id=segment_id)
        self.index_source(source_id)
        with self.db() as conn:
            return self._segment_public(conn.execute('SELECT * FROM segments WHERE id=?',(segment_id,)).fetchone())

    def segment_trash(self, meeting_id, segment_id, trash):
        source_id = None
        with self.lock, self.db() as conn:
            self._meeting(conn, meeting_id, live=True)
            row = conn.execute('SELECT * FROM segments WHERE id=? AND meeting_id=?',(segment_id,meeting_id)).fetchone()
            if not row:
                raise KeyError('该会议中的转写片段不存在。')
            self._invalidate_summary(conn, meeting_id)
            conn.execute('UPDATE segments SET deleted_at=? WHERE id=? AND meeting_id=?', (now() if trash else None,segment_id,meeting_id))
            source=conn.execute('SELECT id FROM sources WHERE segment_id=?',(segment_id,)).fetchone()
            if source:
                source_id=source['id']
                conn.execute('DELETE FROM chunks WHERE source_id=?',(source_id,))
                conn.execute('UPDATE sources SET revision=revision+1,status=? WHERE id=?',('unreadable' if trash else 'indexing',source_id))
        if source_id and not trash:
            self.index_source(source_id)

    def index_source(self, source_id, cancel_event=None):
        check_cancel(cancel_event)
        with self.lock,self.db() as conn:
            row = conn.execute('SELECT * FROM sources WHERE id=?',(source_id,)).fetchone()
            if not row:
                raise KeyError('资料不存在。')
            revision,text = row['revision'],row['text']
            conn.execute('DELETE FROM chunks WHERE source_id=?',(source_id,))
            conn.execute("UPDATE sources SET status=? WHERE id=?", ('indexing' if text.strip() else 'unreadable',source_id))
        if not text.strip():
            return False
        try:
            parts = chunks(text)
            vectors = []
            for offset in range(0,len(parts),32):
                check_cancel(cancel_event)
                batch = self.models.embed(parts[offset:offset+32])
                if len(batch) != len(parts[offset:offset+32]):
                    raise ValueError('embedding 返回的片段数量不一致。')
                vectors.extend(vector_value(v) for v in batch)
            check_cancel(cancel_event)
            if any(len(v) != len(vectors[0]) for v in vectors):
                raise ValueError('embedding 返回的向量维度不一致。')
            with self.lock, self.db() as conn:
                current = conn.execute('SELECT revision FROM sources WHERE id=?',(source_id,)).fetchone()
                if not current or current['revision'] != revision:
                    return False  # A newer edit owns the current index.
                conn.execute('DELETE FROM chunks WHERE source_id=?',(source_id,))
                conn.executemany('INSERT INTO chunks VALUES(?,?,?,?,?)', [(str(uuid.uuid4()),source_id,i,part,json.dumps(vector,separators=(',',':'))) for i,(part,vector) in enumerate(zip(parts,vectors))])
                conn.execute("UPDATE sources SET status='indexed' WHERE id=?",(source_id,))
            return True
        except BaseException as exc:
            with self.db() as conn:
                conn.execute("UPDATE sources SET status='error',extraction_note=? WHERE id=? AND revision=?", ('文字已保存，索引失败：'+str(exc),source_id,revision))
            if isinstance(exc,(KeyboardInterrupt,SystemExit,InterruptedError)):
                raise
            return False

    def reindex_pending(self, cancel_event=None):
        with self.db() as conn:
            ids = [r['id'] for r in conn.execute("""SELECT s.id FROM sources s LEFT JOIN meetings m ON m.id=s.meeting_id LEFT JOIN segments g ON g.id=s.segment_id
                                                     WHERE s.text<>'' AND s.status<>'indexed' AND s.deleted_at IS NULL
                                                     AND (s.meeting_id IS NULL OR m.deleted_at IS NULL) AND (s.segment_id IS NULL OR g.deleted_at IS NULL)""")]
        success = 0
        for source_id in ids:
            check_cancel(cancel_event)
            success += int(self.index_source(source_id,cancel_event))
        return {'indexed':success,'failed':len(ids)-success}

    def scoped_chunks(self, scope, meeting_id=None):
        if scope not in ('all','meetings','meeting'):
            raise ValueError('检索范围无效。')
        conditions = ["s.deleted_at IS NULL", "s.status='indexed'", '(s.meeting_id IS NULL OR (m.id IS NOT NULL AND m.deleted_at IS NULL))', '(s.segment_id IS NULL OR (g.id IS NOT NULL AND g.deleted_at IS NULL))']
        params = []
        with self.db() as conn:
            if scope == 'meeting':
                if not meeting_id:
                    raise ValueError('请先选择会议。')
                self._meeting(conn,meeting_id,live=True)
                conditions.append('s.meeting_id=?')
                params.append(meeting_id)
            elif scope == 'meetings':
                conditions.append('s.meeting_id IS NOT NULL')
            # Scope is enforced in SQL before any vector or content leaves SQLite.
            rows = conn.execute('''SELECT c.text,c.embedding,c.ordinal,s.id AS source_id,s.filename,s.meeting_id,m.title AS meeting_title,
                                   s.revision AS source_revision,m.content_version AS meeting_content_version,s.segment_id
                                   FROM chunks c JOIN sources s ON c.source_id=s.id
                                   LEFT JOIN meetings m ON m.id=s.meeting_id
                                   LEFT JOIN segments g ON g.id=s.segment_id WHERE '''+' AND '.join(conditions),params).fetchall()
        return rows

    def retrieve(self, vector, scope, meeting_id=None, limit=8, include_versions=False):
        vector = vector_value(vector)
        rows = self.scoped_chunks(scope,meeting_id)
        scored = []
        for row in rows:
            score = cosine(vector,vector_value(json.loads(row['embedding'])))
            item={'meeting_id':row['meeting_id'],'meeting_title':row['meeting_title'],'source_id':row['source_id'],'filename':row['filename'],'text':row['text'],'score':score,'ordinal':row['ordinal']}
            if include_versions:
                item['_source_revision']=row['source_revision']
                item['_meeting_content_version']=row['meeting_content_version']
                item['_segment_id']=row['segment_id']
            scored.append(item)
        scored.sort(key=lambda x:x['score'],reverse=True)
        chosen = []
        seen = set()
        for item in scored:
            fingerprint = (item['source_id'],item['text'])
            if fingerprint in seen:
                continue
            seen.add(fingerprint)
            item.pop('ordinal')
            item['label'] = f'[{len(chosen)+1}]'
            chosen.append(item)
            if len(chosen) == limit:
                break
        return chosen

    def validate_citations(self, citations, scope, meeting_id=None):
        """Recheck the exact versions captured with the retrieved text's SQL snapshot.

        Caller holds Store.lock through this check and final job publication, so a
        mutation cannot slip between verification and publishing the final answer.
        """
        error='资料已变化，请重新提问。'
        with self.db() as conn:
            if scope=='meeting':
                row=conn.execute('SELECT deleted_at FROM meetings WHERE id=?',(meeting_id,)).fetchone()
                if not row or row['deleted_at'] is not None:
                    raise ValueError(error)
            for citation in citations:
                row=conn.execute('''SELECT s.revision,s.meeting_id,s.segment_id,s.deleted_at,s.status,
                                           m.id AS parent_meeting_id,m.deleted_at AS meeting_deleted,m.content_version,
                                           g.id AS parent_segment_id,g.deleted_at AS segment_deleted
                                    FROM sources s LEFT JOIN meetings m ON m.id=s.meeting_id
                                    LEFT JOIN segments g ON g.id=s.segment_id WHERE s.id=?''',(citation['source_id'],)).fetchone()
                if (not row or row['deleted_at'] is not None or row['status']!='indexed'
                    or row['revision']!=citation['_source_revision']
                    or row['meeting_id']!=citation['meeting_id']
                    or row['segment_id']!=citation['_segment_id']
                    or (row['meeting_id'] is not None and (row['parent_meeting_id'] is None or row['meeting_deleted'] is not None or row['content_version']!=citation['_meeting_content_version']))
                    or (row['segment_id'] is not None and (row['parent_segment_id'] is None or row['segment_deleted'] is not None))
                    or (scope=='meeting' and row['meeting_id']!=meeting_id)
                    or (scope=='meetings' and row['meeting_id'] is None)):
                    raise ValueError(error)

    def meeting_evidence(self, meeting_id, limit_chars=36_000):
        with self.db() as conn:
            meeting = self._meeting(conn,meeting_id,live=True)
            rows = conn.execute('''SELECT s.filename,s.text FROM sources s LEFT JOIN segments g ON s.segment_id=g.id
                                   WHERE s.meeting_id=? AND s.kind<>'summary' AND s.deleted_at IS NULL
                                   AND (s.segment_id IS NULL OR g.deleted_at IS NULL) ORDER BY s.created_at''', (meeting_id,)).fetchall()
        units = [(row['filename'],part) for row in rows for part in chunks(row['text'],size=1600,overlap=0)]
        # A bounded, evenly sampled excerpt covers the meeting rather than only its opening.
        max_units = max(1,limit_chars//1700)
        if len(units) > max_units:
            indices = sorted(set(round(i*(len(units)-1)/(max_units-1)) for i in range(max_units))) if max_units>1 else [0]
            units = [units[i] for i in indices]
        evidence = '\n\n'.join(f'[{i}] {filename}\n{text}' for i,(filename,text) in enumerate(units,1))
        return {'title':meeting['title'],'content_version':meeting['content_version'],'evidence':evidence[:limit_chars],'sampled':sum(len(row['text']) for row in rows)>limit_chars}

    def summary_evidence(self, meeting_id):
        """All current material, without sampling; generation groups it hierarchically."""
        with self.db() as conn:
            meeting = self._meeting(conn,meeting_id,live=True)
            rows = conn.execute('''SELECT s.filename,s.text FROM sources s LEFT JOIN segments g ON s.segment_id=g.id
                                   WHERE s.meeting_id=? AND s.kind<>'summary' AND s.deleted_at IS NULL
                                   AND (s.segment_id IS NULL OR g.deleted_at IS NULL) ORDER BY s.created_at''',(meeting_id,)).fetchall()
        units = []
        for row in rows:
            for part in chunks(row['text'],size=1400,overlap=0):
                units.append(f"[{len(units)+1}] {row['filename']}\n{part}")
        return {'title':meeting['title'],'content_version':meeting['content_version'],'units':units}

    def save_summary(self, meeting_id, summary, content_version,cancel_event=None):
        if not isinstance(summary,str) or not summary.strip():
            raise ValueError('模型未生成有效摘要。')
        with self.lock,self.db() as conn:
            check_cancel(cancel_event)
            row = self._meeting(conn,meeting_id,live=True)
            if row['content_version'] != content_version:
                raise ValueError('生成摘要时会议资料已更新，请重新生成。')
            conn.execute('UPDATE meetings SET summary=?,updated_at=? WHERE id=?',(summary,now(),meeting_id))
            source_id = self._text_source(conn,meeting_id,'summary',summary)
        self.index_source(source_id)
        return self.get_meeting(meeting_id,detail=False)

    def _copy_file(self, path, folder='attachments', cancel_event=None):
        path = Path(path).expanduser()
        if not path.is_absolute() or not path.is_file():
            raise ValueError('请选择存在的绝对路径本地文件。')
        destination_dir = self.data_dir/folder
        destination_dir.mkdir(mode=0o700,exist_ok=True)
        destination = destination_dir/(str(uuid.uuid4())+path.suffix.lower())
        partial = destination.with_name(destination.name+'.partial')
        digest,total = hashlib.sha256(),0
        try:
            with path.open('rb') as source, partial.open('xb') as output:
                partial.chmod(0o600)
                stat_before = source.fileno()
                import os
                stat_before = os.fstat(stat_before)
                if stat_before.st_size > MAX_FILE_BYTES:
                    raise ValueError('文件超过 256 MB，请拆分后导入。')
                while True:
                    check_cancel(cancel_event)
                    block = source.read(1024*1024)
                    if not block:
                        break
                    total += len(block)
                    if total > MAX_FILE_BYTES:
                        raise ValueError('文件超过 256 MB，请拆分后导入。')
                    output.write(block)
                    digest.update(block)
                stat_after = os.fstat(source.fileno())
                if (stat_before.st_size,stat_before.st_mtime_ns)!=(stat_after.st_size,stat_after.st_mtime_ns):
                    raise ValueError('导入过程中文件发生变化，请保存后重新导入。')
                output.flush()
                os.fsync(output.fileno())
            partial.replace(destination)
            return destination,digest.hexdigest()
        except BaseException:
            partial.unlink(missing_ok=True)
            raise

    def import_files(self, paths, meeting_id=None, cancel_event=None, progress=None):
        if not isinstance(paths,list) or not paths or len(paths)>100 or any(not isinstance(p,str) or not Path(p).is_absolute() for p in paths):
            raise ValueError('请选择 1–100 个绝对路径文件。')
        if meeting_id:
            with self.db() as conn:
                self._meeting(conn,meeting_id,live=True)
        items = []
        for i,path in enumerate(paths):
            try:
                check_cancel(cancel_event)
                items.append(self.import_file(path,meeting_id,cancel_event=cancel_event))
            except InterruptedError:
                if not items:
                    raise
                return {'items':items,'cancelled':True,'warnings':['处理已停止，已经完成的文件仍保留在资料库。']}
            if progress:
                progress((i+1)/len(paths),f'已处理 {i+1}/{len(paths)} 个文件。')
        return {'items':items}

    def import_file(self, path, meeting_id=None, *, cancel_event=None, origin_key=None, saved_text=None, filename=None):
        owned_copies=[]
        try:
            return self._import_file(path,meeting_id,cancel_event=cancel_event,origin_key=origin_key,saved_text=saved_text,filename=filename,owned_copies=owned_copies)
        finally:
            # Only this invocation's new copies are candidates. A copy referenced
            # by a durable source is preserved even if a later index is cancelled.
            for copied in owned_copies:
                if copied.parent != self.data_dir/'attachments':
                    continue
                with self.db() as conn:
                    referenced=conn.execute('SELECT 1 FROM sources WHERE path=? LIMIT 1',(str(copied),)).fetchone()
                if not referenced:
                    copied.unlink(missing_ok=True)

    def _import_file(self, path, meeting_id=None, *, cancel_event=None, origin_key=None, saved_text=None, filename=None,owned_copies):
        check_cancel(cancel_event)
        filename = filename or Path(path).name
        source_id,stamp = str(uuid.uuid4()),now()
        copied,digest = None,None
        with self.db() as conn:
            if meeting_id:
                self._meeting(conn,meeting_id,live=True)
            if origin_key:
                previous=conn.execute('SELECT * FROM sources WHERE logical_key=?',(origin_key,)).fetchone()
                if previous:
                    return self._source_public(conn,previous)
        try:
            copied,digest = self._copy_file(path,cancel_event=cancel_event)
            owned_copies.append(copied)
            check_cancel(cancel_event)
            with self.db() as conn:
                duplicate = conn.execute("SELECT id,deleted_at FROM sources WHERE COALESCE(meeting_id,'')=? AND kind='file' AND file_hash=?",(meeting_id or '',digest)).fetchone()
            if duplicate:
                copied.unlink()
                if duplicate['deleted_at'] is not None:
                    self.source_trash(duplicate['id'],False)
                return self.get_source(duplicate['id'])
            text,note = extract_text(copied) if saved_text is None else (saved_text,'从原应用的已读取文字导入。')
            check_cancel(cancel_event)
            status = 'indexing' if text.strip() else 'unreadable'
        except InterruptedError:
            if copied:
                copied.unlink(missing_ok=True)
            raise
        except Exception as exc:
            text,note,status = '','文件读取失败：'+str(exc),'error'
        with self.lock,self.db() as conn:
            check_cancel(cancel_event)
            if meeting_id:
                self._meeting(conn,meeting_id,live=True)
                self._invalidate_summary(conn,meeting_id)
            if origin_key:
                old = conn.execute('SELECT id FROM sources WHERE logical_key=?',(origin_key,)).fetchone()
                if old:
                    if copied:
                        copied.unlink(missing_ok=True)
                    return self._source_public(conn,conn.execute('SELECT * FROM sources WHERE id=?',(old['id'],)).fetchone())
            try:
                conn.execute('''INSERT INTO sources(id,meeting_id,kind,logical_key,filename,path,original_path,text,extraction_note,status,created_at,file_hash)
                                VALUES(?,?,'file',?,?,?,?,?,?,?,?,?)''',(source_id,meeting_id,origin_key,filename,str(copied or ''),str(path),text,note,status,stamp,digest))
            except sqlite3.IntegrityError:
                if copied:
                    copied.unlink(missing_ok=True)
                old = conn.execute("SELECT * FROM sources WHERE COALESCE(meeting_id,'')=? AND kind='file' AND file_hash=?",(meeting_id or '',digest)).fetchone()
                if old:
                    return self._source_public(conn,old)
                raise
        if status == 'indexing':
            try:
                self.index_source(source_id,cancel_event)
            except InterruptedError:
                # The complete immutable file and text were committed already.
                # Return the saved source so the job can report the actual effect.
                pass
        return self.get_source(source_id)

    def import_source_text(self, meeting_id, origin_key, filename, text):
        """Import original extracted contents when the external original file is absent."""
        if not isinstance(text,str):
            text = str(text or '')
        text = text[:500_000]
        with self.lock,self.db() as conn:
            old = conn.execute('SELECT * FROM sources WHERE logical_key=?',(origin_key,)).fetchone()
            if old:
                return self._source_public(conn,old)
            self._meeting(conn,meeting_id,live=True)
            source_id = str(uuid.uuid4())
            conn.execute('''INSERT INTO sources(id,meeting_id,kind,logical_key,filename,text,extraction_note,status,created_at)
                            VALUES(?,?,'file',?,?,?,'从原应用已读取文字导入；原文件副本不可用。',?,?)''',(source_id,meeting_id,origin_key,filename,text,'indexing' if text.strip() else 'unreadable',now()))
        self.index_source(source_id)
        return self.get_source(source_id)

    def list_sources(self, meeting_id=None, trash=False):
        with self.db() as conn:
            if meeting_id:
                self._meeting(conn,meeting_id)
            sql = "SELECT s.* FROM sources s LEFT JOIN meetings m ON s.meeting_id=m.id WHERE s.kind='file' AND s.deleted_at IS "+('NOT NULL' if trash else 'NULL')+" AND (s.meeting_id IS NULL OR m.deleted_at IS NULL)"
            params = []
            if meeting_id:
                sql += ' AND s.meeting_id=?'
                params.append(meeting_id)
            return [self._source_public(conn,row) for row in conn.execute(sql+' ORDER BY s.created_at DESC',params)]

    def get_source(self, source_id):
        with self.db() as conn:
            row = conn.execute("SELECT * FROM sources WHERE id=? AND kind='file'",(source_id,)).fetchone()
            if not row:
                raise KeyError('文件资料不存在。')
            return self._source_public(conn,row)

    def source_trash(self, source_id, trash):
        with self.lock,self.db() as conn:
            row = conn.execute("SELECT * FROM sources WHERE id=? AND kind='file'",(source_id,)).fetchone()
            if not row:
                raise KeyError('文件资料不存在。')
            if row['meeting_id']:
                self._meeting(conn,row['meeting_id'],live=True)
                self._invalidate_summary(conn,row['meeting_id'])
            conn.execute('UPDATE sources SET deleted_at=?,revision=revision+1 WHERE id=?',(now() if trash else None,source_id))

    def export_meeting(self, meeting_id):
        meeting = self.get_meeting(meeting_id)
        parts = [f"# {meeting['title']}",f"创建时间：{datetime.fromtimestamp(meeting['created_at']).strftime('%Y-%m-%d %H:%M')}"]
        for name,content in (('会议笔记',meeting['note']),('中文摘要',meeting['summary'])):
            if content:
                parts.append(f'## {name}\n\n{content}')
        parts.append('## 会议转写\n\n'+'\n\n'.join(f"### {segment['start_seconds']:.1f}–{segment['end_seconds']:.1f} 秒\n\n{segment['text']}" for segment in meeting['segments']))
        if meeting['attachments']:
            parts.append('## 附件\n\n'+'\n'.join(f"- {source['filename']}（{source['extraction_note']}）" for source in meeting['attachments']))
        safe_name = re.sub(r'[/\\:\x00-\x1f]', '_', meeting['title'])[:100]
        return {'filename':safe_name+'.md','markdown':'\n\n'.join(parts)+'\n'}

    def search(self, query):
        if not isinstance(query,str) or len(query)>2000:
            raise ValueError('搜索内容最多 2000 字。')
        pattern = '%'+query.replace('\\','\\\\').replace('%','\\%').replace('_','\\_')+'%'
        with self.db() as conn:
            rows = conn.execute('''SELECT DISTINCT m.* FROM meetings m LEFT JOIN segments g ON g.meeting_id=m.id AND g.deleted_at IS NULL
                                  WHERE m.deleted_at IS NULL AND (m.title LIKE ? ESCAPE '\\' OR m.note LIKE ? ESCAPE '\\' OR g.text LIKE ? ESCAPE '\\') ORDER BY m.created_at DESC''',(pattern,pattern,pattern)).fetchall()
            return [self._meeting_public(conn,row) for row in rows]

    @contextmanager
    def _original_snapshot(self, path):
        """sqlite backup from mode=ro includes WAL; it never creates/writes the origin."""
        path = Path(path).expanduser().resolve()
        if not path.is_absolute() or not path.is_file():
            raise ValueError('原应用数据库不存在，请选择 database.sqlite。')
        fixture = ROOT/'work'/'fixture'
        fixture.mkdir(parents=True,exist_ok=True,mode=0o700)
        snapshot_path = fixture/('readonly-import-'+str(uuid.uuid4())+'.sqlite')
        original = sqlite3.connect(path.as_uri()+'?mode=ro',uri=True,timeout=30)
        snapshot = sqlite3.connect(snapshot_path)
        snapshot.row_factory = sqlite3.Row
        try:
            original.execute('PRAGMA query_only=ON')
            original.backup(snapshot)
            snapshot_path.chmod(0o600)
            original.close()
            snapshot.execute('PRAGMA query_only=ON')
            yield snapshot
        finally:
            original.close()
            snapshot.close()
            snapshot_path.unlink(missing_ok=True)

    @staticmethod
    def _tables(conn):
        return {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}

    def _commit_imported_meeting(self, event, stamp, title, raw, note, summary):
        """Publish a complete original meeting in one transaction before indexing it."""
        meeting_id = str(uuid.uuid4())
        source_ids,offset = [],0
        with self.lock,self.db() as conn:
            previous = conn.execute('SELECT id FROM meetings WHERE origin_event_id=? AND origin_timestamp=?',(event,stamp)).fetchone()
            if previous:
                return previous['id'],False
            conn.execute('''INSERT INTO meetings(id,title,note,summary,created_at,updated_at,origin_event_id,origin_timestamp)
                            VALUES(?,?,?,?,?,?,?,?)''',(meeting_id,title,note,summary,stamp/1000,now(),event,stamp))
            for n,segment in enumerate(raw):
                if not isinstance(segment,dict):
                    continue
                turns = segment.get('turns') or []
                text = '\n'.join(f"{turn.get('speaker') or '发言人'}：{turn.get('text') or ''}" for turn in turns if isinstance(turn,dict) and turn.get('text'))
                try:
                    duration = max(0,float(segment.get('duration_seconds') or 0))
                    if not math.isfinite(duration):
                        duration = 0
                except (TypeError,ValueError):
                    duration = 0
                if text.strip():
                    segment_id = str(uuid.uuid4())
                    conn.execute('''INSERT INTO segments(id,meeting_id,text,start_seconds,end_seconds,created_at,request_id)
                                    VALUES(?,?,?,?,?,?,?)''',(segment_id,meeting_id,text,offset,offset+duration,stamp/1000,f'foresight:{event}:{stamp}:{n}'))
                    source_ids.append(self._text_source(conn,meeting_id,'transcript',text,segment_id=segment_id))
                offset += duration
            if note:
                source_ids.append(self._text_source(conn,meeting_id,'note',note))
            if summary:
                source_ids.append(self._text_source(conn,meeting_id,'summary',summary))
        for source_id in source_ids:
            self.index_source(source_id)
        return meeting_id,True

    def import_foresight(self, path=DEFAULT_FORESIGHT_DB, attachments_path=DEFAULT_ATTACHMENTS_DB, cancel_event=None, progress=None):
        imported,skipped,warnings = 0,0,[]
        attachment_rows = []
        if attachments_path and Path(attachments_path).expanduser().is_file():
            with self._original_snapshot(attachments_path) as sidecar:
                if 'meeting_files' in self._tables(sidecar):
                    attachment_rows = [dict(r) for r in sidecar.execute('SELECT * FROM meeting_files')]
        with self._original_snapshot(path) as original:
            tables = self._tables(original)
            if 'event_transcript_table' not in tables:
                raise ValueError('数据库中没有 Foresight 会议表。')
            rows = list(original.execute('SELECT * FROM event_transcript_table ORDER BY timestamp'))
            for index,row in enumerate(rows):
                check_cancel(cancel_event)
                event,stamp = str(row['event_id']),int(row['timestamp'])
                try:
                    raw = json.loads(row['transcript'])
                    if not isinstance(raw,list):
                        raise ValueError('转写不是片段数组。')
                except (ValueError,TypeError) as exc:
                    warnings.append(f'会议 {index+1} 转写格式异常：{exc}')
                    continue
                with self.db() as conn:
                    existing = conn.execute('SELECT id,deleted_at FROM meetings WHERE origin_event_id=? AND origin_timestamp=?',(event,stamp)).fetchone()
                if existing:
                    meeting_id = existing['id']
                    skipped += 1
                    if existing['deleted_at'] is not None:
                        continue  # Reimport never resurrects a deliberately trashed meeting.
                else:
                    title = (row['event_name'] or '').strip()
                    if not title or title.lower() in ('new meeting','[new meeting]'):
                        title = datetime.fromtimestamp(stamp/1000).strftime('会议 %Y-%m-%d %H:%M')
                    title = re.sub(r'[\x00-\x1f\x7f]', ' ', title)[:100].strip() or '导入会议'
                    note_text = ''
                    if 'notes_table' in tables:
                        note = original.execute('SELECT content FROM notes_table WHERE id=?',('note_'+event,)).fetchone()
                        if note and note['content']:
                            note_text = str(note['content'])[:500_000]
                    meeting_id,created = self._commit_imported_meeting(event,stamp,title,raw,note_text,str(row['post_event_summarization'] or ''))
                    imported += int(created)
                    skipped += int(not created)
                # Original association is per event_id. Never copy unrelated global documents.
                if 'event_document_table' in tables and 'source_text_table' in tables:
                    for source in original.execute('''SELECT s.* FROM source_text_table s JOIN event_document_table e ON e.document_id=s.document_id WHERE e.event_id=? AND s.source_type<>6''',(event,)):
                        check_cancel(cancel_event)
                        # On this installed version type 2 is the observed document
                        # class. No guessed universal enum; unknown classes fail closed.
                        if source['source_type']!=2:
                            warnings.append(f'会议 {index+1} 的一个关联来源类型未经验证，已跳过。')
                            continue
                        link = str(source['source_link'] or '')
                        parsed = urlsplit(link)
                        local_path = Path(unquote(parsed.path)) if parsed.scheme=='file' and parsed.netloc in ('','localhost') else Path(link) if link.startswith('/') else None
                        if local_path is None or not local_path.is_file() or local_path.suffix.lower() not in ('.txt','.md','.csv','.json','.log','.html','.htm','.pdf','.docx','.pptx','.xlsx'):
                            warnings.append(f'会议 {index+1} 的一个关联来源不是可验证的本地文档，已跳过。')
                            continue
                        self.import_file(str(local_path),meeting_id,origin_key=f"foresight-source:{event}:{stamp}:{source['document_id']}",filename=source['document_name'] or local_path.name,cancel_event=cancel_event)
                for attachment in attachment_rows:
                    if attachment.get('event_id') != event or attachment.get('event_timestamp') != stamp:
                        continue
                    check_cancel(cancel_event)
                    key = f"foresight-attachment:{event}:{stamp}:{attachment['id']}"
                    if Path(attachment.get('saved_path') or '').is_file():
                        self.import_file(attachment['saved_path'],meeting_id,origin_key=key,saved_text=attachment.get('text') or '',filename=attachment.get('filename'))
                    else:
                        self.import_source_text(meeting_id,key,attachment.get('filename') or '原会议附件',attachment.get('text') or '')
                if not existing:
                    summary = row['post_event_summarization'] or ''
                    if summary:
                        with self.db() as conn:
                            version = self._meeting(conn,meeting_id)['content_version']
                        self.save_summary(meeting_id,str(summary),version)
                if progress:
                    progress((index+1)/max(1,len(rows)),f'已读取 {index+1}/{len(rows)} 场会议。')
        return {'imported_meetings':imported,'skipped_meetings':skipped,'warnings':warnings}

    def create_job(self, kind, request_key=None):
        with self.db() as conn:
            job_id,stamp = str(uuid.uuid4()),now()
            conn.execute("INSERT INTO jobs(id,kind,request_key,state,created_at,updated_at) VALUES(?,?,?,'queued',?,?)",(job_id,kind,request_key,stamp,stamp))
        return job_id

    def find_job(self, request_key):
        with self.db() as conn:
            row = conn.execute("SELECT id FROM jobs WHERE request_key=? AND state IN ('queued','running','done') ORDER BY created_at DESC LIMIT 1",(request_key,)).fetchone()
            return row['id'] if row else None

    def update_job(self, job_id, **values):
        if not values or any(k not in ('state','progress','message','partial','result','error') for k in values):
            raise ValueError('任务状态字段无效。')
        if 'result' in values:
            values['result'] = json.dumps(values['result'],ensure_ascii=False) if values['result'] is not None else None
        with self.db() as conn:
            conn.execute('UPDATE jobs SET '+','.join(k+'=?' for k in values)+',updated_at=? WHERE id=?',(*values.values(),now(),job_id))

    def get_job(self, job_id):
        with self.db() as conn:
            row = conn.execute('SELECT * FROM jobs WHERE id=?',(job_id,)).fetchone()
            if not row:
                raise KeyError('任务不存在。')
            result = {k:row[k] for k in ('id','state','progress','message','partial','result','error')}
            result['result'] = json.loads(result['result']) if result['result'] is not None else None
            return result

    def recover_jobs(self):
        with self.db() as conn:
            conn.execute("UPDATE jobs SET state='cancelled',message='上次运行已中断，可重新提交。',partial='',result=NULL,updated_at=? WHERE state IN ('queued','running')",(now(),))
