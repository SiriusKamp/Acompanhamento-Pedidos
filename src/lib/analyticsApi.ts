import type {
  AnalyticsFilters, AnalyticsOverview, OrderAnalyticsDetail, OrderAnalyticsResult,
  ProductAnalyticsResult, ProductSort,
} from '../analytics';
import { supabase } from './supabase';

function unwrap<T>(data: unknown, error: { message: string; code?: string } | null): T {
  if (error) {
    if (error.code === 'PGRST202' || error.code === '42883') {
      throw new Error('O dashboard ainda não está instalado no banco. Execute supabase/migration_order_analytics.sql após migration_order_boards.sql.');
    }
    throw new Error(error.message);
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
  return unwrap<AnalyticsOverview>(data, error);
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
  return unwrap<ProductAnalyticsResult>(data, error);
}

export async function getAnalyticsOrders(
  stockId: string, filters: AnalyticsFilters, limit = 50, offset = 0,
): Promise<OrderAnalyticsResult> {
  const { data, error } = await supabase.rpc('orders_analytics_orders', {
    ...baseFilters(stockId, filters), p_limit: limit, p_offset: offset,
  });
  return unwrap<OrderAnalyticsResult>(data, error);
}

export async function getAnalyticsOrderDetail(stockId: string, orderId: string): Promise<OrderAnalyticsDetail> {
  const { data, error } = await supabase.rpc('orders_analytics_order_detail', {
    p_stock_id: stockId, p_order_id: orderId,
  });
  return unwrap<OrderAnalyticsDetail>(data, error);
}
