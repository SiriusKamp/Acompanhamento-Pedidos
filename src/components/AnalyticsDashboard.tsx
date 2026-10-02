import { useDeferredValue, useEffect, useMemo, useState } from 'react';
import {
  AlertTriangle, ArrowDown, ArrowUp, BarChart3, Box, CheckCircle2, ChevronDown,
  CircleDollarSign, ClipboardList, Factory, LoaderCircle, Package, RefreshCw,
  Search, TrendingDown, TrendingUp, X,
} from 'lucide-react';
import type {
  AnalyticsFilters, AnalyticsOverview, InventoryHealth, OrderAnalytics, OrderAnalyticsDetail,
  ProductAnalytics, ProductRecommendation, ProductRank,
} from '../analytics';
import { getAnalyticsOrderDetail, getAnalyticsOrders, getAnalyticsOverview, getAnalyticsProducts, getInventoryHealth } from '../lib/analyticsApi';
import type { OrderBoard } from '../model';
import { money } from '../model';
import { supabase } from '../lib/supabase';
import { Modal } from './Modal';

type AnalyticsView = 'overview' | 'products' | 'orders';

const TZ = 'America/Sao_Paulo';

function dateKey(value = new Date()) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(value);
  const part = (type: string) => parts.find(item => item.type === type)?.value ?? '';
  return `${part('year')}-${part('month')}-${part('day')}`;
}

function shiftDate(key: string, days: number) {
  const value = new Date(`${key}T12:00:00Z`);
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
}

function toBoundary(key: string) {
  // São Paulo currently uses UTC-03:00. The database keeps all timestamps in UTC.
  return `${key}T00:00:00-03:00`;
}

function periodRange(period: AnalyticsFilters['period']) {
  const today = dateKey();
  if (period === 'today') return { from: toBoundary(today), to: toBoundary(shiftDate(today, 1)) };
  if (period === 'yesterday') return { from: toBoundary(shiftDate(today, -1)), to: toBoundary(today) };
  if (period === '7d') return { from: toBoundary(shiftDate(today, -6)), to: toBoundary(shiftDate(today, 1)) };
  if (period === 'month') return { from: toBoundary(`${today.slice(0, 7)}-01`), to: toBoundary(shiftDate(today, 1)) };
  return { from: toBoundary(shiftDate(today, -29)), to: toBoundary(shiftDate(today, 1)) };
}

function initialFilters(): AnalyticsFilters {
  const range = periodRange('30d');
  return { boardIds: [], period: '30d', ...range, productKind: 'all', search: '' };
}

function number(value: unknown) {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function percent(value: number | null | undefined) {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—';
  return `${new Intl.NumberFormat('pt-BR', { maximumFractionDigits: 1 }).format(value)}%`;
}

function compact(value: number) {
  return new Intl.NumberFormat('pt-BR', { notation: 'compact', maximumFractionDigits: 1 }).format(number(value));
}

function dateLabel(value: string | null | undefined, withTime = false) {
  if (!value) return '—';
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return '—';
  return new Intl.DateTimeFormat('pt-BR', {
    timeZone: TZ, day: '2-digit', month: 'short', year: withTime ? 'numeric' : undefined,
    ...(withTime ? { hour: '2-digit', minute: '2-digit' } : {}),
  }).format(parsed);
}

function dateInput(value: string) {
  return value.slice(0, 10);
}

function difference(current: number, previous: number) {
  if (!previous) return null;
  return (current - previous) / Math.abs(previous) * 100;
}

function quartile(values: number[], factor: number) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * factor))] ?? 0;
}

function recommendation(
  product: ProductAnalytics, periodDays: number, targetMargin: number, targetCoverage: number,
  demandMedian: number, demandLow: number,
): ProductRecommendation {
  if (!product.costComplete || periodDays < 7 || product.orders < 3) {
    return { kind: 'incomplete', title: 'Dados insuficientes', reason: 'São necessários ao menos 7 dias, 3 pedidos e custo FIFO completo.' };
  }
  const margin = product.margin ?? 0;
  const coverage = product.coverageDays;
  const coverageText = coverage === null ? 'sem consumo no período' : `${coverage.toLocaleString('pt-BR', { maximumFractionDigits: 1 })} dia(s) de cobertura`;
  if (product.isKit && product.dailyVelocity > 0 && coverage !== null && coverage < targetCoverage && margin >= targetMargin) {
    return {
      kind: 'produce', title: 'Priorizar produção',
      suggestedQuantity: Math.max(0, Math.ceil(product.dailyVelocity * (targetCoverage + 1) - product.stockWholeUnits)),
      reason: `${product.quantity} un vendidas, margem de ${percent(margin)} e ${coverageText}.`,
    };
  }
  if (product.dailyVelocity >= demandMedian && coverage !== null && coverage < 1) {
    return { kind: 'avoid-stockout', title: 'Evitar ruptura', reason: `${product.quantity} un vendidas e apenas ${coverageText}.` };
  }
  if (product.dailyVelocity >= demandMedian && margin < targetMargin) {
    return { kind: 'review-price', title: 'Revisar preço/custo', reason: `Boa saída, mas margem de ${percent(margin)} abaixo da meta de ${percent(targetMargin)}.` };
  }
  if (product.dailyVelocity < demandMedian && margin >= targetMargin && (coverage === null || coverage >= targetCoverage)) {
    return { kind: 'promote', title: 'Promover', reason: `Margem de ${percent(margin)}, estoque disponível e procura abaixo da mediana.` };
  }
  if (product.dailyVelocity <= demandLow && margin < targetMargin) {
    return { kind: 'review-menu', title: 'Reavaliar cardápio', reason: `Baixa demanda e margem de ${percent(margin)}. Avalie preço, posição ou permanência.` };
  }
  return { kind: 'healthy', title: 'Saudável', reason: `Margem de ${percent(margin)} e cobertura de ${coverageText}.` };
}

function MetricCard({ label, value, previous, moneyValue = false, detail, icon: Icon }: {
  label: string; value: number; previous: number; moneyValue?: boolean; detail?: string; icon: typeof TrendingUp;
}) {
  const change = difference(value, previous);
  return <article className="analytics-metric-card">
    <span className="analytics-metric-icon"><Icon size={20} /></span>
    <span>{label}</span>
    <strong>{moneyValue ? money(value) : compact(value)}</strong>
    <small className={change === null ? '' : change >= 0 ? 'positive' : 'negative'}>
      {change === null ? 'Sem base anterior' : <>{change >= 0 ? <ArrowUp size={12} /> : <ArrowDown size={12} />}{percent(Math.abs(change))} vs. período anterior</>}
    </small>
    {detail && <em>{detail}</em>}
  </article>;
}

function FinancialTrend({ points }: { points: AnalyticsOverview['series'] }) {
  if (!points.length) return <div className="analytics-empty-chart">Sem pedidos finalizados neste período.</div>;
  const width = 760; const height = 220; const top = 22; const bottom = 37; const left = 5; const right = 7;
  const maximum = Math.max(1, ...points.flatMap(point => [number(point.revenue), number(point.cost), number(point.profit)]));
  const step = (width - left - right) / Math.max(1, points.length);
  const y = (value: number) => top + (height - top - bottom) * (1 - Math.max(0, value) / maximum);
  const line = points.map((point, index) => `${left + step * index + step / 2},${y(number(point.profit))}`).join(' ');
  const labels = points.filter((_, index) => index === 0 || index === points.length - 1 || index % Math.ceil(points.length / 5) === 0);
  return <div className="analytics-chart-wrap">
    <div className="analytics-legend"><span><i className="legend-revenue" /> Receita</span><span><i className="legend-cost" /> CMV</span><span><i className="legend-profit" /> Lucro</span></div>
    <svg className="analytics-trend" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Receita, custo e lucro por dia">
      {[.25, .5, .75, 1].map(level => <line key={level} x1={left} x2={width - right} y1={y(maximum * level)} y2={y(maximum * level)} className="analytics-grid-line" />)}
      {points.map((point, index) => {
        const x = left + step * index + step * .15; const barWidth = Math.max(2, step * .28);
        const revenueY = y(number(point.revenue)); const costY = y(number(point.cost));
        return <g key={point.date}><title>{`${dateLabel(point.date)}: receita ${money(number(point.revenue))}, CMV ${money(number(point.cost))}, lucro ${money(number(point.profit))}`}</title>
          <rect x={x} y={revenueY} width={barWidth} height={height - bottom - revenueY} rx="2" className="analytics-bar-revenue" />
          <rect x={x + barWidth + 2} y={costY} width={barWidth} height={height - bottom - costY} rx="2" className="analytics-bar-cost" />
        </g>;
      })}
      <polyline points={line} fill="none" className="analytics-profit-line" />
      {labels.map(point => {
        const index = points.indexOf(point); return <text key={point.date} x={left + step * index + step / 2} y={height - 13} textAnchor="middle" className="analytics-axis-label">{dateLabel(point.date)}</text>;
      })}
    </svg>
  </div>;
}

function RankList({ title, rows, value }: { title: string; rows: ProductRank[]; value: (row: ProductRank) => string }) {
  return <section className="analytics-rank-card"><h3>{title}</h3>{rows.length ? <ol>{rows.map((row, index) => <li key={row.productId}><b>{index + 1}</b><div><strong>{row.name}</strong><small>{row.code || 'Sem código'}</small></div><span>{value(row)}</span></li>)}</ol> : <p>Nenhuma venda no período.</p>}</section>;
}

function AnalyticsFiltersBar({ filters, boards, onChange, targetMargin, setTargetMargin, targetCoverage, setTargetCoverage }: {
  filters: AnalyticsFilters; boards: OrderBoard[]; onChange: (next: AnalyticsFilters) => void;
  targetMargin: number; setTargetMargin: (value: number) => void; targetCoverage: number; setTargetCoverage: (value: number) => void;
}) {
  function setPeriod(period: AnalyticsFilters['period']) {
    if (period === 'custom') { onChange({ ...filters, period }); return; }
    onChange({ ...filters, period, ...periodRange(period) });
  }
  function toggleBoard(id: string) {
    onChange({ ...filters, boardIds: filters.boardIds.includes(id) ? filters.boardIds.filter(value => value !== id) : [...filters.boardIds, id] });
  }
  return <section className="analytics-filters">
    <label className="analytics-filter"><span>Período</span><select value={filters.period} onChange={event => setPeriod(event.target.value as AnalyticsFilters['period'])}>
      <option value="today">Hoje</option><option value="yesterday">Ontem</option><option value="7d">Últimos 7 dias</option><option value="30d">Últimos 30 dias</option><option value="month">Mês atual</option><option value="custom">Personalizado</option>
    </select></label>
    {filters.period === 'custom' && <><label className="analytics-filter"><span>De</span><input type="date" value={dateInput(filters.from)} onChange={event => onChange({ ...filters, from: toBoundary(event.target.value) })} /></label><label className="analytics-filter"><span>Até</span><input type="date" value={dateInput(filters.to)} onChange={event => onChange({ ...filters, to: toBoundary(shiftDate(event.target.value, 1)) })} /></label></>}
    <details className="analytics-board-filter"><summary>Kanbans <strong>{filters.boardIds.length ? filters.boardIds.length : 'Todos'}</strong><ChevronDown size={15} /></summary><div>
      <label><input type="checkbox" checked={!filters.boardIds.length} onChange={() => onChange({ ...filters, boardIds: [] })} /> Todos os kanbans</label>
      {boards.map(board => <label key={board.id}><input type="checkbox" checked={filters.boardIds.includes(board.id)} onChange={() => toggleBoard(board.id)} /> {board.name}</label>)}
    </div></details>
    <details className="analytics-board-filter analytics-settings"><summary>Metas <ChevronDown size={15} /></summary><div>
      <label>Margem mínima <select value={targetMargin} onChange={event => setTargetMargin(Number(event.target.value))}>{[10, 15, 20, 25, 30, 40].map(value => <option key={value} value={value}>{value}%</option>)}</select></label>
      <label>Cobertura alvo <select value={targetCoverage} onChange={event => setTargetCoverage(Number(event.target.value))}>{[3, 7, 14, 30].map(value => <option key={value} value={value}>{value} dias</option>)}</select></label>
    </div></details>
  </section>;
}

function QualityNotice({ overview }: { overview: AnalyticsOverview }) {
  const { quality, summary } = overview;
  if (quality.coveragePercent >= 100) return <div className="analytics-quality good"><CheckCircle2 size={18} /> Custos registrados em todos os {quality.finishedOrders} pedidos finalizados.</div>;
  return <div className="analytics-quality warn"><AlertTriangle size={18} /><div><strong>Custos incompletos em {quality.finishedOrders - quality.costCompleteOrders} pedido(s).</strong><span>Lucro e margem consideram {money(summary.costedRevenue)} de receita com custo completo registrado.</span></div></div>;
}

function InventoryNotice({ health }: { health: InventoryHealth }) {
  if (!health.finishedOrders) return null;
  if (!health.pendingItems && !health.missingCostItems) return <div className="analytics-quality good"><CheckCircle2 size={18} /> Baixas de estoque concluídas em todos os pedidos deste período.</div>;
  const pendingOrders = health.partialOrders + health.pendingOrders;
  return <div className="analytics-quality warn"><AlertTriangle size={18} /><div><strong>{health.pendingItems} item(ns) de {pendingOrders} pedido(s) precisam de conferência de estoque.</strong><span>{health.manualCostItems ? `${health.manualCostItems} item(ns) usam custo unitário informado. ` : ''}{health.missingCostItems ? `${health.missingCostItems} item(ns) ainda estão sem custo.` : 'A venda foi finalizada normalmente; regularize o estoque quando possível.'}</span>{health.alerts.length ? <span className="inventory-alert-products">Pendentes: {health.alerts.map(alert => `${alert.productName} (${alert.quantity} ${alert.unit} pendentes${alert.settledQuantity ? `, ${alert.settledQuantity} baixadas` : ''})`).join(' · ')}</span> : null}</div></div>;
}

function ProductTable({ products, periodDays, targetMargin, targetCoverage, onSelect }: {
  products: ProductAnalytics[]; periodDays: number; targetMargin: number; targetCoverage: number; onSelect: (product: ProductAnalytics) => void;
}) {
  const demand = products.map(product => product.dailyVelocity);
  const median = quartile(demand, .5); const low = quartile(demand, .25);
  return <div className="analytics-table-scroll"><table className="analytics-table product-table"><thead><tr><th>Produto</th><th>Saída</th><th>Receita</th><th>CMV</th><th>Lucro</th><th>Margem</th><th>Estoque / cobertura</th><th>Decisão</th></tr></thead><tbody>
    {products.map(product => {
      const insight = recommendation(product, periodDays, targetMargin, targetCoverage, median, low);
      return <tr key={product.productId} onClick={() => onSelect(product)} tabIndex={0} onKeyDown={event => { if (event.key === 'Enter') onSelect(product); }}>
        <td><strong>{product.name}</strong><small>{product.code || 'Sem código'} · {product.isKit ? 'Kit' : 'Produto'} · {product.orders} pedido(s)</small></td>
        <td><strong>{compact(product.quantity)} un</strong><small>{compact(product.dailyVelocity)}/dia</small></td><td>{money(product.revenue)}</td><td>{product.costComplete ? money(product.cost ?? 0) : '—'}</td><td className={(product.profit ?? 0) < 0 ? 'negative-text' : 'positive-text'}>{product.costComplete ? money(product.profit ?? 0) : '—'}</td><td>{product.costComplete ? percent(product.margin) : 'Incompleto'}</td><td><strong>{compact(product.stockWholeUnits)} un</strong><small>{product.coverageDays === null ? 'Sem consumo' : `${number(product.coverageDays).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} dias`}</small></td><td><span className={`analytics-recommendation ${insight.kind}`}>{insight.title}</span><small>{insight.suggestedQuantity ? `Produzir +${insight.suggestedQuantity} un` : insight.reason}</small></td>
      </tr>;
    })}
  </tbody></table>{!products.length && <div className="analytics-empty-chart">Nenhum produto finalizado corresponde aos filtros.</div>}</div>;
}

function ProductQuadrant({ products, periodDays, targetMargin, targetCoverage, onSelect }: {
  products: ProductAnalytics[]; periodDays: number; targetMargin: number; targetCoverage: number; onSelect: (product: ProductAnalytics) => void;
}) {
  const visible = products.filter(product => product.costComplete).slice(0, 45);
  const maxDemand = Math.max(1, ...visible.map(product => product.quantity));
  const maxRevenue = Math.max(1, ...visible.map(product => product.revenue));
  const demand = visible.map(product => product.dailyVelocity); const median = quartile(demand, .5); const low = quartile(demand, .25);
  return <section className="analytics-quadrant-card"><div className="analytics-card-heading"><div><span>MAPA DE DECISÃO</span><h3>Demanda × margem</h3></div><small>Bolha = receita</small></div><div className="analytics-quadrant"><i className="quadrant-horizontal" /><i className="quadrant-vertical" /><b className="quadrant-label q-top-left">Promover</b><b className="quadrant-label q-top-right">Priorizar produção</b><b className="quadrant-label q-bottom-left">Reavaliar</b><b className="quadrant-label q-bottom-right">Revisar preço</b>{visible.map(product => {
    const insight = recommendation(product, periodDays, targetMargin, targetCoverage, median, low);
    const left = 5 + product.quantity / maxDemand * 89; const bottom = 6 + Math.min(88, Math.max(0, (product.margin ?? 0) / Math.max(1, targetMargin * 2) * 50 + 25));
    const size = 23 + product.revenue / maxRevenue * 24;
    return <button key={product.productId} className={`quadrant-bubble ${insight.kind}`} style={{ left: `${left}%`, bottom: `${bottom}%`, width: size, height: size }} onClick={() => onSelect(product)} title={`${product.name}: ${insight.title}`}><span>{product.name.slice(0, 2).toUpperCase()}</span></button>;
  })}</div></section>;
}

function ProductFocus({ product, insight, onClose }: { product: ProductAnalytics; insight: ProductRecommendation; onClose: () => void }) {
  return <aside className="product-focus"><button className="icon-button" onClick={onClose} aria-label="Fechar detalhes"><X size={17} /></button><span className={`analytics-recommendation ${insight.kind}`}>{insight.title}</span><h3>{product.name}</h3><p>{insight.reason}</p><div className="product-focus-grid"><div><span>Lucro</span><strong>{product.costComplete ? money(product.profit ?? 0) : '—'}</strong></div><div><span>Margem</span><strong>{product.costComplete ? percent(product.margin) : '—'}</strong></div><div><span>Receita</span><strong>{money(product.revenue)}</strong></div><div><span>Quantidade</span><strong>{compact(product.quantity)} un</strong></div><div><span>Estoque</span><strong>{compact(product.stockWholeUnits)} un</strong></div><div><span>Última venda</span><strong>{dateLabel(product.lastSaleAt)}</strong></div></div>{insight.suggestedQuantity ? <div className="product-production-call"><Factory size={19} /><div><b>Produção sugerida</b><span>+{insight.suggestedQuantity} unidade(s) para atingir a cobertura alvo.</span></div></div> : null}</aside>;
}

function OrdersTable({ orders, onOpen }: { orders: OrderAnalytics[]; onOpen: (order: OrderAnalytics) => void }) {
  return <div className="analytics-table-scroll"><table className="analytics-table orders-table"><thead><tr><th>Pedido</th><th>Kanban</th><th>Finalizado</th><th>Receita</th><th>CMV</th><th>Lucro</th><th>Margem</th></tr></thead><tbody>{orders.map(order => <tr key={order.orderId} onClick={() => onOpen(order)} tabIndex={0} onKeyDown={event => { if (event.key === 'Enter') onOpen(order); }}><td><strong>#{String(order.number).padStart(4, '0')}</strong><small>{order.customer || 'Cliente sem nome'} · {order.itemQuantity} item(ns)</small></td><td>{order.boardName}</td><td>{dateLabel(order.finishedAt, true)}</td><td>{money(order.revenue)}</td><td>{order.costComplete ? money(order.cost ?? 0) : '—'}</td><td className={(order.profit ?? 0) < 0 ? 'negative-text' : 'positive-text'}>{order.costComplete ? money(order.profit ?? 0) : '—'}</td><td>{order.costComplete ? percent(order.margin) : 'Incompleto'}</td></tr>)}</tbody></table>{!orders.length && <div className="analytics-empty-chart">Nenhum pedido finalizado corresponde aos filtros.</div>}</div>;
}

function OrderDetailModal({ stockId, order, onClose }: { stockId: string; order: OrderAnalytics; onClose: () => void }) {
  const [detail, setDetail] = useState<OrderAnalyticsDetail | null>(null);
  const [error, setError] = useState('');
  useEffect(() => { let active = true; void getAnalyticsOrderDetail(stockId, order.orderId).then(value => { if (active) setDetail(value); }).catch(reason => { if (active) setError(reason instanceof Error ? reason.message : 'Não foi possível abrir o pedido.'); }); return () => { active = false; }; }, [order.orderId, stockId]);
  return <Modal title={`Pedido #${String(order.number).padStart(4, '0')}`} subtitle={`${order.boardName} · ${dateLabel(order.finishedAt, true)}`} onClose={onClose} wide>
    {error ? <p className="form-error">{error}</p> : !detail ? <div className="analytics-modal-loading"><LoaderCircle className="spin" size={22} /> Carregando custo registrado...</div> : <div className="order-analysis-detail"><div className="order-analysis-totals"><div><span>Receita</span><strong>{money(detail.order.revenue)}</strong></div><div><span>CMV</span><strong>{detail.order.costComplete ? money(detail.order.cost ?? 0) : '—'}</strong></div><div><span>Lucro bruto</span><strong>{detail.order.costComplete ? money(detail.order.profit ?? 0) : '—'}</strong></div><div><span>Margem</span><strong>{detail.order.costComplete ? percent(detail.order.margin) : 'Incompleta'}</strong></div></div><div className="order-analysis-lines">{detail.items.map((item, index) => <article key={`${item.productId}-${index}`}><div><span>{item.quantity}×</span><strong>{item.name}</strong><small>{item.code || 'Sem código'} · preço registrado {money(item.unitPrice)}</small></div><div className="order-analysis-line-values"><span>Receita {money(item.revenue)}</span><span>CMV {item.costComplete ? money(item.cost ?? 0) : '—'}</span><b>Lucro {item.costComplete ? money(item.profit ?? 0) : '—'}</b></div>{item.lots.length ? <small className="order-analysis-lots">Lotes FIFO: {item.lots.map(lot => `${lot.productName} · ${lot.code} (${money(lot.cost)})`).join(' · ')}</small> : <small className="order-analysis-lots">Sem lote rastreável</small>}</article>)}</div></div>}
  </Modal>;
}

export function AnalyticsDashboard({ stockId, boards }: { stockId: string; boards: OrderBoard[] }) {
  const [view, setView] = useState<AnalyticsView>('overview');
  const [filters, setFilters] = useState<AnalyticsFilters>(() => initialFilters());
  const [overview, setOverview] = useState<AnalyticsOverview | null>(null);
  const [inventoryHealth, setInventoryHealth] = useState<InventoryHealth | null>(null);
  const [products, setProducts] = useState<ProductAnalytics[]>([]);
  const [productPeriodDays, setProductPeriodDays] = useState(0);
  const [orders, setOrders] = useState<OrderAnalytics[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [refreshKey, setRefreshKey] = useState(0);
  const [lastRefresh, setLastRefresh] = useState<Date | null>(null);
  const [selectedProduct, setSelectedProduct] = useState<ProductAnalytics | null>(null);
  const [selectedOrder, setSelectedOrder] = useState<OrderAnalytics | null>(null);
  const [targetMargin, setTargetMargin] = useState(() => Number(localStorage.getItem('analytics-target-margin') ?? 20));
  const [targetCoverage, setTargetCoverage] = useState(() => Number(localStorage.getItem('analytics-target-coverage') ?? 7));
  const deferredSearch = useDeferredValue(filters.search);

  useEffect(() => { localStorage.setItem('analytics-target-margin', String(targetMargin)); }, [targetMargin]);
  useEffect(() => { localStorage.setItem('analytics-target-coverage', String(targetCoverage)); }, [targetCoverage]);
  useEffect(() => { setSelectedProduct(null); setSelectedOrder(null); }, [stockId]);

  useEffect(() => {
    let active = true;
    const queryFilters = { ...filters, search: deferredSearch };
    setLoading(true); setError('');
    void Promise.all([
      getAnalyticsOverview(stockId, queryFilters),
      getAnalyticsProducts(stockId, queryFilters, 'profit', 'desc'),
      getAnalyticsOrders(stockId, queryFilters),
      getInventoryHealth(stockId, queryFilters),
    ]).then(([nextOverview, nextProducts, nextOrders, nextInventoryHealth]) => {
      if (!active) return;
      setOverview(nextOverview); setInventoryHealth(nextInventoryHealth); setProducts(nextProducts.rows); setProductPeriodDays(nextProducts.periodDays); setOrders(nextOrders.rows); setLastRefresh(new Date());
    }).catch(reason => { if (active) setError(reason instanceof Error ? reason.message : 'Não foi possível consultar as análises.'); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [stockId, filters.boardIds.join(','), filters.from, filters.to, filters.productKind, deferredSearch, refreshKey]);

  useEffect(() => {
    let timer: number | undefined;
    const refreshSoon = () => { window.clearTimeout(timer); timer = window.setTimeout(() => setRefreshKey(value => value + 1), 850); };
    const channel = supabase.channel(`analytics-${stockId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'order_sales', filter: `stock_id=eq.${stockId}` }, refreshSoon)
      .subscribe();
    const interval = window.setInterval(() => { if (!document.hidden) setRefreshKey(value => value + 1); }, 60_000);
    return () => { window.clearTimeout(timer); window.clearInterval(interval); void supabase.removeChannel(channel); };
  }, [stockId]);

  const demand = products.map(product => product.dailyVelocity);
  const demandMedian = quartile(demand, .5); const demandLow = quartile(demand, .25);
  const selectedInsight = selectedProduct ? recommendation(selectedProduct, productPeriodDays, targetMargin, targetCoverage, demandMedian, demandLow) : null;
  const insights = useMemo(() => products.map(product => ({ product, insight: recommendation(product, productPeriodDays, targetMargin, targetCoverage, demandMedian, demandLow) }))
    .filter(value => !['healthy', 'incomplete'].includes(value.insight.kind))
    .sort((a, b) => (b.product.profit ?? -Infinity) - (a.product.profit ?? -Infinity)).slice(0, 6), [products, productPeriodDays, targetMargin, targetCoverage, demandMedian, demandLow]);

  return <section className="analytics-page">
    <header className="analytics-hero"><div><span className="section-kicker">ANÁLISE E DECISÃO</span><h1>Vendas que viram<br /><em>decisões melhores.</em></h1><p>Receita, custo FIFO e margem por pedido, kanban e produto.</p></div><div className="analytics-hero-icon"><BarChart3 size={42} /></div></header>
    <AnalyticsFiltersBar filters={filters} boards={boards} onChange={setFilters} targetMargin={targetMargin} setTargetMargin={setTargetMargin} targetCoverage={targetCoverage} setTargetCoverage={setTargetCoverage} />
    <div className="analytics-tabs"><button className={view === 'overview' ? 'active' : ''} onClick={() => setView('overview')}><BarChart3 size={16} /> Visão geral</button><button className={view === 'products' ? 'active' : ''} onClick={() => setView('products')}><Package size={16} /> Produtos</button><button className={view === 'orders' ? 'active' : ''} onClick={() => setView('orders')}><ClipboardList size={16} /> Pedidos</button><button className="analytics-refresh" onClick={() => setRefreshKey(value => value + 1)} disabled={loading}><RefreshCw size={16} className={loading ? 'spin' : ''} /> Atualizar</button></div>
    {lastRefresh && <p className="analytics-refreshed">Atualizado às {lastRefresh.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}. Atualização automática ativa.</p>}
    {loading && !overview ? <div className="loading-panel analytics-loading"><LoaderCircle className="spin" size={25} /><strong>Calculando receita, custo FIFO e lucro...</strong></div> : error ? <div className="error-panel analytics-error"><strong>Não foi possível carregar o dashboard.</strong><p>{error}</p><button className="button button-primary" onClick={() => setRefreshKey(value => value + 1)}><RefreshCw size={16} /> Tentar novamente</button></div> : overview ? <>
      <QualityNotice overview={overview} />
      {inventoryHealth && <InventoryNotice health={inventoryHealth} />}
      {view === 'overview' && <><div className="analytics-metrics"><MetricCard label="Pedidos finalizados" value={overview.summary.orders} previous={overview.previous.orders} icon={ClipboardList} /><MetricCard label="Receita realizada" value={overview.summary.revenue} previous={overview.previous.revenue} moneyValue icon={CircleDollarSign} /><MetricCard label="CMV FIFO" value={overview.summary.cost} previous={overview.previous.cost} moneyValue detail={overview.quality.coveragePercent < 100 ? `${percent(overview.quality.coveragePercent)} com custo completo` : undefined} icon={Box} /><MetricCard label="Lucro bruto" value={overview.summary.profit} previous={overview.previous.profit} moneyValue icon={TrendingUp} /><MetricCard label="Margem bruta" value={overview.summary.margin} previous={overview.previous.margin} detail={`Markup ${percent(overview.summary.markup)}`} icon={TrendingDown} /><MetricCard label="Ticket médio" value={overview.summary.averageTicket} previous={overview.previous.averageTicket} moneyValue detail={overview.summary.openPotential ? `${money(overview.summary.openPotential)} em aberto` : 'Nenhum pedido aberto no período'} icon={Package} /></div>
        <div className="analytics-grid-main"><section className="analytics-card analytics-trend-card"><div className="analytics-card-heading"><div><span>RESULTADO NO TEMPO</span><h3>Receita, CMV e lucro por dia</h3></div><small>{filters.boardIds.length ? `${filters.boardIds.length} kanban(s)` : 'Todos os kanbans'}</small></div><FinancialTrend points={overview.series} /></section><section className="analytics-card analytics-insights-card"><div className="analytics-card-heading"><div><span>PRÓXIMAS AÇÕES</span><h3>O que merece atenção</h3></div></div>{insights.length ? <div className="analytics-insights">{insights.map(({ product, insight }) => <button key={product.productId} className={`analytics-insight ${insight.kind}`} onClick={() => setSelectedProduct(product)}><span>{insight.kind === 'produce' ? <Factory size={17} /> : insight.kind === 'avoid-stockout' ? <AlertTriangle size={17} /> : insight.kind === 'review-price' ? <CircleDollarSign size={17} /> : <TrendingUp size={17} />}</span><div><b>{insight.title} · {product.name}</b><small>{insight.reason}</small></div></button>)}</div> : <div className="analytics-empty-chart">Não há alertas com dados suficientes neste período.</div>}</section></div>
        <div className="analytics-grid-secondary"><section className="analytics-card analytics-boards-card"><div className="analytics-card-heading"><div><span>COMPARAÇÃO</span><h3>Resultado por kanban</h3></div></div><div className="analytics-board-list">{overview.boards.length ? overview.boards.map(board => <button key={board.id} onClick={() => setFilters(current => ({ ...current, boardIds: [board.id] }))}><div><strong>{board.name}</strong><small>{board.orders} pedido(s) · margem {percent(board.margin)}</small></div><span>{money(board.profit)}</span><i style={{ width: `${Math.min(100, board.revenue / Math.max(1, ...overview.boards.map(item => item.revenue)) * 100)}%` }} /></button>) : <p>Nenhum kanban com pedidos finalizados.</p>}</div></section><section className="analytics-card analytics-pareto-card"><div className="analytics-card-heading"><div><span>CONTRIBUIÇÃO</span><h3>Pareto do lucro</h3></div><small>Acumulado</small></div>{overview.pareto.length ? <div className="analytics-pareto">{overview.pareto.slice(0, 7).map(point => <div key={point.productId}><div><span>{point.name}</span><b>{money(point.profit)}</b></div><i><em style={{ width: `${Math.min(100, point.accumulatedPercent)}%` }} /></i><small>{percent(point.accumulatedPercent)}</small></div>)}</div> : <div className="analytics-empty-chart">Sem lucro rastreável no período.</div>}</section></div>
        <div className="analytics-ranking-grid"><RankList title="Mais vendidos" rows={overview.rankings.byQuantity} value={row => `${compact(row.quantity)} un`} /><RankList title="Maior receita" rows={overview.rankings.byRevenue} value={row => money(row.revenue)} /><RankList title="Maior lucro" rows={overview.rankings.byProfit} value={row => money(row.profit)} /></div>
      </>}
      {view === 'products' && <><section className="analytics-products-toolbar"><label className="search-field"><Search size={18} /><input aria-label="Buscar produto na análise" placeholder="Buscar por nome ou código" value={filters.search} onChange={event => setFilters(current => ({ ...current, search: event.target.value }))} /></label><label className="analytics-filter"><span>Mostrar</span><select value={filters.productKind} onChange={event => setFilters(current => ({ ...current, productKind: event.target.value as AnalyticsFilters['productKind'] }))}><option value="all">Produtos e kits</option><option value="product">Produtos</option><option value="kit">Kits</option></select></label><span>{products.length} produto(s) com venda finalizada</span></section><div className="analytics-product-map"><ProductQuadrant products={products} periodDays={productPeriodDays} targetMargin={targetMargin} targetCoverage={targetCoverage} onSelect={setSelectedProduct} /></div><section className="analytics-card"><div className="analytics-card-heading"><div><span>RENTABILIDADE POR PRODUTO</span><h3>Decisões baseadas em saída, lucro e cobertura</h3></div><small>Clique em uma linha para ver o resumo</small></div><ProductTable products={products} periodDays={productPeriodDays} targetMargin={targetMargin} targetCoverage={targetCoverage} onSelect={setSelectedProduct} /></section></>}
      {view === 'orders' && <section className="analytics-card"><div className="analytics-card-heading"><div><span>AUDITORIA FINANCEIRA</span><h3>Lucro por pedido finalizado</h3></div><small>{orders.length} pedido(s) mais recentes</small></div><OrdersTable orders={orders} onOpen={setSelectedOrder} /></section>}
    </> : null}
    {selectedProduct && selectedInsight && <ProductFocus product={selectedProduct} insight={selectedInsight} onClose={() => setSelectedProduct(null)} />}
    {selectedOrder && <OrderDetailModal stockId={stockId} order={selectedOrder} onClose={() => setSelectedOrder(null)} />}
  </section>;
}
