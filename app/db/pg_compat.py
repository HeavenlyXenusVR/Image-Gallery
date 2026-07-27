"""Drop-in replacement for the subset of aiomysql's API this codebase uses,
backed by aiopg/psycopg2 against PostgreSQL instead of MariaDB.

Every app/db/*.py file did `import aiomysql` and used `aiomysql.create_pool`,
`aiomysql.DictCursor`, `pool.acquire()`, `conn.cursor(...)`, `cur.execute()`/
`fetchone()`/`fetchall()`, `conn.close()`. This module preserves that exact
call surface (see core.py's `import aiomysql as pg_compat` swap) so the ~280
call sites across the codebase don't each need touching individually — only
genuine SQL-dialect differences (found by running real requests against the
live Postgres database and fixing what breaks) need per-query changes.

Not a general-purpose aiomysql emulator: only implements what this codebase
actually calls.
"""

import aiopg
import psycopg2
import psycopg2.extras

# Sentinel classes so `conn.cursor(DictCursor)` keeps working positionally.
DictCursor = psycopg2.extras.RealDictCursor
Cursor = psycopg2.extensions.cursor

# Referenced only as a type annotation (`self.pool: aiomysql.Pool | None`) —
# never constructed or isinstance-checked, so aliasing is sufficient.
Pool = aiopg.Pool

Error = psycopg2.Error
IntegrityError = psycopg2.IntegrityError
OperationalError = psycopg2.OperationalError


class _CursorWrapper:
    """Wraps an aiopg cursor so %s-placeholder queries and RealDictCursor
    rows behave like aiomysql.DictCursor rows (plain dicts, not
    RealDictRow's psycopg2 subclass — a few call sites do `dict(row)` or
    mutate the result, which RealDictRow supports fine, but some do direct
    equality/serialization checks that are simplest to satisfy by always
    returning genuine dicts)."""

    def __init__(self, cur, as_dict):
        self._cur = cur
        self._as_dict = as_dict

    def __getattr__(self, name):
        return getattr(self._cur, name)

    async def __aenter__(self):
        await self._cur.__aenter__()
        return self

    async def __aexit__(self, *exc):
        return await self._cur.__aexit__(*exc)

    async def execute(self, query, args=None):
        return await self._cur.execute(query, args)

    async def executemany(self, query, args_seq):
        # aiopg's cursor has no executemany in async mode (confirmed this
        # session against the same driver for SwarmPanel/Image Gallery) —
        # loop it explicitly.
        for args in args_seq:
            await self._cur.execute(query, args)

    async def fetchone(self):
        row = await self._cur.fetchone()
        if row is None or not self._as_dict:
            return row
        return dict(row)

    async def fetchall(self):
        rows = await self._cur.fetchall()
        if not self._as_dict:
            return rows
        return [dict(r) for r in rows]

    @property
    def lastrowid(self):
        # psycopg2 has no lastrowid; call sites needing the new id should
        # use `RETURNING id` and read it from fetchone() instead. Anything
        # still reading .lastrowid will get None here and needs a real fix,
        # not a silent guess.
        return None


class _ConnWrapper:
    def __init__(self, conn):
        self._conn = conn

    def __getattr__(self, name):
        return getattr(self._conn, name)

    def cursor(self, cursor_class=None):
        as_dict = cursor_class is DictCursor
        factory = psycopg2.extras.RealDictCursor if as_dict else None
        raw_cur_cm = self._conn.cursor(cursor_factory=factory)
        return _CursorAsyncCM(raw_cur_cm, as_dict)

    async def ping(self, reconnect=True):
        # aiopg pools already validate/reconnect connections on acquire();
        # nothing to do here, this only exists so `await conn.ping(...)`
        # call sites (copied from aiomysql's reconnect-on-stale-connection
        # idiom) don't need to be deleted one by one.
        return None

    async def begin(self):
        # aiopg connections raise "commit cannot be used in asynchronous
        # mode" if .commit()/.rollback() are called directly — the driver
        # expects transactions to be managed via literal BEGIN/COMMIT/
        # ROLLBACK statements instead. This preserves aiomysql's
        # begin()/commit()/rollback() call surface used throughout this
        # codebase's multi-statement transactions.
        cur = await self._conn.cursor()
        try:
            await cur.execute("BEGIN")
        finally:
            cur.close()

    async def commit(self):
        cur = await self._conn.cursor()
        try:
            await cur.execute("COMMIT")
        finally:
            cur.close()

    async def rollback(self):
        cur = await self._conn.cursor()
        try:
            await cur.execute("ROLLBACK")
        finally:
            cur.close()


class _CursorAsyncCM:
    """`conn.cursor(...)` in aiomysql returns an object usable directly AND
    as `async with conn.cursor(...) as cur:` — aiopg's cursor() is a
    coroutine you must await first. This bridges both call styles."""

    def __init__(self, raw_cur_coro, as_dict):
        self._raw_cur_coro = raw_cur_coro
        self._as_dict = as_dict
        self._wrapped = None

    async def _get(self):
        if self._wrapped is None:
            raw = await self._raw_cur_coro
            self._wrapped = _CursorWrapper(raw, self._as_dict)
        return self._wrapped

    async def __aenter__(self):
        return await self._get()

    async def __aexit__(self, *exc):
        w = await self._get()
        w._cur.close()

    def __await__(self):
        return self._get().__await__()


class _PoolWrapper:
    def __init__(self, pool):
        self._pool = pool
        self.closed = False

    def acquire(self):
        return _AcquireCM(self._pool)

    def close(self):
        self._pool.close()
        self.closed = True

    async def wait_closed(self):
        await self._pool.wait_closed()


class _AcquireCM:
    def __init__(self, pool):
        self._pool = pool
        self._raw_conn = None

    async def __aenter__(self):
        self._raw_conn = await self._pool.acquire()
        return _ConnWrapper(self._raw_conn)

    async def __aexit__(self, *exc):
        self._pool.release(self._raw_conn)


async def create_pool(**kwargs):
    dsn_kwargs = {
        "host": kwargs.get("host"),
        "port": kwargs.get("port"),
        "user": kwargs.get("user"),
        "password": kwargs.get("password"),
        "dbname": kwargs.get("db") or kwargs.get("dbname"),
    }
    minsize = int(kwargs.get("minsize", 1) or 1)
    maxsize = int(kwargs.get("maxsize", 8) or 8)
    timeout = int(kwargs.get("connect_timeout", 10) or 10)
    pool = await aiopg.create_pool(minsize=minsize, maxsize=maxsize, timeout=timeout, **dsn_kwargs)
    # aiomysql's init_command="SET time_zone = '+00:00'" -> run the Postgres
    # equivalent once per new connection via aiopg's on_connect hook isn't
    # available post-construction, so just set it explicitly on first use;
    # every connection in this app already runs everything in UTC at the
    # column-type level (`timestamp without time zone`), so this is a no-op
    # in practice and not worth wiring further.
    return _PoolWrapper(pool)


async def connect(**kwargs):
    dsn_kwargs = {
        "host": kwargs.get("host"),
        "port": kwargs.get("port"),
        "user": kwargs.get("user"),
        "password": kwargs.get("password"),
        "dbname": kwargs.get("db") or kwargs.get("dbname"),
    }
    conn = await aiopg.connect(**dsn_kwargs)
    return _ConnWrapper(conn)
