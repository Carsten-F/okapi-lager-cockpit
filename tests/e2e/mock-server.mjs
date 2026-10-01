// Mock der Supabase-API fuer lokale Tests: Login (/auth/v1) und RPC (/rest/v1/rpc) gegen
// eine lokale Postgres-Datenbank, dazu die statischen Dateien aus ../../web unter /lager/.
// Die SQL-Funktionen laufen unveraendert als Rolle authenticated mit gesetzter Nutzer-ID.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const here = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(here, '../../web');
const USERS = {
  'admin@test': 'a0000000-0000-0000-0000-000000000001', 'einkauf@test': 'a0000000-0000-0000-0000-000000000002',
  'lager@test': 'a0000000-0000-0000-0000-000000000003', 'viewer@test': 'a0000000-0000-0000-0000-000000000004',
  'keine@test': 'a0000000-0000-0000-0000-000000000005',
};
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.txt': 'text/plain', '.svg': 'image/svg+xml' };
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const token = (sub, email) => `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub, email, role: 'authenticated', aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 })}.mock`;
const subOf = (req) => { try { return JSON.parse(Buffer.from((req.headers.authorization || '').split('.')[1], 'base64url')).sub; } catch { return null; } };
const session = (email) => { const id = USERS[email]; return { access_token: token(id, email), token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600,
  refresh_token: `r-${email}`, user: { id, aud: 'authenticated', role: 'authenticated', email, app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() } }; };

export function startMock({ port, pgConfig }) {
  const pool = new pg.Pool(pgConfig);
  const log = [];
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x');
    const send = (code, body, headers = {}) => { res.writeHead(code, { 'content-type': 'application/json', ...headers }); res.end(body == null ? '' : JSON.stringify(body)); };
    const readBody = () => new Promise((r) => { let d = ''; req.on('data', (c) => (d += c)); req.on('end', () => r(d ? JSON.parse(d) : {})); });
    try {
      if (url.pathname === '/auth/v1/token') {
        const b = await readBody();
        const email = url.searchParams.get('grant_type') === 'refresh_token' ? String(b.refresh_token || '').replace(/^r-/, '') : b.email;
        if (!USERS[email] || (b.password !== undefined && b.password !== 'test')) return send(400, { code: 400, error_code: 'invalid_credentials', msg: 'Invalid login credentials' });
        return send(200, session(email));
      }
      if (url.pathname === '/auth/v1/user') { const sub = subOf(req); const email = Object.keys(USERS).find((k) => USERS[k] === sub); return email ? send(200, session(email).user) : send(401, { msg: 'invalid' }); }
      if (url.pathname === '/auth/v1/logout') return send(204, null);
      if (url.pathname.startsWith('/rest/v1/rpc/')) {
        const fn = url.pathname.split('/').pop(); const args = await readBody(); const sub = subOf(req);
        if (!sub) return send(401, { code: 'PGRST301', message: 'JWT invalid' });
        if (!/^lager_[a-z_]+$/.test(fn) || req.headers['content-profile'] !== 'okapi_stock') return send(404, { code: 'PGRST202', message: 'not found' });
        const keys = Object.keys(args);
        const sql = `select okapi_stock.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`;
        const client = await pool.connect();
        try {
          await client.query('begin');
          await client.query('set local role authenticated');
          await client.query("select set_config('request.jwt.claim.sub', $1, true)", [sub]);
          const r = await client.query(sql, keys.map((k) => (args[k] === null ? null : typeof args[k] === 'object' ? JSON.stringify(args[k]) : String(args[k]))));
          await client.query('commit');
          log.push({ fn, ok: true });
          return send(200, r.rows[0].r);
        } catch (e) {
          await client.query('rollback').catch(() => {});
          log.push({ fn, ok: false, msg: e.message });
          return send(e.code === '42501' ? 403 : 400, { code: e.code, message: e.message, details: null, hint: null });
        } finally { client.release(); }
      }
      if (url.pathname === '/' ) { res.writeHead(302, { location: '/lager/' }); return res.end(); }
      if (url.pathname.startsWith('/lager')) {
        let rel = url.pathname.replace(/^\/lager\/?/, '') || 'index.html';
        const file = path.join(webRoot, rel);
        if (!file.startsWith(webRoot) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); return res.end('not found'); }
        res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream',
          // dieselbe Policy wie in deploy/apache-lager.conf.example, damit der Test Verstoesse findet
          'content-security-policy': "default-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
          'x-content-type-options': 'nosniff' });
        return fs.createReadStream(file).pipe(res);
      }
      res.writeHead(404); res.end('not found');
    } catch (e) { send(500, { message: String(e) }); }
  });
  return new Promise((resolve) => server.listen(port, () => resolve({ server, pool, log, close: () => { server.close(); return pool.end(); } })));
}
