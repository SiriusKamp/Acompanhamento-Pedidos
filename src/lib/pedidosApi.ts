import type { Order, OrderStatus, Product } from '../model';

// In development, Vite proxies /api to localhost:8086. Production sets the public API origin.
const origin = import.meta.env.VITE_PEDIDOS_API_URL?.trim().replace(/\/+$/, '') ?? '';
const SESSION_KEY = 'pedidos-stock-session';

export interface Stock { id: string; name: string }
export interface StockConnection { connectionId: string; stocks: Stock[] }
export interface StockProduct {
  sourceProductId: string;
  name: string;
  code: string;
  category: string;
  isKit: boolean;
  suggestedPrice: number | null;
}
interface Page<T> { rows: T[]; total: number; page: number; size: number }
export interface NewOrder {
  customer: string;
  note: string;
  items: Array<{ productId: string; quantity: number }>;
  finalTotal: number;
  paid: number;
}

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${origin}/api/v1${path}`, {
      ...options,
      headers: { Accept: 'application/json', ...(options.body ? { 'Content-Type': 'application/json' } : {}),
        ...(sessionStorage.getItem(SESSION_KEY) ? { 'X-Orders-Session': sessionStorage.getItem(SESSION_KEY)! } : {}),
        ...options.headers },
    });
  } catch {
    throw new Error('A API de pedidos não respondeu. Verifique se ela está rodando na porta 8086.');
  }
  if (!response.ok) {
    if (response.status === 401) sessionStorage.removeItem(SESSION_KEY);
    const problem = await response.json().catch(() => null) as { detail?: string; message?: string; title?: string } | null;
    throw new Error(problem?.detail || problem?.message || problem?.title || `Erro HTTP ${response.status}.`);
  }
  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}

export const getProducts = () => request<Product[]>('/products');
export const updateProductPrice = (id: string, price: number) =>
  request<Product>(`/products/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify({ price }) });
export const getOrders = () => request<Order[]>('/orders');
export const createOrder = (order: NewOrder) =>
  request<Order>('/orders', { method: 'POST', body: JSON.stringify(order) });
export const changeOrderStatus = (id: string, status: OrderStatus) =>
  request<Order>(`/orders/${encodeURIComponent(id)}/status`, { method: 'PATCH', body: JSON.stringify({ status }) });

export async function connectStock(email: string, password: string): Promise<StockConnection> {
  const connection = await request<StockConnection>('/stock/connections', {
    method: 'POST', body: JSON.stringify({ email: email.trim(), password }),
  });
  sessionStorage.setItem(SESSION_KEY, connection.connectionId);
  return connection;
}

export async function getStockProducts(connectionId: string, stockId: string): Promise<StockProduct[]> {
  const rows: StockProduct[] = [];
  for (let page = 0; ; page++) {
    const query = new URLSearchParams({ page: String(page), size: '100' });
    const result = await request<Page<StockProduct>>(
      `/stock/connections/${encodeURIComponent(connectionId)}/stocks/${encodeURIComponent(stockId)}/products?${query}`,
    );
    if (!Array.isArray(result.rows) || !Number.isFinite(result.total)) throw new Error('Resposta inválida ao consultar o estoque.');
    rows.push(...result.rows);
    if (rows.length >= result.total || result.rows.length === 0) return rows;
  }
}

export const importProducts = (connectionId: string, stockId: string, items: Array<{ sourceProductId: string; price: number }>) =>
  request<Product[]>('/products/import', {
    method: 'POST', body: JSON.stringify({ connectionId, stockId, items }),
  });

export const apiOrigin = origin || 'http://localhost:8086 (proxy do Vite)';
