import { useMemo, useState } from 'react';
import { Minus, Plus, RotateCcw, Search, ShoppingBag, Sparkles } from 'lucide-react';
import type { Product } from '../model';
import { initials, money, parseAmount } from '../model';
import type { NewOrder } from '../lib/pedidosApi';
import { Modal } from './Modal';

export function OrderModal({ products, onClose, onCreate, onImport }: {
  products: Product[]; onClose: () => void; onCreate: (order: NewOrder) => Promise<void>; onImport: () => void;
}) {
  const [search, setSearch] = useState('');
  const [kitOnly, setKitOnly] = useState(false);
  const [quantities, setQuantities] = useState<Record<string, number>>({});
  const [customer, setCustomer] = useState('');
  const [note, setNote] = useState('');
  const [editedFinal, setEditedFinal] = useState<string | null>(null);
  const [paidText, setPaidText] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const filtered = useMemo(() => {
    const needle = search.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
    return products.filter(product => (!kitOnly || product.isKit)
      && `${product.name} ${product.code} ${product.category}`.normalize('NFD').replace(/[\u0300-\u036f]/g, '')
        .toLowerCase().includes(needle));
  }, [products, search, kitOnly]);
  const selected = products.filter(product => (quantities[product.id] ?? 0) > 0);
  const subtotal = Math.round(selected.reduce((sum, product) => sum + product.price * quantities[product.id], 0) * 100) / 100;
  const finalText = editedFinal ?? subtotal.toFixed(2);
  const finalTotal = parseAmount(finalText);
  const paid = parseAmount(paidText);
  const change = Math.max(0, Math.round((paid - finalTotal) * 100) / 100);
  const remaining = Math.max(0, Math.round((finalTotal - paid) * 100) / 100);

  function changeQuantity(id: string, difference: number) {
    setQuantities(current => ({ ...current, [id]: Math.max(0, Math.min(999, (current[id] ?? 0) + difference)) }));
  }

  async function submit() {
    if (!selected.length) { setError('Adicione pelo menos um produto ao pedido.'); return; }
    if (editedFinal !== null && (!editedFinal.trim() || !Number.isFinite(Number(editedFinal.replace(',', '.'))) || Number(editedFinal.replace(',', '.')) < 0)) {
      setError('Informe um valor final válido.'); return;
    }
    if (paidText.trim() && (!Number.isFinite(Number(paidText.replace(',', '.'))) || Number(paidText.replace(',', '.')) < 0)) {
      setError('Informe um valor pago válido.'); return;
    }
    setBusy(true); setError('');
    try {
      await onCreate({ customer: customer.trim(), note: note.trim(),
        items: selected.map(product => ({ productId: product.id, quantity: quantities[product.id] })),
        finalTotal, paid });
      onClose();
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'Não foi possível criar o pedido.');
    } finally { setBusy(false); }
  }

  return <Modal title="Criar pedido" subtitle="Escolha os itens e confira o pagamento antes de salvar." onClose={onClose} wide>
    <div className="order-modal-grid">
      <section className="picker-panel">
        <div className="picker-toolbar">
          <label className="search-field"><Search size={18} /><input data-autofocus value={search} onChange={event => setSearch(event.target.value)} placeholder="Buscar nome, código ou categoria" /></label>
          <div className="filter-pills"><button className={!kitOnly ? 'pill active' : 'pill'} onClick={() => setKitOnly(false)}>Todos</button><button className={kitOnly ? 'pill active' : 'pill'} onClick={() => setKitOnly(true)}>Kits</button></div>
        </div>
        <div className="picker-list">
          {!products.length && <div className="modal-empty"><ShoppingBag size={30} /><h3>Seu catálogo está vazio</h3><p>Importe os produtos do estoque antes de criar o primeiro pedido.</p><button className="button button-secondary" onClick={onImport}>Importar produtos</button></div>}
          {products.length > 0 && filtered.length === 0 && <div className="modal-empty"><Search size={28} /><h3>Nenhum produto encontrado</h3><p>Tente outro nome ou código.</p></div>}
          {filtered.map(product => <div className="picker-item" key={product.id}>
            <div className={`product-avatar ${product.isKit ? 'avatar-kit' : ''}`}>{initials(product.name)}</div>
            <div className="picker-info"><strong>{product.name}</strong><span>{product.category} · {product.code}</span></div>
            <strong className="picker-price">{money(product.price)}</strong>
            <div className="stepper"><button aria-label={`Remover ${product.name}`} onClick={() => changeQuantity(product.id, -1)} disabled={!quantities[product.id]}><Minus size={14} /></button><span>{quantities[product.id] ?? 0}</span><button aria-label={`Adicionar ${product.name}`} onClick={() => changeQuantity(product.id, 1)}><Plus size={14} /></button></div>
          </div>)}
        </div>
      </section>
      <section className="checkout-panel">
        <div className="checkout-heading"><span className="checkout-icon"><ShoppingBag size={18} /></span><div><h3>Resumo do pedido</h3><p>{selected.length ? `${selected.reduce((sum, item) => sum + quantities[item.id], 0)} item(ns) selecionado(s)` : 'Adicione itens ao lado'}</p></div></div>
        <div className="selected-lines">{selected.length ? selected.map(product => <div className="selected-line" key={product.id}><span>{quantities[product.id]}× {product.name}</span><strong>{money(product.price * quantities[product.id])}</strong></div>) : <div className="cart-placeholder">Os itens escolhidos aparecem aqui.</div>}</div>
        <div className="subtotal-line"><span>Valor sugerido</span><strong>{money(subtotal)}</strong></div>
        <div className="form-grid">
          <label className="field"><span>Cliente ou mesa <small>opcional</small></span><input value={customer} onChange={event => setCustomer(event.target.value)} placeholder="Ex.: Mesa 04" /></label>
          <label className="field"><span>Observações <small>opcional</small></span><input value={note} onChange={event => setNote(event.target.value)} placeholder="Ex.: sem gelo" /></label>
        </div>
        <div className="payment-grid">
          <label className="field"><span>Valor final <small>editável</small></span><div className="money-field suggested-field"><span>R$</span><input inputMode="decimal" aria-label="Valor final" value={finalText} onChange={event => setEditedFinal(event.target.value)} /></div></label>
          <label className="field"><span>Valor pago</span><div className="money-field"><span>R$</span><input inputMode="decimal" aria-label="Valor pago" value={paidText} onChange={event => setPaidText(event.target.value)} placeholder="0,00" /></div></label>
        </div>
        {editedFinal !== null && <button className="reset-price" onClick={() => setEditedFinal(null)}><RotateCcw size={13} /> Usar valor sugerido</button>}
        <div className={`change-box ${remaining > 0 ? 'change-pending' : ''}`}><div><span>{remaining > 0 ? 'Falta receber' : 'Troco a devolver'}</span><strong>{money(remaining > 0 ? remaining : change)}</strong></div><Sparkles size={21} /></div>
        {error && <p className="form-error" role="alert">{error}</p>}
        <button className="button button-primary checkout-submit" onClick={submit} disabled={busy || !selected.length}>{busy ? 'Salvando...' : 'Criar pedido'}</button>
      </section>
    </div>
  </Modal>;
}
