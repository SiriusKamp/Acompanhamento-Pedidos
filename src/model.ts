export type OrderStatus = 'waiting' | 'preparing' | 'finished' | 'cancelled';

export interface Product {
  id: string;
  sourceProductId: string | null;
  sourceStockId: string | null;
  name: string;
  code: string;
  category: string;
  isKit: boolean;
  suggestedPrice: number | null;
  price: number;
  importedAt: string;
}

export interface OrderItem {
  productId: string;
  name: string;
  quantity: number;
  unitPrice: number;
}

export interface Order {
  id: string;
  number: number;
  customer: string;
  note: string;
  items: OrderItem[];
  suggestedTotal: number;
  finalTotal: number;
  paid: number;
  status: OrderStatus;
  createdAt: string;
  updatedAt: string;
}

export const statusLabels: Record<OrderStatus, string> = {
  waiting: 'Aguardando',
  preparing: 'Preparando',
  finished: 'Finalizados',
  cancelled: 'Cancelados',
};

export function uid() {
  return globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

export const money = (value: number) => new Intl.NumberFormat('pt-BR', {
  style: 'currency', currency: 'BRL',
}).format(Number.isFinite(value) ? value : 0);

export function parseAmount(value: string): number {
  const parsed = Number(value.trim().replace(',', '.'));
  return Number.isFinite(parsed) && parsed >= 0 ? Math.round(parsed * 100) / 100 : 0;
}

export function initials(name: string) {
  return name.split(/\s+/).filter(Boolean).slice(0, 2).map(part => part[0]).join('').toUpperCase() || 'PR';
}

export function timeLabel(value: string) {
  return new Intl.DateTimeFormat('pt-BR', { hour: '2-digit', minute: '2-digit' }).format(new Date(value));
}
