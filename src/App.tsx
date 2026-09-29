import { useEffect, useMemo, useState } from 'react';
import { ArrowDownToLine, ArrowRight, Bell, CheckCheck, ChevronRight, CircleX, Clock3, LayoutDashboard, LoaderCircle, Package, Plus, RefreshCw, Search, ShoppingBag, Sparkles, Wallet } from 'lucide-react';
import type { Order, OrderStatus, Product } from './model';
import { initials, money, parseAmount, statusLabels, timeLabel, uid } from './model';
import { createOrder, changeOrderStatus, getOrders, getProducts, updateProductPrice, type NewOrder } from './lib/pedidosApi';
import { readOrders, readProducts, saveOrders, saveProducts } from './lib/localData';
import { OrderModal } from './components/OrderModal';
import { ImportModal } from './components/ImportModal';

type Tab = 'orders' | 'products';
const statuses: OrderStatus[] = ['waiting', 'preparing', 'finished', 'cancelled'];
const DEMO_KEY = 'fluxo-demo-mode';

function statusIcon(status: OrderStatus) {
  return { waiting: Clock3, preparing: Package, finished: CheckCheck, cancelled: CircleX }[status];
}

function nextActions(status: OrderStatus): Array<{ status: OrderStatus; label: string; primary?: boolean }> {
  const actions: Record<OrderStatus, Array<{ status: OrderStatus; label: string; primary?: boolean }>> = {
    waiting: [{ status: 'preparing', label: 'Preparar', primary: true }, { status: 'cancelled', label: 'Cancelar' }],
    preparing: [{ status: 'finished', label: 'Finalizar', primary: true }, { status: 'cancelled', label: 'Cancelar' }],
    finished: [],
    cancelled: [{ status: 'waiting', label: 'Reabrir', primary: true }],
  };
  return actions[status];
}

function OrderCard({ order, onStatus, busy }: {
  order: Order; onStatus: (id: string, status: OrderStatus) => void; busy: boolean;
}) {
  const remaining = Math.max(0, order.finalTotal - order.paid);
  const change = Math.max(0, order.paid - order.finalTotal);
  return <article className="order-card">
    <div className="order-card-top"><span className="order-number">#{String(order.number).padStart(4, '0')}</span><span className="order-time"><Clock3 size={13} /> {timeLabel(order.createdAt)}</span></div>
    <h3>{order.customer || 'Cliente sem nome'}</h3>
    <p className="order-note">{order.note || 'Pedido para acompanhar'}</p>
    <div className="order-items">{order.items.map((item, index) => <div key={`${item.productId}-${index}`}><span><b>{item.quantity}×</b> {item.name}</span><span>{money(item.quantity * item.unitPrice)}</span></div>)}</div>
    <div className="order-financial"><div><span>Total</span><strong>{money(order.finalTotal)}</strong></div><small className={remaining > 0 ? 'payment-due' : 'payment-done'}>{remaining > 0 ? `Falta ${money(remaining)}` : change > 0 ? `Troco ${money(change)}` : 'Pagamento completo'}</small></div>
    {nextActions(order.status).length > 0 && <div className="card-actions">{nextActions(order.status).map(action => <button key={action.status} className={action.primary ? 'card-action-primary' : 'card-action-secondary'} disabled={busy} onClick={() => onStatus(order.id, action.status)}>{action.label}{action.primary && <ChevronRight size={15} />}</button>)}</div>}
  </article>;
}

function BoardColumn({ status, orders, onStatus, busyId }: {
  status: OrderStatus; orders: Order[]; onStatus: (id: string, status: OrderStatus) => void; busyId: string | null;
}) {
  const Icon = statusIcon(status);
  return <section className={`board-column column-${status}`} aria-label={statusLabels[status]}>
    <div className="column-head"><div className="column-title"><span className="status-icon"><Icon size={17} /></span><h2>{statusLabels[status]}</h2></div><span className="count-badge">{orders.length}</span></div>
    <div className="column-content">{orders.length ? orders.map(order => <OrderCard key={order.id} order={order} onStatus={onStatus} busy={busyId === order.id} />)
      : <div className="column-empty"><div><Icon size={24} /></div><p>Nenhum pedido<br />{statusLabels[status].toLowerCase()}</p></div>}</div>
  </section>;
}

function CatalogCard({ product, onSave, busy }: {
  product: Product; onSave: (id: string, price: number) => Promise<void>; busy: boolean;
}) {
  const [editing, setEditing] = useState(false);
  const [priceText, setPriceText] = useState(product.price.toFixed(2));
  const [error, setError] = useState('');
  useEffect(() => { if (!editing) setPriceText(product.price.toFixed(2)); }, [product.price, editing]);
  async function submit() {
    if (!priceText.trim() || !Number.isFinite(Number(priceText.replace(',', '.'))) || Number(priceText.replace(',', '.')) < 0) {
      setError('Preço inválido.'); return;
    }
    setError('');
    try { await onSave(product.id, parseAmount(priceText)); setEditing(false); }
    catch (failure) { setError(failure instanceof Error ? failure.message : 'Não foi possível salvar.'); }
  }
  return <article className="catalog-card"><div className="catalog-card-main"><div className={`catalog-avatar ${product.isKit ? 'avatar-kit' : ''}`}>{initials(product.name)}</div><div className="catalog-info"><span className="catalog-category">{product.category} {product.isKit && <b>Kit</b>}</span><h3>{product.name}</h3><p>{product.code}</p></div></div>
    <div className="catalog-bottom"><div><small>Preço de venda</small>{editing ? <div className="catalog-edit"><div className="money-field"><span>R$</span><input aria-label={`Preço de ${product.name}`} inputMode="decimal" value={priceText} onChange={event => setPriceText(event.target.value)} onKeyDown={event => { if (event.key === 'Enter') void submit(); if (event.key === 'Escape') setEditing(false); }} /></div><button className="button button-primary button-small" disabled={busy} onClick={submit}>Salvar</button></div> : <strong>{money(product.price)}</strong>}</div>{!editing && <button className="link-button" onClick={() => setEditing(true)}>Editar preço</button>}</div>
    {product.suggestedPrice !== null && <div className="catalog-suggested"><Sparkles size={13} /> Sugerido pelo estoque: {money(product.suggestedPrice)}</div>}
    {error && <p className="form-error" role="alert">{error}</p>}
  </article>;
}

export default function App() {
  const [tab, setTab] = useState<Tab>('orders');
  const [demoMode, setDemoMode] = useState(() => localStorage.getItem(DEMO_KEY) === 'true');
  const [products, setProducts] = useState<Product[]>([]);
  const [orders, setOrders] = useState<Order[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [modal, setModal] = useState<'order' | 'import' | null>(null);
  const [orderSearch, setOrderSearch] = useState('');
  const [productSearch, setProductSearch] = useState('');
  const [busyId, setBusyId] = useState<string | null>(null);
  const [reload, setReload] = useState(0);
  const [slow, setSlow] = useState(false);
  const [toast, setToast] = useState('');

  useEffect(() => {
    let active = true;
    setLoading(true); setError(''); setSlow(false);
    const timer = window.setTimeout(() => { if (active) setSlow(true); }, 12000);
    if (demoMode) {
      setProducts(readProducts()); setOrders(readOrders()); setLoading(false);
      window.clearTimeout(timer);
    } else {
      void Promise.all([getProducts(), getOrders()]).then(([newProducts, newOrders]) => {
        if (!active) return;
        if (!Array.isArray(newProducts) || !Array.isArray(newOrders)) throw new Error('Formato de resposta inválido da API.');
        setProducts(newProducts); setOrders(newOrders); setLoading(false);
      }).catch(failure => { if (active) { setError(failure instanceof Error ? failure.message : 'Falha ao consultar a API.'); setLoading(false); } });
    }
    return () => { active = false; window.clearTimeout(timer); };
  }, [demoMode, reload]);

  useEffect(() => {
    if (!toast) return;
    const timer = window.setTimeout(() => setToast(''), 4500);
    return () => window.clearTimeout(timer);
  }, [toast]);

  const filteredOrders = useMemo(() => {
    const needle = orderSearch.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
    return orders.filter(order => `${order.number} ${order.customer} ${order.items.map(item => item.name).join(' ')}`
      .normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().includes(needle));
  }, [orders, orderSearch]);
  const filteredProducts = useMemo(() => {
    const needle = productSearch.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
    return products.filter(product => `${product.name} ${product.code} ${product.category}`
      .normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().includes(needle));
  }, [products, productSearch]);
  const counts = Object.fromEntries(statuses.map(status => [status, orders.filter(order => order.status === status).length])) as Record<OrderStatus, number>;
  const finishedTotal = orders.filter(order => order.status === 'finished').reduce((sum, order) => sum + order.finalTotal, 0);
  const today = new Intl.DateTimeFormat('pt-BR', { day: 'numeric', month: 'long', year: 'numeric' }).format(new Date());

  function toggleDemo() {
    const next = !demoMode;
    localStorage.setItem(DEMO_KEY, String(next));
    setDemoMode(next); setModal(null);
  }

  async function addOrder(input: NewOrder) {
    let created: Order;
    if (demoMode) {
      const items = input.items.map(item => {
        const product = products.find(candidate => candidate.id === item.productId);
        if (!product) throw new Error('Um item não está mais disponível. Atualize o catálogo.');
        return { productId: product.id, name: product.name, quantity: item.quantity, unitPrice: product.price };
      });
      const now = new Date().toISOString();
      created = { id: uid(), number: Math.max(0, ...orders.map(order => order.number)) + 1,
        customer: input.customer, note: input.note, items,
        suggestedTotal: Math.round(items.reduce((sum, item) => sum + item.unitPrice * item.quantity, 0) * 100) / 100,
        finalTotal: input.finalTotal, paid: input.paid, status: 'waiting', createdAt: now, updatedAt: now };
    } else created = await createOrder(input);
    setOrders(current => {
      const updated = [created, ...current.filter(order => order.id !== created.id)];
      if (demoMode) saveOrders(updated);
      return updated;
    });
    setToast(`Pedido #${String(created.number).padStart(4, '0')} criado.`);
  }

  async function updateStatus(id: string, status: OrderStatus) {
    setBusyId(id);
    try {
      let updated: Order;
      if (demoMode) {
        const current = orders.find(order => order.id === id);
        if (!current) throw new Error('Pedido não encontrado.');
        updated = { ...current, status, updatedAt: new Date().toISOString() };
      } else updated = await changeOrderStatus(id, status);
      setOrders(current => {
        const next = current.map(order => order.id === id ? updated : order);
        if (demoMode) saveOrders(next);
        return next;
      });
      setToast(`Pedido movido para ${statusLabels[status].toLowerCase()}.`);
    } catch (failure) { setToast(failure instanceof Error ? failure.message : 'Não foi possível atualizar o pedido.'); }
    finally { setBusyId(null); }
  }

  async function savePrice(id: string, price: number) {
    setBusyId(id);
    try {
      const updated = demoMode ? { ...products.find(product => product.id === id)!, price } : await updateProductPrice(id, price);
      setProducts(current => {
        const next = current.map(product => product.id === id ? updated : product);
        if (demoMode) saveProducts(next);
        return next;
      });
      setToast('Preço atualizado. Pedidos antigos mantêm o preço registrado na venda.');
    } finally { setBusyId(null); }
  }

  function imported(importedProducts: Product[]) {
    setProducts(current => {
      const byId = new Map(current.map(product => [product.id, product]));
      importedProducts.forEach(product => byId.set(product.id, product));
      const next = [...byId.values()].sort((a, b) => a.name.localeCompare(b.name, 'pt-BR'));
      if (demoMode) saveProducts(next);
      return next;
    });
    setToast(`${importedProducts.length} produto(s) importado(s).`);
    if (!demoMode) setReload(value => value + 1);
  }

  return <div className="app-shell">
    <aside className="sidebar"><div className="brand"><div className="brand-mark"><ShoppingBag size={22} /></div><div><strong>fluxo<span>.</span></strong><small>acompanhamento de pedidos</small></div></div>
      <div className="sidebar-label">ESPAÇO DE TRABALHO</div>
      <nav className="main-nav" aria-label="Menu principal"><button className={tab === 'orders' ? 'nav-item active' : 'nav-item'} onClick={() => setTab('orders')}><LayoutDashboard size={19} /> Pedidos <span>{orders.length}</span></button><button className={tab === 'products' ? 'nav-item active' : 'nav-item'} onClick={() => setTab('products')}><Package size={19} /> Produtos <span>{products.length}</span></button></nav>
      <div className="sidebar-divider" /><div className="sidebar-label">VISÃO RÁPIDA</div><div className="sidebar-statuses">{statuses.map(status => <button key={status} onClick={() => setTab('orders')}><i className={`dot dot-${status}`} />{statusLabels[status]}<b>{counts[status]}</b></button>)}</div>
      <div className="sidebar-bottom"><div className="mode-card"><span className={demoMode ? 'mode-dot demo' : 'mode-dot'} /><div><strong>{demoMode ? 'Modo demonstração' : 'API de pedidos'}</strong><small>{demoMode ? 'Dados apenas neste navegador' : 'localhost:8086'}</small></div></div><button className="mode-toggle" onClick={toggleDemo}>{demoMode ? 'Usar API local' : 'Ativar demonstração'} <ArrowRight size={15} /></button></div>
    </aside>

    <main className="main-area"><header className="topbar"><div className="mobile-brand"><div className="brand-mark"><ShoppingBag size={19} /></div><strong>fluxo<span>.</span></strong></div><div className="breadcrumb">Visão geral <ChevronRight size={14} /> <strong>{tab === 'orders' ? 'Pedidos' : 'Produtos'}</strong></div><div className="topbar-right"><span className="today-label">{today}</span><span className="topbar-icon"><Bell size={19} /></span><span className="user-avatar">OP</span></div></header>
      <div className="mobile-nav"><button className={tab === 'orders' ? 'active' : ''} onClick={() => setTab('orders')}><LayoutDashboard size={17} /> Pedidos</button><button className={tab === 'products' ? 'active' : ''} onClick={() => setTab('products')}><Package size={17} /> Produtos</button><button onClick={toggleDemo}>{demoMode ? 'Demo' : 'API'}</button></div>
      <div className="page-content">
        {tab === 'orders' ? <><section className="hero"><div className="hero-content"><span className="eyebrow"><Sparkles size={14} /> PAINEL DE OPERAÇÃO</span><h1>Um pedido de cada vez.<br /><em>Tudo em movimento.</em></h1><p>Acompanhe a operação em tempo real, do primeiro item à entrega.</p><div className="hero-actions"><button className="button button-white" onClick={() => setModal('order')}><Plus size={18} /> Criar pedido</button><button className="button button-hero-outline" onClick={() => setModal('import')}><ArrowDownToLine size={17} /> Importar itens</button></div></div><div className="hero-art" aria-hidden="true"><div className="orbit orbit-one" /><div className="orbit orbit-two" /><div className="floating-tile tile-one"><Package size={27} /></div><div className="floating-tile tile-two"><CheckCheck size={24} /></div><div className="floating-tile tile-three"><ShoppingBag size={31} /></div></div></section>
          <section className="metrics" aria-label="Resumo dos pedidos"><div className="metric"><span className="metric-icon metric-violet"><ShoppingBag size={22} /></span><div><small>Pedidos no total</small><strong>{orders.length}</strong></div></div><div className="metric"><span className="metric-icon metric-amber"><Clock3 size={22} /></span><div><small>Aguardando</small><strong>{counts.waiting}</strong></div></div><div className="metric"><span className="metric-icon metric-blue"><Package size={22} /></span><div><small>Em preparo</small><strong>{counts.preparing}</strong></div></div><div className="metric"><span className="metric-icon metric-green"><Wallet size={22} /></span><div><small>Finalizados</small><strong>{money(finishedTotal)}</strong></div></div></section>
          <section className="section-heading"><div><span className="section-kicker">QUADRO DE PEDIDOS</span><h2>Acompanhe cada etapa</h2><p>Movimente os cartões conforme o pedido avança.</p></div><div className="heading-controls"><label className="search-field"><Search size={18} /><input aria-label="Pesquisar pedidos" placeholder="Buscar pedido ou cliente" value={orderSearch} onChange={event => setOrderSearch(event.target.value)} /></label><button className="button button-primary" onClick={() => setModal('order')}><Plus size={18} /> Novo pedido</button></div></section>
          {loading ? <div className="loading-panel"><LoaderCircle className="spin" size={25} /><strong>Carregando pedidos e produtos...</strong>{slow && <span>A API pode estar iniciando. Aguarde mais um pouco.</span>}</div> : error ? <div className="error-panel"><strong>Não foi possível carregar os dados.</strong><p>{error}</p><div><button className="button button-secondary" onClick={() => setReload(value => value + 1)}><RefreshCw size={16} /> Tentar novamente</button><button className="button button-primary" onClick={() => setModal('import')}>Conectar estoque</button></div></div> : <div className="board" aria-label="Pedidos por status">{statuses.map(status => <BoardColumn key={status} status={status} orders={filteredOrders.filter(order => order.status === status)} onStatus={updateStatus} busyId={busyId} />)}</div>}
        </> : <><section className="catalog-hero"><div><span className="section-kicker">SEU CATÁLOGO</span><h1>Produtos & preços</h1><p>Os itens importados do estoque ficam prontos para entrar nos pedidos.</p></div><button className="button button-primary" onClick={() => setModal('import')}><ArrowDownToLine size={18} /> Importar produtos</button></section>
          <div className="catalog-toolbar"><label className="search-field"><Search size={18} /><input aria-label="Pesquisar produtos" placeholder="Buscar por nome, código ou categoria" value={productSearch} onChange={event => setProductSearch(event.target.value)} /></label><span>{filteredProducts.length} produto{filteredProducts.length === 1 ? '' : 's'}</span></div>
          {loading ? <div className="loading-panel"><LoaderCircle className="spin" size={25} /> Carregando catálogo...</div> : error ? <div className="error-panel"><strong>Não foi possível carregar o catálogo.</strong><p>{error}</p><button className="button button-primary" onClick={() => setModal('import')}>Conectar estoque</button></div> : filteredProducts.length ? <div className="catalog-grid">{filteredProducts.map(product => <CatalogCard key={product.id} product={product} onSave={savePrice} busy={busyId === product.id} />)}</div> : <div className="catalog-empty"><div><Package size={31} /></div><h2>{products.length ? 'Nenhum item encontrado' : 'Seu catálogo começa aqui'}</h2><p>{products.length ? 'Tente outro nome ou código.' : 'Importe itens do estoque e defina os preços que vão aparecer nos pedidos.'}</p><button className="button button-primary" onClick={() => setModal('import')}><ArrowDownToLine size={17} /> Importar produtos</button></div>}
        </>}
      </div>
    </main>
    {toast && <div className="toast" role="status"><CheckCheck size={17} />{toast}</div>}
    {modal === 'order' && <OrderModal products={products} onClose={() => setModal(null)} onCreate={addOrder} onImport={() => setModal('import')} />}
    {modal === 'import' && <ImportModal currentProducts={products} demoMode={demoMode} onClose={() => setModal(null)} onImported={imported} onStockSelected={() => setReload(value => value + 1)} />}
  </div>;
}
