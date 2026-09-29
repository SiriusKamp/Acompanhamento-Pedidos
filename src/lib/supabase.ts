import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL?.trim();
const key = (import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
  || import.meta.env.VITE_SUPABASE_ANON_KEY)?.trim();

export const isSupabaseConfigured = !!url && /^https?:\/\//.test(url) && !!key;
// The browser only receives a publishable/anon key; owner checks live in RLS/RPCs.
export const supabase = createClient(
  isSupabaseConfigured ? url : 'http://127.0.0.1:54321',
  isSupabaseConfigured ? key : 'unconfigured-public-key',
  { auth: { persistSession: isSupabaseConfigured, autoRefreshToken: isSupabaseConfigured,
    detectSessionInUrl: isSupabaseConfigured } },
);
