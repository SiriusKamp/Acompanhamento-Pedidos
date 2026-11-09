-- When a board's catalog receives a cost later, snapshot it once for older
-- finished order lines that still have no historical or manual cost.
BEGIN;

CREATE OR REPLACE FUNCTION public.snapshot_new_catalog_cost_to_finished_orders()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NEW.unit_cost IS NULL THEN RETURN NEW; END IF;
  UPDATE public.order_sale_items AS item SET
    unit_cost_snapshot=CASE WHEN item.unit='un' THEN NEW.unit_cost
      ELSE NEW.unit_cost/nullif(public.content_base(product.content_quantity,product.content_unit),0) END,
    final_cost_snapshot=round((CASE WHEN item.unit='un' THEN NEW.unit_cost
      ELSE NEW.unit_cost/nullif(public.content_base(product.content_quantity,product.content_unit),0) END)*item.quantity,6),
    cost_source='catalog_estimate',
    cost_complete_snapshot=true
  FROM public.order_sales AS sale
  LEFT JOIN public.products AS product ON product.id=NEW.product_id
  WHERE item.order_id=sale.id AND item.catalog_item_id=NEW.id AND sale.status='finished'
    AND item.final_cost_snapshot IS NULL AND item.unit_cost_snapshot IS NULL
    AND coalesce(item.manual_unit_cost_measure,item.manual_unit_cost) IS NULL
    AND coalesce(item.cost_source,'missing')='missing'
    AND (item.unit='un' OR nullif(public.content_base(product.content_quantity,product.content_unit),0) IS NOT NULL)
    AND NOT EXISTS(SELECT 1 FROM public.order_inventory_settlements settlement
      WHERE settlement.order_item_id=item.id AND settlement.actual_cost IS NOT NULL);
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS order_catalog_cost_refresh_finished_estimates ON public.order_catalog_items;
CREATE TRIGGER order_catalog_cost_refresh_finished_estimates
  AFTER INSERT OR UPDATE OF unit_cost ON public.order_catalog_items
  FOR EACH ROW EXECUTE FUNCTION public.snapshot_new_catalog_cost_to_finished_orders();

NOTIFY pgrst,'reload schema';
COMMIT;
