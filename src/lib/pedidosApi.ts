import type { ItemPreset, Order, OrderBoard, OrderStatus, Product } from '../model';
import { supabase } from './supabase';

export interface Stock { id: string; name: string }
export interface StockProduct {
  sourceProductId: string;
  name: string;
  code: string;
  category: string;
  isKit: boolean;
  suggestedPrice: number | null;
}
export interface NewOrder {
  customer: string;
  note: string;
  items: Array<{ productId: string; quantity: number }>;
  finalTotal: number;
  paid: number;
}

function result<T>(data: unknown, error: { message: string; code?: string } | null): T {
  if (error) {
    if (error.code === 'PGRST202' || error.code === '42883') {
      throw new Error('As funções de pedidos/kanbans não estão instaladas. Execute supabase/migration_order_boards.sql após orders_monolith.sql.');
    }
    throw new Error(error.message);
  }
  return data as T;
}

export async function getStocks(): Promise<Stock[]> {
  const { data, error } = await supabase.from('stocks').select('id,name').order('name');
  return result<Stock[]>(data ?? [], error);
}

export async function getOrderBoards(stockId: string): Promise<OrderBoard[]> {
  const { data, error } = await supabase.rpc('order_boards_list', { p_stock_id: stockId });
  const rows = result<OrderBoard[]>(data, error);
  if (!Array.isArray(rows)) throw new Error('Lista de kanbans inválida.');
  return rows;
}

export async function createOrderBoard(stockId: string, name: string): Promise<OrderBoard> {
  const { data, error } = await supabase.rpc('order_boards_create', {
    p_stock_id: stockId, p_name: name.trim(),
  });
  return result<OrderBoard>(data, error);
}

export async function getItemPresets(stockId: string): Promise<ItemPreset[]> {
  const { data, error } = await supabase.rpc('order_presets_list', { p_stock_id: stockId });
  const rows = result<ItemPreset[]>(data, error);
  if (!Array.isArray(rows)) throw new Error('Lista de presets inválida.');
  return rows;
}

export async function saveItemPreset(
  stockId: string, name: string, items: ItemPreset['items'],
): Promise<ItemPreset> {
  const { data, error } = await supabase.rpc('order_presets_save', {
    p_stock_id: stockId, p_name: name.trim(), p_items: items,
  });
  return result<ItemPreset>(data, error);
}

export async function createStock(userId: string, name: string): Promise<Stock> {
  const { data, error } = await supabase.from('stocks')
    .insert({ user_id: userId, name: name.trim() }).select('id,name').single();
  return result<Stock>(data, error);
}

export async function getProducts(stockId: string, boardId: string): Promise<Product[]> {
  const { data, error } = await supabase.rpc('orders_catalog_board', {
    p_stock_id: stockId, p_board_id: boardId,
  });
  const rows = result<Product[]>(data, error);
  if (!Array.isArray(rows)) throw new Error('Catálogo de pedidos inválido.');
  return rows;
}

export async function updateProductPrice(
  stockId: string, boardId: string, id: string, price: number, unitCost: number | null,
): Promise<Product> {
  const { data, error } = await supabase.rpc('orders_update_catalog_item_board', {
    p_stock_id: stockId, p_board_id: boardId, p_catalog_id: id, p_price: price, p_unit_cost: unitCost,
  });
  return result<Product>(data, error);
}

export async function getOrders(stockId: string, boardId: string): Promise<Order[]> {
  const { data, error } = await supabase.rpc('orders_list_board', {
    p_stock_id: stockId, p_board_id: boardId,
  });
  const rows = result<Order[]>(data, error);
  if (!Array.isArray(rows)) throw new Error('Lista de pedidos inválida.');
  return rows;
}

export async function createOrder(stockId: string, boardId: string, order: NewOrder): Promise<Order> {
  const { data, error } = await supabase.rpc('orders_create_board', {
    p_stock_id: stockId, p_board_id: boardId, p_data: order,
  });
  return result<Order>(data, error);
}

export async function changeOrderStatus(stockId: string, boardId: string, id: string, status: OrderStatus): Promise<Order> {
  const { data, error } = await supabase.rpc('orders_change_status_board', {
    p_stock_id: stockId, p_board_id: boardId, p_order_id: id, p_status: status,
  });
  return result<Order>(data, error);
}

export async function getStockProducts(stockId: string): Promise<StockProduct[]> {
  const rows: StockProduct[] = [];
  for (let page = 0; ; page++) {
    const { data, error } = await supabase.from('product_catalog')
      .select('id,name,sku,type_name,is_kit,suggested_sale_price,next_sale')
      .eq('stock_id', stockId).eq('active', true)
      .order('name').order('id').range(page * 500, page * 500 + 499);
    const batch = result<Array<{
      id: string; name: string; sku: string; type_name: string | null;
      is_kit: boolean; suggested_sale_price: number | null; next_sale: number | null;
    }>>(data ?? [], error);
    rows.push(...batch.map(row => ({
      sourceProductId: row.id, name: row.name, code: row.sku,
      category: row.type_name ?? 'Sem categoria', isKit: row.is_kit,
      suggestedPrice: row.suggested_sale_price ?? row.next_sale,
    })));
    if (batch.length < 500) return rows;
  }
}

export async function importProducts(
  stockId: string, boardId: string, items: Array<{ sourceProductId: string; price: number; unitCost?: number | null }>,
): Promise<Product[]> {
  const imported: Product[] = [];
  for (let start = 0; start < items.length; start += 100) {
    const { data, error } = await supabase.rpc('orders_import_catalog_board', {
      p_stock_id: stockId, p_board_id: boardId, p_items: items.slice(start, start + 100),
    });
    imported.push(...result<Product[]>(data, error));
  }
  return imported;
}
