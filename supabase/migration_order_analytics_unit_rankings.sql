BEGIN;

CREATE OR REPLACE FUNCTION public.orders_analytics_unit_rankings(
  p_stock_id uuid,p_board_ids uuid[],p_from timestamptz,p_to timestamptz
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF p_from IS NULL OR p_to IS NULL OR p_to<=p_from OR p_to-p_from>interval '366 days' THEN
    RAISE EXCEPTION 'Intervalo de análise inválido.' USING ERRCODE='22023';
  END IF;
  WITH lines AS (
    SELECT * FROM public.order_analytics_lines(p_stock_id,p_board_ids,p_from,p_to)
  ), totals AS (
    SELECT line.product_id,min(line.product_name) AS name,min(line.sku) AS code,
      sum(CASE WHEN item.unit='un' THEN item.quantity ELSE 1 END) AS quantity,
      sum(line.allocated_revenue) AS revenue,
      CASE WHEN bool_and(line.cost_complete) THEN sum(line.allocated_revenue)-sum(line.actual_cost) END AS profit
    FROM lines line JOIN public.order_sale_items item ON item.id=line.line_id
    WHERE line.product_id IS NOT NULL
    GROUP BY line.product_id
  ), ranked AS (
    SELECT * FROM totals ORDER BY quantity DESC,name LIMIT 5
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('productId',product_id,'name',name,'code',code,
    'quantity',quantity,'quantityUnit','un','revenue',revenue,'profit',coalesce(profit,0)) ORDER BY quantity DESC,name),'[]'::jsonb)
  INTO result FROM ranked;
  RETURN result;
END $$;

REVOKE ALL ON FUNCTION public.orders_analytics_unit_rankings(uuid,uuid[],timestamptz,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.orders_analytics_unit_rankings(uuid,uuid[],timestamptz,timestamptz) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
