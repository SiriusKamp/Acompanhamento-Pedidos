import { useState, type FormEvent } from 'react';
import { LockKeyhole, ShoppingBag } from 'lucide-react';
import { isSupabaseConfigured, supabase } from '../lib/supabase';

export function AuthScreen() {
  const [register, setRegister] = useState(false);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true); setError(''); setMessage('');
    try {
      if (register) {
        const { data, error: authError } = await supabase.auth.signUp({
          email: email.trim(), password,
        });
        if (authError) throw authError;
        if (!data.session) setMessage('Cadastro criado. Confirme o e-mail e depois entre.');
      } else {
        const { error: authError } = await supabase.auth.signInWithPassword({
          email: email.trim(), password,
        });
        if (authError) throw authError;
      }
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'Não foi possível autenticar.');
    } finally { setBusy(false); }
  }

  return <main className="auth-page"><section className="auth-card">
    <div className="auth-brand"><span className="brand-mark"><ShoppingBag size={23} /></span><strong>fluxo<span>.</span></strong></div>
    <div className="auth-icon"><LockKeyhole size={22} /></div>
    <h1>{register ? 'Criar conta' : 'Entrar no estoque'}</h1>
    <p>Use a mesma conta do Estoque para acessar seus produtos e pedidos.</p>
    {!isSupabaseConfigured ? <p className="form-error" role="alert">
      Configure VITE_SUPABASE_URL e VITE_SUPABASE_PUBLISHABLE_KEY no ambiente.
    </p> : <form className="auth-form" onSubmit={submit}>
      <label className="field"><span>E-mail</span><input type="email" autoComplete="username"
        required value={email} onChange={event => setEmail(event.target.value)} /></label>
      <label className="field"><span>Senha</span><input type="password"
        autoComplete={register ? 'new-password' : 'current-password'} minLength={6}
        required value={password} onChange={event => setPassword(event.target.value)} /></label>
      {error && <p className="form-error" role="alert">{error}</p>}
      {message && <p className="auth-message" role="status">{message}</p>}
      <button className="button button-primary" disabled={busy} type="submit">
        {busy ? 'Aguarde...' : register ? 'Cadastrar' : 'Entrar'}
      </button>
    </form>}
    {isSupabaseConfigured && <button className="auth-switch" onClick={() => {
      setRegister(value => !value); setError(''); setMessage('');
    }}>{register ? 'Já tenho conta' : 'Criar uma conta'}</button>}
  </section></main>;
}
