export type AnalyticsPeriod = 'today' | 'yesterday' | '7d' | '30d' | 'month' | 'custom';
export type ProductKindFilter = 'all' | 'product' | 'kit';
export type ProductSort = 'profit' | 'revenue' | 'quantity' | 'margin' | 'name';

export interface AnalyticsFilters {
  boardIds: string[];
  period: AnalyticsPeriod;
  from: string;
  to: string;
  productKind: ProductKindFilter;
  search: string;
}

export interface FinancialSummary {
  orders: number;
  revenue: number;
  cost: number;
  profit: number;
  costedRevenue: number;
  margin: number;
  markup: number;
  averageTicket: number;
  openPotential?: number;
}

export interface AnalyticsSeriesPoint {
  date: string;
  orders: number;
  revenue: number;
  cost: number;
  profit: number;
}

export interface BoardAnalytics {
  id: string;
  name: string;
  orders: number;
  revenue: number;
  cost: number;
  profit: number;
  margin: number;
  averageTicket: number;
}

export interface ProductRank {
  productId: string;
  name: string;
  code: string | null;
  quantity: number;
  revenue: number;
  profit: number;
}

export interface ParetoPoint {
  productId: string;
  name: string;
  profit: number;
  accumulatedPercent: number;
}

export interface AnalyticsQuality {
  finishedOrders: number;
  costCompleteOrders: number;
  coveragePercent: number;
}

export interface InventoryHealth {
  finishedOrders: number;
  settledOrders: number;
  partialOrders: number;
  pendingOrders: number;
  pendingItems: number;
  manualCostItems: number;
  missingCostItems: number;
  alerts: Array<{ productName: string; quantity: number; settledQuantity: number; unit: string; message: string | null }>;
}

export interface AnalyticsOverview {
  summary: FinancialSummary;
  previous: FinancialSummary;
  series: AnalyticsSeriesPoint[];
  boards: BoardAnalytics[];
  rankings: {
    byQuantity: ProductRank[];
    byRevenue: ProductRank[];
    byProfit: ProductRank[];
  };
  pareto: ParetoPoint[];
  quality: AnalyticsQuality;
}

export interface ProductAnalytics {
  productId: string;
  name: string;
  code: string | null;
  isKit: boolean;
  orders: number;
  quantity: number;
  revenue: number;
  cost: number | null;
  profit: number | null;
  margin: number | null;
  markup: number | null;
  averagePrice: number;
  adjustmentPercent: number | null;
  stockWholeUnits: number;
  dailyVelocity: number;
  coverageDays: number | null;
  lastSaleAt: string | null;
  previousQuantity: number;
  previousRevenue: number;
  previousProfit: number | null;
  costComplete: boolean;
}

export interface ProductAnalyticsResult {
  total: number;
  periodDays: number;
  rows: ProductAnalytics[];
}

export interface OrderAnalytics {
  orderId: string;
  number: number;
  boardId: string;
  boardName: string;
  customer: string;
  createdAt: string;
  finishedAt: string;
  suggestedTotal: number;
  finalTotal: number;
  lineCount: number;
  itemQuantity: number;
  revenue: number;
  cost: number | null;
  profit: number | null;
  margin: number | null;
  adjustmentPercent: number | null;
  costComplete: boolean;
}

export interface OrderAnalyticsResult {
  total: number;
  rows: OrderAnalytics[];
}

export interface OrderAnalyticsDetailItem {
  productId: string | null;
  name: string;
  code: string | null;
  isKit: boolean;
  quantity: number;
  unitPrice: number;
  listedRevenue: number;
  revenue: number;
  cost: number | null;
  profit: number | null;
  margin: number | null;
  costComplete: boolean;
  lots: Array<{ lotId: string; code: string; productName: string; quantityBase: number; cost: number }>;
}

export interface OrderAnalyticsDetail {
  order: Omit<OrderAnalytics, 'orderId' | 'boardId' | 'suggestedTotal' | 'lineCount' | 'itemQuantity' | 'adjustmentPercent'>;
  items: OrderAnalyticsDetailItem[];
}

export type ProductRecommendationKind = 'produce' | 'avoid-stockout' | 'review-price' | 'promote' | 'review-menu' | 'healthy' | 'incomplete';

export interface ProductRecommendation {
  kind: ProductRecommendationKind;
  title: string;
  reason: string;
  suggestedQuantity?: number;
}
