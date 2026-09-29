import { useEffect, useMemo, useState } from 'react';
import { Check, CloudDownload, Package, Search, Sparkles } from 'lucide-react';
import type { Product } from '../model';
import { money, parseAmount } from '../model';
import { getStockProducts, importProducts, type StockProduct } from '../lib/pedidosApi';
import { Modal } from './Modal';

type Draft = StockProduct & { selected: boolean; priceText: string };

export function ImportModal({ stockId, stockName, currentProducts, onClose, onImported }: {
  stockId: string; stockName: string; currentProducts: Product[];
  onClose: () => void; onImported: (products: Product[]) => void;
}) {
  const [draft, setDraft] = useState<Draft[]>([]);
  const [search, setSearch] = useState('');
  const [busy, setBusy] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    let active = true;
    void getStockProducts(stockId).then(products => {
      if (!active) return;
      setDraft(products.map(product => {
        const existing = currentProducts.find(item => item.sourceProductId === product.sourceProductId);
        return { ...product, selected: true,
          priceText: (existing?.price ?? product.suggestedPrice ?? 0).toFixed(2) };
      }));
    }).catch(failure => {
      if (active) setError(failure instanceof Error ? failure.message : 'Não foi possível buscar os produtos.');
    }).finally(() => { if (active) setBusy(false); });
    return () => { active = false; };
  }, [stockId, currentProducts]);

  const filtered = useMemo(() => {
    const needle = search.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
    return draft.filter(item => `${item.name} ${item.code} ${item.category}`.normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '').toLowerCase().includes(needle));
  }, [draft, search]);
  const selectedCount = draft.filter(item => item.selected).length;

  async function saveImport() {
    const selected = draft.filter(item => item.selected);
    if (!selected.length) { setError('Selecione pelo menos um produto.'); return; }
    if (selected.some(item => !item.priceText.trim()
      || !Number.isFinite(Number(item.priceText.replace(',', '.')))
      || Number(item.priceText.replace(',', '.')) < 0)) {
      setError('Confira os preços dos itens selecionados.'); return;
    }
    setBusy(true); setError('');
    try {
      const products = await importProducts(stockId, selected.map(item => ({
        sourceProductId: item.sourceProductId, price: parseAmount(item.priceText),
      })));
      onImported(products); onClose();
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'Não foi possível importar.');
    } finally { setBusy(false); }
  }

  return <Modal title="Importar produtos" subtitle={`Estoque ${stockName}: escolha os itens e defina os preços de venda.`}
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
