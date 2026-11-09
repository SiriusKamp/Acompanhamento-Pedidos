-- Expose the cost captured on order items to the Vite client.
-- Run after migration_order_measurement_and_edit.sql and the order settlement migrations.
-- The cost comes from the catalog value copied when the order is created. Finishing an
-- order may replace it with the actual inventory settlement snapshot. Historical rows
-- are intentionally left untouched.
BEGIN;

CREATE OR REPLACE FUNCTION public.snapshot_order_item_catalog_cost()
RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE catalog_cost numeric;
BEGIN
  catalog_cost:=coalesce(NEW.manual_unit_cost_measure,NEW.manual_unit_cost);
  NEW.unit_cost_snapshot:=coalesce(NEW.unit_cost_snapshot,catalog_cost);
  NEW.final_cost_snapshot:=coalesce(NEW.final_cost_snapshot,
    CASE WHEN catalog_cost IS NULL THEN NULL ELSE round(catalog_cost*NEW.quantity,6) END);
  NEW.cost_source:=coalesce(NEW.cost_source,
    CASE WHEN catalog_cost IS NULL THEN 'missing' ELSE 'manual' END);
  NEW.cost_complete_snapshot:=coalesce(NEW.cost_complete_snapshot,catalog_cost IS NOT NULL);
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS order_sale_items_catalog_cost_snapshot ON public.order_sale_items;
CREATE TRIGGER order_sale_items_catalog_cost_snapshot
  BEFORE INSERT ON public.order_sale_items
  FOR EACH ROW EXECUTE FUNCTION public.snapshot_order_item_catalog_cost();

CREATE OR REPLACE FUNCTION public.orders_get_board(p_stock_id uuid,p_board_id uuid,p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT jsonb_build_object(
    'id',o.id,'boardId',o.board_id,'boardName',b.name,'number',o.number,'customer',o.customer,'note',o.note,
    'suggestedTotal',o.suggested_total,'finalTotal',o.final_total,'paid',o.paid,'status',o.status,
    'inventoryStatus',o.inventory_status,'createdAt',o.created_at,'updatedAt',o.updated_at,
    'items',coalesce((SELECT jsonb_agg(jsonb_build_object(
      'productId',coalesce(i.catalog_item_id::text,''),'name',i.product_name,'quantity',i.quantity,
      'unit',i.unit,'unitPrice',coalesce(i.unit_price_measure,i.unit_price),'sourceStockName',i.source_stock_name,
      'unitCostSnapshot',i.unit_cost_snapshot,'finalCostSnapshot',i.final_cost_snapshot,
      'costSource',i.cost_source,'costCompleteSnapshot',i.cost_complete_snapshot
    ) ORDER BY i.id) FROM public.order_sale_items i WHERE i.order_id=o.id),'[]'::jsonb)
  ) INTO result
  FROM public.order_sales o JOIN public.order_boards b ON b.id=o.board_id
  WHERE o.id=p_order_id AND o.stock_id=p_stock_id AND o.board_id=p_board_id;
  RETURN result;
END $$;

NOTIFY pgrst,'reload schema';
COMMIT;
