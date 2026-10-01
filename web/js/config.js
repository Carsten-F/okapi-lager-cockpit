// Der ANON_KEY ist fuer Browser gedacht und darf hier stehen. Er allein gewaehrt keinen
// Datenzugriff: alle Funktionen verlangen einen Login und eine Rolle (lager.user_roles).
// NIEMALS den SERVICE_ROLE_KEY hier eintragen.
export const config = {
  // Seite und API liegen auf derselben Adresse (supabase.okapi-online.de).
  supabaseUrl: window.location.origin,
  anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzg4OTU1NjE1LCJleHAiOjE5NDY2MzU2MTV9.s8TmeHXueuJqjjW6RBiQ5a8YVm4_Fusu-avQ7EuuIRA',
  schema: 'okapi_stock',
  storageKey: 'okapi-lager-auth',
};
