import { useEffect, useMemo, useState } from 'react';
import { ArrowLeft, Check, CloudDownload, LockKeyhole, Package, Search, Sparkles } from 'lucide-react';
import type { Product } from '../model';
import { money, parseAmount } from '../model';
import { connectStock, getProducts, getStockProducts, importProducts, type Stock, type StockProduct } from '../lib/pedidosApi';
import { demoProducts } from '../lib/demo';
import { Modal } from './Modal';

type Draft = StockProduct & { selected: boolean; priceText: string };

export function ImportModal({ currentProducts, demoMode, onClose, onImported, onStockSelected }: {
  currentProducts: Product[]; demoMode: boolean; onClose: () => void; onImported: (products: Product[]) => void; onStockSelected: () => void;
}) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [connectionId, setConnectionId] = useState('');
  const [stocks, setStocks] = useState<Stock[]>([]);
  const [stockId, setStockId] = useState('');
  const [draft, setDraft] = useState<Draft[]>([]);
  const [search, setSearch] = useState('');
  const [busy, setBusy] = useState(false);
  const [slow, setSlow] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!busy) { setSlow(false); return; }
    const timer = window.setTimeout(() => setSlow(true), 12000);
    return () => window.clearTimeout(timer);
  }, [busy]);

  const filtered = useMemo(() => {
    const needle = search.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
    return draft.filter(item => `${item.name} ${item.code} ${item.category}`.normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '').toLowerCase().includes(needle));
  }, [draft, search]);
  const selectedCount = draft.filter(item => item.selected).length;

  async function connect() {
    if (!email.trim() || !password) { setError('Informe e-mail e senha do estoque.'); return; }
    setBusy(true); setError('');
    try {
      const result = await connectStock(email, password);
      if (!result.stocks.length) throw new Error('Esta conta não possui estoques disponíveis.');
      setConnectionId(result.connectionId); setStocks(result.stocks); setStockId(result.stocks[0].id);
      setPassword('');
    } catch (failure) { setError(failure instanceof Error ? failure.message : 'Não foi possível conectar.'); }
    finally { setBusy(false); }
  }

  async function load() {
    if (!stockId) return;
    setBusy(true); setError(''); setDraft([]);
    try {
      const products = await getStockProducts(connectionId, stockId);
      const existingCatalog = await getProducts();
      setDraft(products.map(product => {
        const existing = existingCatalog.find(item => item.sourceProductId === product.sourceProductId && item.sourceStockId === stockId);
        return { ...product, selected: true, priceText: (existing?.price ?? product.suggestedPrice ?? 0).toFixed(2) };
      }));
      onStockSelected();
    } catch (failure) { setError(failure instanceof Error ? failure.message : 'Não foi possível buscar os produtos.'); }
    finally { setBusy(false); }
  }

  async function saveImport() {
    const selected = draft.filter(item => item.selected);
    if (!selected.length) { setError('Selecione pelo menos um produto.'); return; }
    if (selected.some(item => !item.priceText.trim() || !Number.isFinite(Number(item.priceText.replace(',', '.'))) || Number(item.priceText.replace(',', '.')) < 0)) {
      setError('Confira os preços dos itens selecionados.'); return;
    }
    setBusy(true); setError('');
    try {
      const products = await importProducts(connectionId, stockId, selected.map(item => ({
        sourceProductId: item.sourceProductId, price: parseAmount(item.priceText),
      })));
      onImported(products); onClose();
    } catch (failure) { setError(failure instanceof Error ? failure.message : 'Não foi possível importar.'); }
    finally { setBusy(false); }
  }

  function importDemo() {
    const existing = new Map(currentProducts.map(item => [item.id, item]));
    const merged = demoProducts().map(item => existing.get(item.id) ?? item);
    onImported(merged); onClose();
  }

  return <Modal title="Importar produtos" subtitle={demoMode ? 'Experimente o fluxo com um catálogo de exemplo.' : 'Conecte sua conta de estoque e defina os preços de venda.'} onClose={onClose} wide={!!draft.length}>
    {demoMode ? <div className="import-intro"><div className="import-hero-icon"><Package size={28} /></div><h3>Catálogo de demonstração</h3><p>Seis itens de exemplo serão adicionados ao seu catálogo local. Você poderá criar pedidos e testar o cálculo de troco.</p><button className="button button-primary" onClick={importDemo}><CloudDownload size={17} /> Importar exemplos</button></div> : <div className="import-body">
      {!connectionId ? <div className="connect-grid"><div className="connect-copy"><div className="import-hero-icon"><CloudDownload size={28} /></div><h3>Conecte o seu estoque</h3><p>Entre com a conta do Estoque para escolher os produtos e kits que quer vender neste painel.</p><div className="security-note"><LockKeyhole size={16} /><span>A senha não é salva no navegador. A API de pedidos mantém a conexão temporária.</span></div></div><form className="connect-form" onSubmit={event => { event.preventDefault(); void connect(); }}><label className="field"><span>E-mail do estoque</span><input data-autofocus type="email" autoComplete="username" value={email} onChange={event => setEmail(event.target.value)} placeholder="voce@exemplo.com" required /></label><label className="field"><span>Senha do estoque</span><input type="password" autoComplete="current-password" value={password} onChange={event => setPassword(event.target.value)} placeholder="Sua senha" required /></label><button className="button button-primary" type="submit" disabled={busy}>{busy ? 'Conectando...' : 'Conectar estoque'}</button>{slow && <p className="slow-note">A API está iniciando. Isso pode levar alguns minutos.</p>}</form></div>
      : <><div className="import-controls"><button className="text-back" onClick={() => { setConnectionId(''); setStocks([]); setDraft([]); }}><ArrowLeft size={16} /> Outra conta</button><label className="field"><span>Estoque de origem</span><select value={stockId} onChange={event => { setStockId(event.target.value); setDraft([]); }}>
        {stocks.map(stock => <option key={stock.id} value={stock.id}>{stock.name}</option>)}
      </select></label><button className="button button-secondary" onClick={load} disabled={busy}><CloudDownload size={17} /> {busy ? 'Buscando...' : 'Buscar produtos'}</button></div>
      {slow && <p className="slow-note">A API está respondendo lentamente. Aguarde mais um pouco.</p>}
      {draft.length > 0 && <><div className="import-list-head"><label className="search-field"><Search size={17} /><input value={search} onChange={event => setSearch(event.target.value)} placeholder="Filtrar produtos" /></label><button className="text-back" onClick={() => setDraft(items => items.map(item => ({ ...item, selected: selectedCount !== items.length })))}>{selectedCount === draft.length ? 'Desmarcar todos' : 'Selecionar todos'}</button></div><div className="import-list">
        {filtered.map(item => <div className="import-row" key={item.sourceProductId}><label className="import-check"><input type="checkbox" checked={item.selected} onChange={event => setDraft(items => items.map(row => row.sourceProductId === item.sourceProductId ? { ...row, selected: event.target.checked } : row))} /><span className="check-ui"><Check size={13} /></span></label><div className="import-row-info"><strong>{item.name}</strong><span>{item.category} · {item.code}</span></div><div className="import-price"><label>Preço de venda</label><div className="money-field"><span>R$</span><input inputMode="decimal" aria-label={`Preço de ${item.name}`} value={item.priceText} onChange={event => setDraft(items => items.map(row => row.sourceProductId === item.sourceProductId ? { ...row, priceText: event.target.value } : row))} /></div><small>{item.suggestedPrice !== null ? `Sugerido: ${money(item.suggestedPrice)}` : 'Sem preço sugerido'}</small></div></div>)}
        {!filtered.length && <p className="list-empty">Nenhum produto corresponde à busca.</p>}
      </div><div className="import-footer"><span><Sparkles size={16} /> {selectedCount} de {draft.length} selecionados</span><button className="button button-primary" onClick={saveImport} disabled={!selectedCount || busy}>{busy ? 'Importando...' : `Importar ${selectedCount} produto${selectedCount === 1 ? '' : 's'}`}</button></div></>}
      {!busy && !draft.length && <div className="modal-empty compact"><Package size={27} /><p>Busque os itens deste estoque para selecionar e precificar.</p></div>}
      </>}
      {error && <p className="form-error" role="alert">{error}</p>}
    </div>}
  </Modal>;
}
