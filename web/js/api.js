import { config } from './config.js';

export const sb = window.supabase.createClient(config.supabaseUrl, config.anonKey, {
  db: { schema: config.schema },
  auth: { persistSession: true, autoRefreshToken: true, storageKey: config.storageKey, detectSessionInUrl: false },
});

function translate(error) {
  const m = error?.message || 'Unbekannter Fehler';
  if (error?.code === '42501' || /forbidden|permission denied/i.test(m)) return 'Dafür fehlt die Berechtigung.';
  if (/JWT|expired|invalid.*token/i.test(m)) return 'Die Anmeldung ist abgelaufen. Bitte neu anmelden.';
  if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return 'Keine Verbindung zum Server.';
  return m;
}

// Leere Werte weglassen, damit die Standardwerte der Datenbankfunktion greifen.
// keepNull: Parameter ohne Standardwert, die explizit null sein duerfen.
export function clean(args, keepNull = []) {
  const out = {};
  for (const [k, v] of Object.entries(args || {})) {
    if (v === undefined || v === '') continue;
    if (v === null && !keepNull.includes(k)) continue;
    out[k] = v;
  }
  return out;
}

export async function rpc(fn, args, keepNull) {
  const { data, error } = await sb.rpc(fn, clean(args, keepNull));
  if (error) {
    const e = new Error(translate(error));
    e.code = error.code;
    throw e;
  }
  return data;
}
