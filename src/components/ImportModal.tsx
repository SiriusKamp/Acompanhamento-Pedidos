import { useEffect, useMemo, useState } from 'react';
import { Check, CloudDownload, Package, Search, Sparkles, Trash2 } from 'lucide-react';
import type { Product } from '../model';
import type { ItemPreset } from '../model';
import { money, parseAmount } from '../model';
import { getStockProducts, importProducts, type Stock, type StockProduct } from '../lib/pedidosApi';
import { Modal } from './Modal';

type Draft = StockProduct & { selected: boolean; priceText: string; unitCostText: string; overwritePrice: boolean; alreadyImported: boolean };

export function ImportModal({ stockId, boardId, stockName, stocks, currentProducts, presets, onClose, onImported, onSavePreset, onDeletePreset }: {
  stockId: string; boardId: string; stockName: string; stocks: Stock[]; currentProducts: Product[]; presets: ItemPreset[];
  onClose: () => void; onImported: (products: Product[]) => void;
  onSavePreset: (name: string, items: ItemPreset['items']) => Promise<ItemPreset>;
  onDeletePreset: (presetId: string) => Promise<void>;
}) {
  const [draft, setDraft] = useState<Draft[]>([]);
  const [search, setSearch] = useState('');
  const [stockFilter, setStockFilter] = useState('all');
  const [busy, setBusy] = useState(true);
  const [error, setError] = useState('');
  const [presetName, setPresetName] = useState('');
  const [activePresetId, setActivePresetId] = useState('');
  const [presetBusy, setPresetBusy] = useState(false);

  useEffect(() => {
    let active = true;
    void Promise.all(stocks.map(stock => getStockProducts(stock.id, stock.name))).then(productGroups => {
      if (!active) return;
      const products = productGroups.flat();
      setDraft(previous => {
        const previousById = new Map(previous.map(item => [item.sourceProductId, item]));
        return products.map(product => {
          const saved = previousById.get(product.sourceProductId);
          const existing = currentProducts.find(item => item.sourceProductId === product.sourceProductId
            && item.sourceStockId === product.sourceStockId);
          return { ...product, selected: saved?.selected ?? !!existing, alreadyImported: !!existing, overwritePrice: saved?.overwritePrice ?? false,
            priceText: saved?.priceText ?? (existing?.price ?? product.suggestedPrice ?? 0).toFixed(2),
            unitCostText: saved?.unitCostText ?? (product.suggestedCost !== null
              ? product.suggestedCost.toFixed(2)
              : existing?.unitCost === null || existing?.unitCost === undefined ? '' : existing.unitCost.toFixed(2)) };
        });
      });
    }).catch(failure => {
      if (active) setError(failure instanceof Error ? failure.message : 'Não foi possível buscar os produtos.');
    }).finally(() => { if (active) setBusy(false); });
    return () => { active = false; };
  }, [stocks, boardId, currentProducts]);

  const filtered = useMemo(() => {
    const needle = search.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
    return draft.filter(item => (stockFilter === 'all' || item.sourceStockId === stockFilter)
      && `${item.name} ${item.code} ${item.category} ${item.sourceStockName}`.normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '').toLowerCase().includes(needle));
  }, [draft, search, stockFilter]);
  const selectedCount = draft.filter(item => item.selected).length;

  function applyPreset(presetId: string) {
    setActivePresetId(presetId);
    const preset = presets.find(item => item.id === presetId);
    const chosen = new Map((preset?.items ?? []).map(item => [item.sourceProductId, item.price]));
    setDraft(items => items.map(item => ({
      ...item,
      selected: chosen.has(item.sourceProductId),
      overwritePrice: chosen.has(item.sourceProductId) || item.overwritePrice,
      priceText: chosen.has(item.sourceProductId)
        ? chosen.get(item.sourceProductId)!.toFixed(2) : item.priceText,
    })));
  }

  async function deletePreset() {
    const selected = presets.find(preset => preset.id === activePresetId);
    if (!selected || !window.confirm(`Excluir o preset “${selected.name}”?`)) return;
    setPresetBusy(true); setError('');
    try {
      await onDeletePreset(selected.id);
      setActivePresetId(''); setPresetName('');
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'Não foi possível excluir o preset.');
    } finally { setPresetBusy(false); }
  }

  async function savePreset() {
    const selected = draft.filter(item => item.selected);
    if (!presetName.trim()) { setError('Dê um nome para o preset.'); return; }
    if (!selected.length) { setError('Selecione pelo menos um item para salvar.'); return; }
    if (selected.some(item => !item.priceText.trim()
      || !Number.isFinite(Number(item.priceText.replace(',', '.')))
      || Number(item.priceText.replace(',', '.')) < 0)) {
      setError('Confira os preços dos itens selecionados antes de salvar.'); return;
    }
    setPresetBusy(true); setError('');
    try {
      const saved = await onSavePreset(presetName, selected.map(item => ({
        sourceProductId: item.sourceProductId, sourceStockId: item.sourceStockId, price: parseAmount(item.priceText),
      })));
      setActivePresetId(saved.id); setPresetName(saved.name);
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'Não foi possível salvar o preset.');
    } finally { setPresetBusy(false); }
  }

  async function saveImport() {
    const selected = draft.filter(item => item.selected);
    if (!selected.length) { setError('Selecione pelo menos um produto.'); return; }
    if (selected.some(item => !item.priceText.trim()
      || !Number.isFinite(Number(item.priceText.replace(',', '.')))
      || Number(item.priceText.replace(',', '.')) < 0
      || (item.unitCostText.trim() && (!Number.isFinite(Number(item.unitCostText.replace(',', '.')))
        || Number(item.unitCostText.replace(',', '.')) < 0)))) {
      setError('Confira os preços de venda e custos dos itens selecionados.'); return;
    }
    setBusy(true); setError('');
    try {
      const products = await importProducts(stockId, boardId, selected.map(item => ({
        sourceProductId: item.sourceProductId, sourceStockId: item.sourceStockId, price: parseAmount(item.priceText), overwritePrice: item.overwritePrice,
        unitCost: item.unitCostText.trim() ? parseAmount(item.unitCostText) : null,
      })));
      onImported(products); onClose();
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'Não foi possível importar.');
    } finally { setBusy(false); }
  }

  return <Modal title="Importar produtos" subtitle={`Kanban ${stockName}: pesquise itens de todos os seus estoques. Presets e preços ficam salvos na sua conta.`}
    onClose={onClose} wide>
    <div className="import-body">
      {busy && !draft.length && <div className="modal-empty compact"><CloudDownload size={27} /><p>Buscando produtos e kits ativos...</p></div>}
      {!busy && !draft.length && !error && <div className="modal-empty compact"><Package size={27} /><p>Este estoque não possui produtos ativos.</p></div>}
      {!!draft.length && <>
        <div className="import-list-head"><label className="search-field"><Search size={17} />
          <input aria-label="Buscar produtos por nome ou código" value={search} onChange={event => setSearch(event.target.value)} placeholder="Buscar produtos por nome ou código" />
        </label><select className="import-stock-filter" aria-label="Filtrar itens por estoque" value={stockFilter} onChange={event => setStockFilter(event.target.value)}>
          <option value="all">Todos os estoques</option>{stocks.map(stock => <option key={stock.id} value={stock.id}>{stock.name}</option>)}
        </select><button className="text-back" onClick={() => setDraft(items => items.map(item =>
          ({ ...item, selected: selectedCount !== items.length })))}>
          {selectedCount === draft.length ? 'Desmarcar todos' : 'Selecionar todos'}
        </button></div>
        <div className="import-list">{filtered.map(item => <div className="import-row" key={`${item.sourceStockId}-${item.sourceProductId}`}>
          <label className="import-check"><input type="checkbox" checked={item.selected}
            onChange={event => setDraft(items => items.map(row => row.sourceProductId === item.sourceProductId && row.sourceStockId === item.sourceStockId
              ? { ...row, selected: event.target.checked } : row))} />
            <span className="check-ui"><Check size={13} /></span></label>
          <div className="import-row-info"><strong>{item.name}</strong><span>{item.category} · {item.code}</span><small className="import-stock-name">{item.sourceStockName}</small></div>
          <div className="import-price"><label>Preço de venda</label><div className="money-field"><span>R$</span>
            <input inputMode="decimal" aria-label={`Preço de ${item.name}`} value={item.priceText}
              onChange={event => setDraft(items => items.map(row => row.sourceProductId === item.sourceProductId && row.sourceStockId === item.sourceStockId
                ? { ...row, priceText: event.target.value, overwritePrice: true } : row))} /></div>
            <small>{item.alreadyImported ? 'Preço salvo é mantido; edição manual ou preset pode alterá-lo.' : item.suggestedPrice !== null ? `Sugerido: ${money(item.suggestedPrice)}` : 'Sem preço sugerido'}</small>
          </div>
          <div className="import-price"><label>Custo unitário no catálogo</label><div className="money-field"><span>R$</span>
            <input inputMode="decimal" aria-label={`Custo de ${item.name}`} placeholder="Opcional" value={item.unitCostText}
              onChange={event => setDraft(items => items.map(row => row.sourceProductId === item.sourceProductId && row.sourceStockId === item.sourceStockId
                ? { ...row, unitCostText: event.target.value } : row))} /></div>
            <small>{item.suggestedCost === null ? 'Custo indisponível no estoque; você pode informar manualmente.'
              : `${item.costIsEstimated || !item.costComplete ? 'Estimativa' : 'Custo atual'} do estoque: ${money(item.suggestedCost)}${!item.costComplete ? ' · incompleto' : ''}`}</small>
          </div>
        </div>)}
          {!filtered.length && <p className="list-empty">Nenhum produto corresponde à busca.</p>}
        </div>
        <div className="preset-tools">
          <div className="preset-select-row"><label className="field"><span>Usar preset salvo</span><select value={activePresetId} onChange={event => applyPreset(event.target.value)}>
              <option value="">Selecione um preset para marcar os itens</option>
              {presets.map(preset => <option key={preset.id} value={preset.id}>{preset.name}</option>)}
            </select></label>
            <button type="button" className="icon-button preset-delete" aria-label="Excluir preset selecionado"
              title="Excluir preset selecionado" onClick={() => void deletePreset()} disabled={!activePresetId || presetBusy}>
              <Trash2 size={17} />
            </button>
          </div>
          <div className="preset-save"><label className="field"><span>Nome do preset para esta seleção</span><input aria-label="Nome do preset" value={presetName}
            onChange={event => setPresetName(event.target.value)} placeholder="Ex.: Cardápio de sexta" maxLength={80} /></label>
            <button className="button button-secondary" onClick={() => void savePreset()} disabled={presetBusy || !selectedCount}>
              {presetBusy ? 'Salvando...' : 'Salvar preset'}
            </button>
          </div>
        </div>
        <div className="import-footer"><span><Sparkles size={16} /> {selectedCount} de {draft.length} selecionados</span>
          <button className="button button-primary" onClick={saveImport} disabled={!selectedCount || busy}>
            {busy ? 'Importando...' : `Importar ${selectedCount} produto${selectedCount === 1 ? '' : 's'}`}
          </button></div>
      </>}
      {error && <p className="form-error" role="alert">{error}</p>}
    </div>
  </Modal>;
}
