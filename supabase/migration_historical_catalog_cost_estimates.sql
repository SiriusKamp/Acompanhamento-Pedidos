-- Backfill cost estimates for finished orders that predate catalog cost imports.
-- These are explicitly marked as estimates, never presented as historical FIFO costs.
BEGIN;

ALTER TABLE public.order_sale_items DROP CONSTRAINT IF EXISTS order_sale_items_cost_source_check;
ALTER TABLE public.order_sale_items ADD CONSTRAINT order_sale_items_cost_source_check
  CHECK (cost_source IS NULL OR cost_source IN ('inventory','manual','mixed','missing','catalog_estimate'));

WITH estimates AS (
  SELECT i.id,
    CASE WHEN i.unit='un' THEN c.unit_cost
      ELSE c.unit_cost/nullif(public.content_base(p.content_quantity,p.content_unit),0) END AS unit_cost
  FROM public.order_sale_items i
  JOIN public.order_sales o ON o.id=i.order_id AND o.status='finished'
  JOIN public.order_catalog_items c ON c.id=i.catalog_item_id AND c.unit_cost IS NOT NULL
  LEFT JOIN public.products p ON p.id=coalesce(i.product_id,c.product_id)
  WHERE i.final_cost_snapshot IS NULL AND i.unit_cost_snapshot IS NULL
    AND coalesce(i.manual_unit_cost_measure,i.manual_unit_cost) IS NULL
    AND coalesce(i.cost_source,'missing')='missing'
    AND NOT EXISTS(SELECT 1 FROM public.order_inventory_settlements s WHERE s.order_item_id=i.id AND s.actual_cost IS NOT NULL)
), valid_estimates AS (
  SELECT id,unit_cost FROM estimates WHERE unit_cost IS NOT NULL AND unit_cost>=0
)
UPDATE public.order_sale_items i SET
  unit_cost_snapshot=e.unit_cost,
  final_cost_snapshot=round(e.unit_cost*i.quantity,6),
  cost_source='catalog_estimate',
  cost_complete_snapshot=true
FROM valid_estimates e WHERE e.id=i.id;

CREATE OR REPLACE FUNCTION public.orders_analytics_estimate_summary(
  p_stock_id uuid,p_board_ids uuid[],p_from timestamptz,p_to timestamptz
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF p_from IS NULL OR p_to IS NULL OR p_to<=p_from OR p_to-p_from>interval '366 days' THEN
    RAISE EXCEPTION 'Intervalo de análise inválido.' USING ERRCODE='22023';
  END IF;
  SELECT jsonb_build_object(
    'estimatedOrders',count(DISTINCT o.id),
    'estimatedItems',count(i.id),
    'estimatedCost',coalesce(sum(i.final_cost_snapshot),0)
  ) INTO result
  FROM public.order_sales o JOIN public.order_sale_items i ON i.order_id=o.id
  WHERE o.stock_id=p_stock_id AND o.status='finished' AND o.finished_at>=p_from AND o.finished_at<p_to
    AND (coalesce(cardinality(p_board_ids),0)=0 OR o.board_id=ANY(p_board_ids))
    AND i.cost_source='catalog_estimate';
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_analytics_order_detail(p_stock_id uuid,p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb; completed_at timestamptz;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT o.finished_at INTO completed_at FROM public.order_sales o
    WHERE o.id=p_order_id AND o.stock_id=p_stock_id AND o.status='finished';
  IF completed_at IS NULL THEN RAISE EXCEPTION 'Pedido finalizado não encontrado.' USING ERRCODE='P0002'; END IF;
  WITH lines AS (
    SELECT * FROM public.order_analytics_lines(p_stock_id,NULL,completed_at-interval '1 microsecond',completed_at+interval '1 microsecond')
    WHERE order_id=p_order_id
  ), header AS (
    SELECT max(order_number) AS number,max(board_name) AS board_name,max(customer) AS customer,
      max(created_at) AS created_at,max(finished_at) AS finished_at,max(final_total) AS final_total,
      sum(allocated_revenue) AS revenue,bool_and(cost_complete) AS cost_complete,
      CASE WHEN bool_and(cost_complete) THEN sum(actual_cost) END AS cost
    FROM lines
  )
  SELECT jsonb_build_object(
    'order',(SELECT jsonb_build_object('number',number,'boardName',board_name,'customer',customer,
      'createdAt',created_at,'finishedAt',finished_at,'finalTotal',final_total,'revenue',revenue,
      'cost',cost,'profit',CASE WHEN cost_complete THEN revenue-cost END,
      'margin',CASE WHEN cost_complete THEN round((revenue-cost)/nullif(revenue,0)*100,2) END,
      'costComplete',cost_complete) FROM header),
    'items',coalesce((SELECT jsonb_agg(jsonb_build_object(
      'productId',line.product_id,'name',line.product_name,'code',line.sku,'isKit',line.is_kit,
      'quantity',line.quantity,'unitPrice',line.unit_price,'listedRevenue',line.listed_revenue,
      'revenue',line.allocated_revenue,'cost',line.actual_cost,
      'profit',CASE WHEN line.cost_complete THEN line.allocated_revenue-line.actual_cost END,
      'margin',CASE WHEN line.cost_complete THEN round((line.allocated_revenue-line.actual_cost)/nullif(line.allocated_revenue,0)*100,2) END,
      'costComplete',line.cost_complete,
      'costSource',(SELECT item.cost_source FROM public.order_sale_items item WHERE item.id=line.line_id),
      'lots',coalesce((SELECT jsonb_agg(jsonb_build_object('lotId',lot.id,'code',lot.code,
        'productName',component.name,'quantityBase',abs(movement.quantity),
        'cost',abs(movement.quantity)*movement.cost_per_base) ORDER BY lot.acquired_at,lot.id)
        FROM public.order_sale_items sale_line
        JOIN public.order_sales sale ON sale.id=sale_line.order_id
        LEFT JOIN public.order_inventory_settlements settlement ON settlement.order_item_id=sale_line.id
        JOIN public.inventory_operation_items operation_item ON operation_item.operation_id=
          coalesce(settlement.inventory_operation_id,sale.inventory_operation_id)
        JOIN public.inventory_movements movement ON movement.item_id=operation_item.id
        JOIN public.stock_lots lot ON lot.id=movement.lot_id
        JOIN public.products component ON component.id=lot.product_id
        WHERE sale_line.id=line.line_id),'[]'::jsonb)
    ) ORDER BY line.product_name) FROM lines line),'[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;

REVOKE ALL ON FUNCTION public.orders_analytics_estimate_summary(uuid,uuid[],timestamptz,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.orders_analytics_estimate_summary(uuid,uuid[],timestamptz,timestamptz) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
