BEGIN;

-- Qualify references whose names also exist as OUT parameters in this
-- PL/pgSQL RETURNS TABLE function (for example suggested_total/final_total).
CREATE OR REPLACE FUNCTION public.order_analytics_lines(p_stock_id uuid,p_board_ids uuid[],p_from timestamptz,p_to timestamptz)
RETURNS TABLE(order_id uuid,order_number bigint,board_id uuid,board_name text,customer text,created_at timestamptz,finished_at timestamptz,
  suggested_total numeric,final_total numeric,line_id uuid,product_id uuid,product_name text,sku text,is_kit boolean,
  quantity integer,unit_price numeric,listed_revenue numeric,allocated_revenue numeric,actual_cost numeric,cost_complete boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF p_from IS NULL OR p_to IS NULL OR p_to<=p_from OR p_to-p_from>interval '366 days' THEN RAISE EXCEPTION 'Intervalo de análise inválido.' USING ERRCODE='22023'; END IF;
  RETURN QUERY
  WITH selected AS (
    SELECT o.id,o.number,o.board_id,b.name board_name,o.customer,o.created_at,o.finished_at,o.suggested_total,o.final_total,o.inventory_operation_id
    FROM public.order_sales o JOIN public.order_boards b ON b.id=o.board_id
    WHERE o.stock_id=p_stock_id AND o.status='finished' AND o.finished_at>=p_from AND o.finished_at<p_to
      AND (coalesce(cardinality(p_board_ids),0)=0 OR o.board_id=ANY(p_board_ids))
  ), source AS (
    SELECT o.*,i.id source_line_id,coalesce(i.product_id,c.product_id) source_product_id,i.product_name source_name,p.sku source_sku,
      coalesce(p.is_kit,false) source_is_kit,i.quantity raw_quantity,i.unit,coalesce(i.unit_price_measure,i.unit_price) unit_price,
      i.quantity*coalesce(i.unit_price_measure,i.unit_price) raw_listed,p.content_quantity,p.content_unit,
      CASE WHEN lower(coalesce(p.content_unit,'un')) IN('ml','l') THEN 'ml' WHEN lower(coalesce(p.content_unit,'un')) IN('g','kg') THEN 'g' ELSE 'un' END base_unit,
      i.cost_source,coalesce(i.manual_unit_cost_measure,i.manual_unit_cost) manual_unit_cost,i.unit_cost_snapshot,i.final_revenue_snapshot,
      i.final_cost_snapshot,i.cost_complete_snapshot,s.status settlement_status,s.actual_cost settlement_cost,s.pending_quantity,
      count(*) OVER(PARTITION BY o.id) line_count,row_number() OVER(PARTITION BY o.id ORDER BY i.id) line_position,
      sum(i.quantity) OVER(PARTITION BY o.id) quantity_total
    FROM selected o JOIN public.order_sale_items i ON i.order_id=o.id
    LEFT JOIN public.order_catalog_items c ON c.id=i.catalog_item_id
    LEFT JOIN public.products p ON p.id=coalesce(i.product_id,c.product_id)
    LEFT JOIN public.order_inventory_settlements s ON s.order_item_id=i.id
  ), raw AS (
    SELECT source.*,coalesce(source.final_revenue_snapshot,CASE WHEN source.suggested_total>0 THEN source.final_total*source.raw_listed/source.suggested_total
      WHEN source.quantity_total>0 THEN source.final_total*source.raw_quantity/source.quantity_total ELSE 0 END) raw_revenue
    FROM source
  ), allocations AS (
    SELECT raw.*,CASE WHEN raw.line_position=raw.line_count THEN raw.final_total-coalesce(sum(round(raw.raw_revenue,2)) OVER(PARTITION BY raw.id ORDER BY raw.source_line_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0)
      ELSE round(raw.raw_revenue,2) END line_revenue FROM raw
  ), legacy_costs AS (
    SELECT o.id order_cost_id,item.product_id cost_product_id,sum(abs(m.quantity)*m.cost_per_base) total_cost
    FROM selected o JOIN public.inventory_operation_items item ON item.operation_id=o.inventory_operation_id
    JOIN public.inventory_movements m ON m.item_id=item.id GROUP BY o.id,item.product_id
  ), calculated AS (
    SELECT a.*,CASE WHEN a.final_cost_snapshot IS NOT NULL THEN a.final_cost_snapshot
      WHEN a.settlement_status='settled' AND a.settlement_cost IS NOT NULL THEN a.settlement_cost
      WHEN a.settlement_status='partial' THEN coalesce(a.settlement_cost,0)+CASE WHEN a.manual_unit_cost IS NOT NULL THEN a.manual_unit_cost*coalesce(a.pending_quantity,0) ELSE 0 END
      WHEN a.cost_source IN ('manual','mixed') AND a.unit_cost_snapshot IS NOT NULL THEN a.unit_cost_snapshot*a.raw_quantity
      ELSE legacy_costs.total_cost END line_cost
    FROM allocations a LEFT JOIN legacy_costs ON legacy_costs.order_cost_id=a.id AND legacy_costs.cost_product_id=a.source_product_id
  )
  SELECT c.id,c.number,c.board_id,c.board_name,c.customer,c.created_at,c.finished_at,c.suggested_total,c.final_total,c.source_line_id,c.source_product_id,
    c.source_name,c.source_sku,c.source_is_kit,
    round(CASE WHEN c.unit='un' THEN c.raw_quantity*coalesce(public.content_base(c.content_quantity,c.content_unit),1)
      ELSE c.raw_quantity*coalesce((SELECT u.base_factor FROM public.measurement_units u WHERE u.code=c.unit),1) END)::integer,
    c.unit_price,c.raw_listed,c.line_revenue,c.line_cost,coalesce(c.cost_complete_snapshot,c.line_cost IS NOT NULL)
  FROM calculated c;
END $$;

NOTIFY pgrst,'reload schema';
COMMIT;
