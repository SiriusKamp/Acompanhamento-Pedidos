import { useEffect, useMemo, useRef, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { ArrowDownToLine, ArrowLeft, Bell, CheckCheck, ChevronRight, CircleX, Clock3, LayoutDashboard, LoaderCircle, LogOut, Package, Plus, RefreshCw, Search, ShoppingBag, Sparkles, Wallet, Zap } from 'lucide-react';
import type { Order, OrderStatus, Product } from './model';
import { elapsedLabel, initials, money, parseAmount, statusLabels, timeLabel } from './model';
import { createOrder, changeOrderStatus, createStock, getOrders, getProducts, getStocks, updateProductPrice, type NewOrder, type Stock } from './lib/pedidosApi';
import { supabase } from './lib/supabase';
import { OrderModal } from './components/OrderModal';
import { ImportModal } from './components/ImportModal';
import { AuthScreen } from './components/AuthScreen';
import { ThemePicker, themeLabels, themeOrder, type Theme } from './components/ThemePicker';

type Tab = 'orders' | 'products';
const statuses: OrderStatus[] = ['waiting', 'preparing', 'finished', 'cancelled'];

function statusIcon(status: OrderStatus) {
  return { waiting: Clock3, preparing: Package, finished: CheckCheck, cancelled: CircleX }[status];
}

function nextActions(status: OrderStatus): Array<{ status: OrderStatus; label: string; primary?: boolean; back?: boolean }> {
  const actions: Record<OrderStatus, Array<{ status: OrderStatus; label: string; primary?: boolean; back?: boolean }>> = {
    waiting: [{ status: 'preparing', label: 'Preparar', primary: true }, { status: 'cancelled', label: 'Cancelar' }],
    preparing: [{ status: 'waiting', label: 'Voltar', back: true }, { status: 'finished', label: 'Finalizar', primary: true }, { status: 'cancelled', label: 'Cancelar' }],
    finished: [],
    cancelled: [{ status: 'waiting', label: 'Voltar para aguardando', primary: true, back: true }],
  };
  return actions[status];
}

function OrderCard({ order, onStatus, busy, now }: {
  order: Order; onStatus: (id: string, status: OrderStatus) => void; busy: boolean; now: number;
}) {
  const remaining = Math.max(0, order.finalTotal - order.paid);
  const change = Math.max(0, order.paid - order.finalTotal);
  return <article className="order-card">
    <div className="order-card-top"><span className="order-number">#{String(order.number).padStart(4, '0')}</span><span className="order-time">Criado às {timeLabel(order.createdAt)}</span></div>
    <span className="order-elapsed" aria-label={`Tempo desde a criação: ${elapsedLabel(order.createdAt, now)}`}><Clock3 size={15} /> {elapsedLabel(order.createdAt, now)}</span>
    <h3>{order.customer || 'Cliente sem nome'}</h3>
    {order.note && <p className="order-note">{order.note}</p>}
    <div className="order-items">{order.items.map((item, index) => <div className="order-item" key={`${item.productId}-${index}`}><span className="order-item-quantity">{item.quantity}×</span><strong className="order-item-name">{item.name}</strong><span className="order-item-price">{money(item.quantity * item.unitPrice)}</span></div>)}</div>
    <div className="order-financial"><div><span>Total</span><strong>{money(order.finalTotal)}</strong></div><small className={remaining > 0 ? 'payment-due' : 'payment-done'}>{remaining > 0 ? `Falta ${money(remaining)}` : change > 0 ? `Troco ${money(change)}` : 'Pagamento completo'}</small></div>
    {nextActions(order.status).length > 0 && <div className="card-actions">{nextActions(order.status).map(action => <button key={action.status} className={action.primary ? 'card-action-primary' : 'card-action-secondary'} disabled={busy} onClick={() => onStatus(order.id, action.status)}>{action.back && <ArrowLeft size={15} />}{action.label}{action.primary && !action.back && <ChevronRight size={15} />}</button>)}</div>}
    {order.status === 'finished' && <p className="order-locked">Finalizado · estoque baixado</p>}
  </article>;
}

function BoardColumn({ status, orders, onStatus, busyId, now, mobileActive }: {
  status: OrderStatus; orders: Order[]; onStatus: (id: string, status: OrderStatus) => void;
  busyId: string | null; now: number; mobileActive: boolean;
}) {
  const Icon = statusIcon(status);
  return <section className={`board-column column-${status} ${mobileActive ? '' : 'mobile-hidden'}`} aria-label={statusLabels[status]}>
    <div className="column-head"><div className="column-title"><span className="status-icon"><Icon size={17} /></span><h2>{statusLabels[status]}</h2></div><span className="count-badge">{orders.length}</span></div>
    <div className="column-content">{orders.length ? orders.map(order => <OrderCard key={order.id} order={order} onStatus={onStatus} busy={busyId === order.id} now={now} />)
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
  const [theme, setTheme] = useState<Theme>(() => {
    const stored = localStorage.getItem('pedidos-theme-v1');
    if (stored === 'light' || stored === 'dark' || stored === 'neon') return stored;
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  });
  const [now, setNow] = useState(Date.now());
  const [mobileStage, setMobileStage] = useState<OrderStatus>('waiting');
  const [session, setSession] = useState<Session | null>(null);
  const [authLoading, setAuthLoading] = useState(true);
  const [stocks, setStocks] = useState<Stock[]>([]);
  const [stockId, setStockId] = useState('');
  const [stocksLoading, setStocksLoading] = useState(false);
  const [stocksError, setStocksError] = useState('');
  const [stockReload, setStockReload] = useState(0);
  const [newStockName, setNewStockName] = useState('');
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
  const busyIdRef = useRef<string | null>(null);
  const ordersVersionRef = useRef(0);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem('pedidos-theme-v1', theme);
  }, [theme]);

  useEffect(() => {
    const tick = () => setNow(Date.now());
    const timer = window.setInterval(tick, 60_000);
    document.addEventListener('visibilitychange', tick);
    return () => { window.clearInterval(timer); document.removeEventListener('visibilitychange', tick); };
  }, []);

  useEffect(() => {
    let active = true;
    let authRevision = 0;
    let previousUserId: string | null = null;
    const applySession = (next: Session | null) => {
      if (!active) return;
      const nextUserId = next?.user.id ?? null;
      if (previousUserId !== nextUserId) {
        setStocks([]); setStockId(''); setProducts([]); setOrders([]);
        previousUserId = nextUserId;
      }
      setSession(next); setAuthLoading(false);
    };
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, next) => {
      authRevision++;
      applySession(next);
    });
    const initialRevision = authRevision;
    void supabase.auth.getSession().then(({ data }) => {
      if (active && authRevision === initialRevision) applySession(data.session);
    }).catch(() => { if (active && authRevision === initialRevision) setAuthLoading(false); });
    return () => { active = false; subscription.unsubscribe(); };
  }, []);

  useEffect(() => {
    const userId = session?.user.id;
    if (!userId) {
      setStocks([]); setStockId(''); setProducts([]); setOrders([]); return;
    }
    let active = true;
    setStocksLoading(true); setStocksError('');
    void getStocks().then(rows => {
      if (!active) return;
      setStocks(rows);
      const preferred = localStorage.getItem(`pedidos-stock:${userId}`);
      setStockId(rows.find(row => row.id === preferred)?.id ?? rows[0]?.id ?? '');
    }).catch(failure => {
      if (active) setStocksError(failure instanceof Error ? failure.message : 'Falha ao consultar estoques.');
    }).finally(() => { if (active) setStocksLoading(false); });
    return () => { active = false; };
  }, [session?.user.id, stockReload]);

  useEffect(() => {
    let active = true;
    if (!stockId) { setProducts([]); setOrders([]); setLoading(false); return; }
    setProducts([]); setOrders([]);
    setLoading(true); setError(''); setSlow(false);
    const timer = window.setTimeout(() => { if (active) setSlow(true); }, 12000);
    void Promise.all([getProducts(stockId), getOrders(stockId)]).then(([newProducts, newOrders]) => {
      if (!active) return;
      setProducts(newProducts); setOrders(newOrders); setLoading(false);
    }).catch(failure => {
      if (active) { setError(failure instanceof Error ? failure.message : 'Falha ao consultar pedidos.'); setLoading(false); }
    });
    return () => { active = false; window.clearTimeout(timer); };
  }, [stockId, reload]);

  useEffect(() => {
    if (!stockId || !session) return;
    let active = true;
    let inFlight = false;
    const refresh = async () => {
      if (!active || inFlight || document.hidden || busyIdRef.current) return;
      inFlight = true;
      const version = ordersVersionRef.current;
      try {
        const latest = await getOrders(stockId);
        if (active && version === ordersVersionRef.current && !busyIdRef.current) setOrders(latest);
      } catch {
        // The next scheduled refresh retries; user actions still report their own errors.
      } finally { inFlight = false; }
    };
    const timer = window.setInterval(() => { void refresh(); }, 30_000);
    const onVisible = () => { if (!document.hidden) void refresh(); };
    document.addEventListener('visibilitychange', onVisible);
    return () => { active = false; window.clearInterval(timer); document.removeEventListener('visibilitychange', onVisible); };
  }, [stockId, session?.user.id]);

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

  function chooseStock(next: string) {
    if (!session) return;
    localStorage.setItem(`pedidos-stock:${session.user.id}`, next);
    setProducts([]); setOrders([]); setLoading(true);
    setStockId(next); setModal(null);
  }

  async function addStock() {
    if (!session || !newStockName.trim()) return;
    try {
      const created = await createStock(session.user.id, newStockName);
      setStocks(current => [...current, created]);
      setNewStockName('');
      chooseStock(created.id);
    } catch (failure) {
      setStocksError(failure instanceof Error ? failure.message : 'Não foi possível criar o estoque.');
    }
  }

  async function addOrder(input: NewOrder) {
    const created = await createOrder(stockId, input);
    ordersVersionRef.current++;
    setOrders(current => {
      return [created, ...current.filter(order => order.id !== created.id)];
    });
    setToast(`Pedido #${String(created.number).padStart(4, '0')} criado.`);
  }

  async function updateStatus(id: string, status: OrderStatus) {
    busyIdRef.current = id;
    ordersVersionRef.current++;
    setBusyId(id);
    try {
      const updated = await changeOrderStatus(stockId, id, status);
      setOrders(current => {
        return current.map(order => order.id === id ? updated : order);
      });
      setMobileStage(status);
      setToast(`Pedido movido para ${statusLabels[status].toLowerCase()}.`);
    } catch (failure) { setToast(failure instanceof Error ? failure.message : 'Não foi possível atualizar o pedido.'); }
    finally { busyIdRef.current = null; setBusyId(null); }
  }

  async function savePrice(id: string, price: number) {
    busyIdRef.current = id;
    setBusyId(id);
    try {
      const updated = await updateProductPrice(stockId, id, price);
      setProducts(current => {
        return current.map(product => product.id === id ? updated : product);
      });
      setToast('Preço atualizado. Pedidos antigos mantêm o preço registrado na venda.');
    } finally { busyIdRef.current = null; setBusyId(null); }
  }

  function imported(importedProducts: Product[]) {
    setProducts(current => {
      const byId = new Map(current.map(product => [product.id, product]));
      importedProducts.forEach(product => byId.set(product.id, product));
      const next = [...byId.values()].sort((a, b) => a.name.localeCompare(b.name, 'pt-BR'));
      return next;
    });
    setToast(`${importedProducts.length} produto(s) importado(s).`);
    setReload(value => value + 1);
  }

  if (authLoading) return <div className="loading-panel full-screen"><LoaderCircle className="spin" size={27} /> Recuperando sessão...</div>;
  if (!session) return <AuthScreen theme={theme} onThemeChange={setTheme} />;
  if (stocksLoading) return <div className="loading-panel full-screen"><LoaderCircle className="spin" size={27} /> Carregando estoques...</div>;
  if (!stockId) return <main className="auth-page"><section className="auth-card">
    <ThemePicker theme={theme} onChange={setTheme} />
    <div className="auth-brand"><span className="brand-mark"><ShoppingBag size={23} /></span><strong>fluxo<span>.</span></strong></div>
    <h1>Seu primeiro estoque</h1><p>Crie um estoque ou use a mesma conta no Estoque Pro para trazer seus produtos.</p>
    {stocksError && <p className="form-error" role="alert">{stocksError}</p>}
    <form className="auth-form" onSubmit={event => { event.preventDefault(); void addStock(); }}>
      <label className="field"><span>Nome do estoque</span><input required value={newStockName}
        onChange={event => setNewStockName(event.target.value)} placeholder="Ex.: Loja principal" /></label>
      <button className="button button-primary" type="submit">Criar estoque</button>
    </form>
    <button className="auth-switch" onClick={() => setStockReload(value => value + 1)}>Atualizar lista</button>
    <button className="auth-switch" onClick={() => void supabase.auth.signOut()}>Sair da conta</button>
  </section></main>;

  return <div className="app-shell">
    <aside className="sidebar"><div className="brand"><div className="brand-mark"><ShoppingBag size={22} /></div><div><strong>fluxo<span>.</span></strong><small>acompanhamento de pedidos</small></div></div>
      <div className="sidebar-label">ESPAÇO DE TRABALHO</div>
      <nav className="main-nav" aria-label="Menu principal"><button className={tab === 'orders' ? 'nav-item active' : 'nav-item'} onClick={() => setTab('orders')}><LayoutDashboard size={19} /> Pedidos <span>{orders.length}</span></button><button className={tab === 'products' ? 'nav-item active' : 'nav-item'} onClick={() => setTab('products')}><Package size={19} /> Produtos <span>{products.length}</span></button></nav>
      <div className="sidebar-divider" /><div className="sidebar-label">VISÃO RÁPIDA</div><div className="sidebar-statuses">{statuses.map(status => <button key={status} onClick={() => setTab('orders')}><i className={`dot dot-${status}`} />{statusLabels[status]}<b>{counts[status]}</b></button>)}</div>
      <div className="sidebar-bottom"><div className="mode-card"><span className="mode-dot" /><div><strong>Estoque conectado</strong><small>{stocks.find(stock => stock.id === stockId)?.name}</small></div></div>
        <button className="mode-toggle" onClick={() => void supabase.auth.signOut()}><LogOut size={15} /> Sair da conta</button></div>
    </aside>

    <main className="main-area"><header className="topbar"><div className="mobile-brand"><div className="brand-mark"><ShoppingBag size={19} /></div><strong>fluxo<span>.</span></strong></div><div className="breadcrumb">Visão geral <ChevronRight size={14} /> <strong>{tab === 'orders' ? 'Pedidos' : 'Produtos'}</strong></div><div className="topbar-right"><label className="stock-selector"><span>Estoque</span><select aria-label="Estoque ativo" value={stockId} onChange={event => chooseStock(event.target.value)}>{stocks.map(stock => <option key={stock.id} value={stock.id}>{stock.name}</option>)}</select></label><ThemePicker theme={theme} onChange={setTheme} /><span className="today-label">{today}</span><span className="topbar-icon"><Bell size={19} /></span><span className="user-avatar">{initials(session.user.email ?? 'Usuário')}</span><button className="mobile-signout" aria-label="Sair da conta" onClick={() => void supabase.auth.signOut()}><LogOut size={17} /></button></div></header>
      <div className="mobile-nav"><button className={tab === 'orders' ? 'active' : ''} onClick={() => setTab('orders')}><LayoutDashboard size={17} /> Pedidos</button><button className={tab === 'products' ? 'active' : ''} onClick={() => setTab('products')}><Package size={17} /> Produtos</button><button className="mobile-theme" aria-label={`Tema atual: ${themeLabels[theme]}. Alterar tema`} title={`Tema: ${themeLabels[theme]}`} onClick={() => setTheme(themeOrder[(themeOrder.indexOf(theme) + 1) % themeOrder.length])}><Zap size={17} /><span>{themeLabels[theme]}</span></button></div>
      <div className="page-content">
        {tab === 'orders' ? <><section className="hero"><div className="hero-content"><span className="eyebrow"><Sparkles size={14} /> PAINEL DE OPERAÇÃO</span><h1>Um pedido de cada vez.<br /><em>Tudo em movimento.</em></h1><p>Acompanhe a operação em tempo real, do primeiro item à entrega.</p><div className="hero-actions"><button className="button button-white" onClick={() => setModal('order')}><Plus size={18} /> Criar pedido</button><button className="button button-hero-outline" onClick={() => setModal('import')}><ArrowDownToLine size={17} /> Importar itens</button></div></div><div className="hero-art" aria-hidden="true"><div className="orbit orbit-one" /><div className="orbit orbit-two" /><div className="floating-tile tile-one"><Package size={27} /></div><div className="floating-tile tile-two"><CheckCheck size={24} /></div><div className="floating-tile tile-three"><ShoppingBag size={31} /></div></div></section>
          <section className="metrics" aria-label="Resumo dos pedidos"><div className="metric"><span className="metric-icon metric-violet"><ShoppingBag size={22} /></span><div><small>Pedidos no total</small><strong>{orders.length}</strong></div></div><div className="metric"><span className="metric-icon metric-amber"><Clock3 size={22} /></span><div><small>Aguardando</small><strong>{counts.waiting}</strong></div></div><div className="metric"><span className="metric-icon metric-blue"><Package size={22} /></span><div><small>Em preparo</small><strong>{counts.preparing}</strong></div></div><div className="metric"><span className="metric-icon metric-green"><Wallet size={22} /></span><div><small>Finalizados</small><strong>{money(finishedTotal)}</strong></div></div></section>
          <section className="section-heading"><div><span className="section-kicker">QUADRO DE PEDIDOS</span><h2>Acompanhe cada etapa</h2><p>Movimente os cartões conforme o pedido avança.</p></div><div className="heading-controls"><label className="search-field"><Search size={18} /><input aria-label="Pesquisar pedidos" placeholder="Buscar pedido ou cliente" value={orderSearch} onChange={event => setOrderSearch(event.target.value)} /></label><button className="button button-secondary refresh-button" aria-label="Atualizar pedidos" title="Atualizar pedidos" onClick={() => setReload(value => value + 1)}><RefreshCw size={17} /></button><button className="button button-primary new-order-button" onClick={() => setModal('order')}><Plus size={18} /> Novo pedido</button></div></section>
          <nav className="mobile-stages" aria-label="Etapas dos pedidos">{statuses.map(status => <button key={status} aria-pressed={mobileStage === status} className={mobileStage === status ? `active stage-${status}` : `stage-${status}`} onClick={() => setMobileStage(status)}>{statusLabels[status]} <b>{counts[status]}</b></button>)}</nav>
          {loading ? <div className="loading-panel"><LoaderCircle className="spin" size={25} /><strong>Carregando pedidos e produtos...</strong>{slow && <span>A consulta está demorando. Aguarde mais um pouco.</span>}</div> : error ? <div className="error-panel"><strong>Não foi possível carregar os dados.</strong><p>{error}</p><div><button className="button button-secondary" onClick={() => setReload(value => value + 1)}><RefreshCw size={16} /> Tentar novamente</button><button className="button button-primary" onClick={() => setModal('import')}>Importar produtos</button></div></div> : <div className="board" aria-label="Pedidos por status">{statuses.map(status => <BoardColumn key={status} status={status} orders={filteredOrders.filter(order => order.status === status)} onStatus={updateStatus} busyId={busyId} now={now} mobileActive={mobileStage === status} />)}</div>}
        </> : <><section className="catalog-hero"><div><span className="section-kicker">SEU CATÁLOGO</span><h1>Produtos & preços</h1><p>Os itens importados do estoque ficam prontos para entrar nos pedidos.</p></div><button className="button button-primary" onClick={() => setModal('import')}><ArrowDownToLine size={18} /> Importar produtos</button></section>
          <div className="catalog-toolbar"><label className="search-field"><Search size={18} /><input aria-label="Pesquisar produtos" placeholder="Buscar por nome, código ou categoria" value={productSearch} onChange={event => setProductSearch(event.target.value)} /></label><span>{filteredProducts.length} produto{filteredProducts.length === 1 ? '' : 's'}</span></div>
          {loading ? <div className="loading-panel"><LoaderCircle className="spin" size={25} /> Carregando catálogo...</div> : error ? <div className="error-panel"><strong>Não foi possível carregar o catálogo.</strong><p>{error}</p><button className="button button-primary" onClick={() => setModal('import')}>Importar produtos</button></div> : filteredProducts.length ? <div className="catalog-grid">{filteredProducts.map(product => <CatalogCard key={product.id} product={product} onSave={savePrice} busy={busyId === product.id} />)}</div> : <div className="catalog-empty"><div><Package size={31} /></div><h2>{products.length ? 'Nenhum item encontrado' : 'Seu catálogo começa aqui'}</h2><p>{products.length ? 'Tente outro nome ou código.' : 'Importe itens do estoque e defina os preços que vão aparecer nos pedidos.'}</p><button className="button button-primary" onClick={() => setModal('import')}><ArrowDownToLine size={17} /> Importar produtos</button></div>}
        </>}
      </div>
    </main>
    {tab === 'orders' && <button className="mobile-create-order" onClick={() => setModal('order')}><Plus size={21} /> Criar pedido</button>}
    {toast && <div className="toast" role="status"><CheckCheck size={17} />{toast}</div>}
    {modal === 'order' && <OrderModal products={products} onClose={() => setModal(null)} onCreate={addOrder} onImport={() => setModal('import')} />}
    {modal === 'import' && <ImportModal stockId={stockId} stockName={stocks.find(stock => stock.id === stockId)?.name ?? 'atual'} currentProducts={products} onClose={() => setModal(null)} onImported={imported} />}
  </div>;
}
