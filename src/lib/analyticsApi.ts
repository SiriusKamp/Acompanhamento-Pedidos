import type {
  AnalyticsFilters, AnalyticsOverview, OrderAnalyticsDetail, OrderAnalyticsResult,
  ProductAnalyticsResult, ProductSort,
} from '../analytics';
import { supabase } from './supabase';

type DatabaseError = { message: string; code?: string; hint?: string | null; details?: string | null };

function unwrap<T>(data: unknown, error: DatabaseError | null, operation: string): T {
  if (error) {
    if (error.code === 'PGRST202') {
      throw new Error(`A consulta ${operation} não existe no Supabase conectado a este deploy. Confirme se o Vercel usa o mesmo VITE_SUPABASE_URL onde migration_order_analytics.sql foi executada.`);
    }
    const diagnostic = [error.message, error.details, error.hint].filter(Boolean).join(' ');
    throw new Error(`Falha na consulta ${operation}${error.code ? ` (${error.code})` : ''}: ${diagnostic}`);
  }
  if (!data || typeof data !== 'object') throw new Error('O banco retornou uma análise inválida.');
  return data as T;
}

function baseFilters(stockId: string, filters: AnalyticsFilters) {
  return {
    p_stock_id: stockId,
    p_board_ids: filters.boardIds.length ? filters.boardIds : null,
    p_from: filters.from,
    p_to: filters.to,
  };
}

export async function getAnalyticsOverview(stockId: string, filters: AnalyticsFilters): Promise<AnalyticsOverview> {
  const { data, error } = await supabase.rpc('orders_analytics_overview', {
    ...baseFilters(stockId, filters), p_timezone: 'America/Sao_Paulo',
  });
  return unwrap<AnalyticsOverview>(data, error, 'visão geral');
}

export async function getAnalyticsProducts(
  stockId: string, filters: AnalyticsFilters, sort: ProductSort, direction: 'asc' | 'desc',
  limit = 100, offset = 0,
): Promise<ProductAnalyticsResult> {
  const { data, error } = await supabase.rpc('orders_analytics_products', {
    ...baseFilters(stockId, filters),
    p_search: filters.search || null,
    p_kind: filters.productKind,
    p_sort: sort,
    p_direction: direction,
    p_limit: limit,
    p_offset: offset,
  });
  return unwrap<ProductAnalyticsResult>(data, error, 'produtos');
}

export async function getAnalyticsOrders(
  stockId: string, filters: AnalyticsFilters, limit = 50, offset = 0,
): Promise<OrderAnalyticsResult> {
  const { data, error } = await supabase.rpc('orders_analytics_orders', {
    ...baseFilters(stockId, filters), p_limit: limit, p_offset: offset,
  });
  return unwrap<OrderAnalyticsResult>(data, error, 'pedidos');
}

export async function getAnalyticsOrderDetail(stockId: string, orderId: string): Promise<OrderAnalyticsDetail> {
  const { data, error } = await supabase.rpc('orders_analytics_order_detail', {
    p_stock_id: stockId, p_order_id: orderId,
  });
  return unwrap<OrderAnalyticsDetail>(data, error, 'detalhe do pedido');
}
