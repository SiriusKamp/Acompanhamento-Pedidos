import { useEffect, useMemo, useState } from 'react';
import { Check, CloudDownload, Package, Search, Sparkles } from 'lucide-react';
import type { Product } from '../model';
import type { ItemPreset } from '../model';
import { money, parseAmount } from '../model';
import { getStockProducts, importProducts, type StockProduct } from '../lib/pedidosApi';
import { Modal } from './Modal';

type Draft = StockProduct & { selected: boolean; priceText: string; unitCostText: string };

export function ImportModal({ stockId, boardId, stockName, currentProducts, presets, onClose, onImported, onSavePreset }: {
  stockId: string; boardId: string; stockName: string; currentProducts: Product[]; presets: ItemPreset[];
  onClose: () => void; onImported: (products: Product[]) => void;
  onSavePreset: (name: string, items: ItemPreset['items']) => Promise<ItemPreset>;
}) {
  const [draft, setDraft] = useState<Draft[]>([]);
  const [search, setSearch] = useState('');
  const [busy, setBusy] = useState(true);
  const [error, setError] = useState('');
  const [presetName, setPresetName] = useState('');
  const [presetBusy, setPresetBusy] = useState(false);

  useEffect(() => {
    let active = true;
    void getStockProducts(stockId).then(products => {
      if (!active) return;
      setDraft(products.map(product => {
        const existing = currentProducts.find(item => item.sourceProductId === product.sourceProductId);
        return { ...product, selected: !!existing,
          priceText: (existing?.price ?? product.suggestedPrice ?? 0).toFixed(2),
          unitCostText: existing?.unitCost === null || existing?.unitCost === undefined ? '' : existing.unitCost.toFixed(2) };
      }));
    }).catch(failure => {
      if (active) setError(failure instanceof Error ? failure.message : 'Não foi possível buscar os produtos.');
    }).finally(() => { if (active) setBusy(false); });
    return () => { active = false; };
  }, [stockId, boardId, currentProducts]);

  const filtered = useMemo(() => {
    const needle = search.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
    return draft.filter(item => `${item.name} ${item.code} ${item.category}`.normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '').toLowerCase().includes(needle));
  }, [draft, search]);
  const selectedCount = draft.filter(item => item.selected).length;

  function applyPreset(presetId: string) {
    const preset = presets.find(item => item.id === presetId);
    const chosen = new Map((preset?.items ?? []).map(item => [item.sourceProductId, item.price]));
    setDraft(items => items.map(item => ({
      ...item,
      selected: chosen.has(item.sourceProductId),
      priceText: chosen.has(item.sourceProductId)
        ? chosen.get(item.sourceProductId)!.toFixed(2) : item.priceText,
    })));
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
      await onSavePreset(presetName, selected.map(item => ({
        sourceProductId: item.sourceProductId, price: parseAmount(item.priceText),
      })));
      setPresetName('');
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
        sourceProductId: item.sourceProductId, price: parseAmount(item.priceText),
        unitCost: item.unitCostText.trim() ? parseAmount(item.unitCostText) : null,
      })));
      onImported(products); onClose();
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'Não foi possível importar.');
    } finally { setBusy(false); }
  }

  return <Modal title="Importar produtos" subtitle={`Estoque ${stockName}: escolha os itens, o preço de venda e, se necessário, o custo unitário manual.`}
    onClose={onClose} wide>
    <div className="import-body">
      {busy && !draft.length && <div className="modal-empty compact"><CloudDownload size={27} /><p>Buscando produtos e kits ativos...</p></div>}
      {!busy && !draft.length && !error && <div className="modal-empty compact"><Package size={27} /><p>Este estoque não possui produtos ativos.</p></div>}
      {!!draft.length && <>
        <div className="import-list-head"><label className="search-field"><Search size={17} />
          <input value={search} onChange={event => setSearch(event.target.value)} placeholder="Filtrar produtos" />
        </label><button className="text-back" onClick={() => setDraft(items => items.map(item =>
          ({ ...item, selected: selectedCount !== items.length })))}>
          {selectedCount === draft.length ? 'Desmarcar todos' : 'Selecionar todos'}
        </button></div>
        <div className="preset-tools">
          <label className="field"><span>Usar preset salvo</span><select defaultValue="" onChange={event => applyPreset(event.target.value)}>
            <option value="">Selecione um preset para marcar os itens</option>
            {presets.map(preset => <option key={preset.id} value={preset.id}>{preset.name}</option>)}
          </select></label>
          <div className="preset-save"><label className="field"><span>Salvar seleção atual</span><input value={presetName}
            onChange={event => setPresetName(event.target.value)} placeholder="Ex.: Cardápio de sexta" maxLength={80} /></label>
            <button className="button button-secondary" onClick={() => void savePreset()} disabled={presetBusy || !selectedCount}>
              {presetBusy ? 'Salvando...' : 'Salvar preset'}
            </button>
          </div>
        </div>
        <div className="import-list">{filtered.map(item => <div className="import-row" key={item.sourceProductId}>
          <label className="import-check"><input type="checkbox" checked={item.selected}
            onChange={event => setDraft(items => items.map(row => row.sourceProductId === item.sourceProductId
              ? { ...row, selected: event.target.checked } : row))} />
            <span className="check-ui"><Check size={13} /></span></label>
          <div className="import-row-info"><strong>{item.name}</strong><span>{item.category} · {item.code}</span></div>
          <div className="import-price"><label>Preço de venda</label><div className="money-field"><span>R$</span>
            <input inputMode="decimal" aria-label={`Preço de ${item.name}`} value={item.priceText}
              onChange={event => setDraft(items => items.map(row => row.sourceProductId === item.sourceProductId
                ? { ...row, priceText: event.target.value } : row))} /></div>
            <small>{item.suggestedPrice !== null ? `Sugerido: ${money(item.suggestedPrice)}` : 'Sem preço sugerido'}</small>
          </div>
          <div className="import-price"><label>Custo unitário</label><div className="money-field"><span>R$</span>
            <input inputMode="decimal" aria-label={`Custo de ${item.name}`} placeholder="Opcional" value={item.unitCostText}
              onChange={event => setDraft(items => items.map(row => row.sourceProductId === item.sourceProductId
                ? { ...row, unitCostText: event.target.value } : row))} /></div>
            <small>Usado se faltar custo FIFO</small>
          </div>
        </div>)}
          {!filtered.length && <p className="list-empty">Nenhum produto corresponde à busca.</p>}
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
