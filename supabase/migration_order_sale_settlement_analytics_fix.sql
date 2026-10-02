-- Fixes column-name ambiguity in the settlement-aware analytics source.
BEGIN;

CREATE OR REPLACE FUNCTION public.order_analytics_lines(
  p_stock_id uuid,p_board_ids uuid[],p_from timestamptz,p_to timestamptz
)
RETURNS TABLE(
  order_id uuid,order_number bigint,board_id uuid,board_name text,customer text,
  created_at timestamptz,finished_at timestamptz,suggested_total numeric,final_total numeric,
  line_id uuid,product_id uuid,product_name text,sku text,is_kit boolean,
  quantity integer,unit_price numeric,listed_revenue numeric,allocated_revenue numeric,
  actual_cost numeric,cost_complete boolean
) LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF p_from IS NULL OR p_to IS NULL OR p_to<=p_from OR p_to-p_from>interval '366 days' THEN
    RAISE EXCEPTION 'Intervalo de análise inválido.' USING ERRCODE='22023';
  END IF;
  IF coalesce(cardinality(p_board_ids),0)>0 AND EXISTS(
    SELECT 1 FROM unnest(p_board_ids) b WHERE NOT EXISTS(
      SELECT 1 FROM public.order_boards board WHERE board.id=b AND board.stock_id=p_stock_id)) THEN
    RAISE EXCEPTION 'Kanban não pertence ao estoque selecionado.' USING ERRCODE='42501';
  END IF;
  RETURN QUERY
  WITH selected_orders AS (
    SELECT o.id,o.number,o.board_id,b.name AS board_name,o.customer,o.created_at,o.finished_at,
      o.suggested_total,o.final_total,o.inventory_operation_id
    FROM public.order_sales o JOIN public.order_boards b ON b.id=o.board_id
    WHERE o.stock_id=p_stock_id AND o.status='finished' AND o.finished_at>=p_from AND o.finished_at<p_to
      AND (coalesce(cardinality(p_board_ids),0)=0 OR o.board_id=ANY(p_board_ids))
  ), source_lines AS (
    SELECT o.*,i.id AS source_line_id,coalesce(i.product_id,catalog.product_id) AS source_product_id,
      i.product_name AS source_product_name,product.sku AS source_sku,coalesce(product.is_kit,false) AS source_is_kit,
      i.quantity AS source_quantity,i.unit_price AS source_unit_price,i.quantity*i.unit_price AS source_listed_revenue,
      i.cost_source,i.unit_cost_snapshot,settlement.status AS settlement_status,settlement.actual_cost AS settlement_cost,
      count(*) OVER(PARTITION BY o.id) AS line_count,row_number() OVER(PARTITION BY o.id ORDER BY i.id) AS line_position,
      sum(i.quantity) OVER(PARTITION BY o.id) AS quantity_total
    FROM selected_orders o JOIN public.order_sale_items i ON i.order_id=o.id
    LEFT JOIN public.order_catalog_items catalog ON catalog.id=i.catalog_item_id
    LEFT JOIN public.products product ON product.id=coalesce(i.product_id,catalog.product_id)
    LEFT JOIN public.order_inventory_settlements settlement ON settlement.order_item_id=i.id
  ), raw_allocations AS (
    SELECT source_lines.*,CASE WHEN source_lines.suggested_total>0 THEN source_lines.final_total*source_lines.source_listed_revenue/source_lines.suggested_total
      WHEN source_lines.quantity_total>0 THEN source_lines.final_total*source_lines.source_quantity/source_lines.quantity_total ELSE 0 END AS raw_revenue
    FROM source_lines
  ), allocations AS (
    SELECT raw_allocations.*,CASE WHEN raw_allocations.line_position=raw_allocations.line_count THEN raw_allocations.final_total-coalesce(
      sum(round(raw_allocations.raw_revenue,2)) OVER(PARTITION BY raw_allocations.id ORDER BY raw_allocations.source_line_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0)
      ELSE round(raw_allocations.raw_revenue,2) END AS line_revenue
    FROM raw_allocations
  ), legacy_costs AS (
    SELECT o.id AS cost_order_id,item.product_id AS cost_product_id,sum(abs(m.quantity)*m.cost_per_base) AS total_cost
    FROM selected_orders o JOIN public.inventory_operation_items item ON item.operation_id=o.inventory_operation_id
    JOIN public.inventory_movements m ON m.item_id=item.id GROUP BY o.id,item.product_id
  ), calculated AS (
    SELECT a.*,CASE
      WHEN a.settlement_status='settled' AND a.settlement_cost IS NOT NULL THEN a.settlement_cost
      WHEN a.cost_source='manual' AND a.unit_cost_snapshot IS NOT NULL THEN a.unit_cost_snapshot*a.source_quantity
      WHEN legacy_costs.cost_order_id IS NOT NULL THEN legacy_costs.total_cost
      ELSE NULL END AS line_cost
    FROM allocations a LEFT JOIN legacy_costs ON legacy_costs.cost_order_id=a.id
      AND legacy_costs.cost_product_id=a.source_product_id
  )
  SELECT c.id,c.number,c.board_id,c.board_name,c.customer,c.created_at,c.finished_at,c.suggested_total,c.final_total,
    c.source_line_id,c.source_product_id,c.source_product_name,c.source_sku,c.source_is_kit,c.source_quantity,
    c.source_unit_price,c.source_listed_revenue,c.line_revenue,c.line_cost,c.line_cost IS NOT NULL
  FROM calculated c;
END $$;

NOTIFY pgrst, 'reload schema';
COMMIT;
