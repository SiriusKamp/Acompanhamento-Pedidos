import type { Product } from '../model';

const examples = [
  ['Café espresso', 'CAF-001', 'Bebidas quentes', false, 8.9],
  ['Cappuccino cremoso', 'CAF-002', 'Bebidas quentes', false, 16.5],
  ['Limonada da casa', 'BEB-014', 'Bebidas geladas', true, 13.9],
  ['Sanduíche natural', 'LAN-008', 'Lanches', false, 22.9],
  ['Brownie com sorvete', 'DOC-003', 'Sobremesas', true, 24.5],
  ['Combo café + brownie', 'COM-002', 'Combos', true, 29.9],
] as const;

export function demoProducts(): Product[] {
  const importedAt = new Date().toISOString();
  return examples.map(([name, code, category, isKit, price]) => ({
    id: `demo:${code}`, sourceProductId: null, sourceStockId: null,
    name, code, category, isKit, price, suggestedPrice: price, importedAt,
  }));
}
