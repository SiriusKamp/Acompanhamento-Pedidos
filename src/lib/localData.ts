import type { Order, Product } from '../model';

const PRODUCTS_KEY = 'fluxo-products-v1';
const ORDERS_KEY = 'fluxo-orders-v1';

function readArray<T>(key: string, valid: (value: unknown) => value is T): T[] {
  try {
    const stored = JSON.parse(localStorage.getItem(key) ?? '[]') as unknown;
    return Array.isArray(stored) ? stored.filter(valid) : [];
  } catch { return []; }
}

function isProduct(value: unknown): value is Product {
  if (!value || typeof value !== 'object') return false;
  const product = value as Partial<Product>;
  return typeof product.id === 'string' && typeof product.name === 'string'
    && typeof product.price === 'number' && Number.isFinite(product.price);
}

function isOrder(value: unknown): value is Order {
  if (!value || typeof value !== 'object') return false;
  const order = value as Partial<Order>;
  return typeof order.id === 'string' && typeof order.number === 'number'
    && Array.isArray(order.items) && typeof order.finalTotal === 'number'
    && ['waiting', 'preparing', 'finished', 'cancelled'].includes(order.status ?? '');
}

export const readProducts = () => readArray(PRODUCTS_KEY, isProduct);
export const readOrders = () => readArray(ORDERS_KEY, isOrder);
export const saveProducts = (products: Product[]) => localStorage.setItem(PRODUCTS_KEY, JSON.stringify(products));
export const saveOrders = (orders: Order[]) => localStorage.setItem(ORDERS_KEY, JSON.stringify(orders));
