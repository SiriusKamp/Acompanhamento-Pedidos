BEGIN;

-- Source-stock analytics for the overview. Existing unfiltered RPCs remain unchanged.

CREATE OR REPLACE FUNCTION public.order_analytics_lines_for_source_stock(
  p_stock_id uuid,p_board_ids uuid[],p_from timestamptz,p_to timestamptz,p_source_stock_id uuid
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
  -- Source stock may belong to a different account; only filter order items already imported into p_stock_id.
  RETURN QUERY
  SELECT line.order_id,line.order_number,line.board_id,line.board_name,line.customer,
    line.created_at,line.finished_at,line.suggested_total,line.final_total,line.line_id,
    line.product_id,line.product_name,line.sku,line.is_kit,line.quantity,line.unit_price,
    line.listed_revenue,line.allocated_revenue,line.actual_cost,line.cost_complete
  FROM public.order_analytics_lines(p_stock_id,p_board_ids,p_from,p_to) line
  JOIN public.order_sale_items item ON item.id=line.line_id
  LEFT JOIN public.order_catalog_items catalog ON catalog.id=item.catalog_item_id
  LEFT JOIN public.products product ON product.id=coalesce(item.product_id,catalog.product_id)
  WHERE coalesce(item.source_stock_id,product.stock_id)=p_source_stock_id;
END $$;

CREATE OR REPLACE FUNCTION public.orders_analytics_overview_source_stock(
  p_stock_id uuid, p_board_ids uuid[], p_from timestamptz, p_to timestamptz,
  p_source_stock_id uuid,p_timezone text DEFAULT 'America/Sao_Paulo'
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb; previous_from timestamptz := p_from - (p_to - p_from);
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  -- Source stock may belong to a different account; only filter order items already imported into p_stock_id.
  IF p_timezone IS DISTINCT FROM 'America/Sao_Paulo' THEN
    RAISE EXCEPTION 'Fuso horário não suportado.' USING ERRCODE = '22023';
  END IF;
  WITH current_lines AS (
    SELECT * FROM public.order_analytics_lines_for_source_stock(p_stock_id, p_board_ids, p_from, p_to, p_source_stock_id)
  ), previous_lines AS (
    SELECT * FROM public.order_analytics_lines_for_source_stock(p_stock_id, p_board_ids, previous_from, p_from, p_source_stock_id)
  ), current_orders AS (
    -- Every order belongs to exactly one board. PostgreSQL has no max(uuid),
    -- so aggregate its text representation and cast the stable value back to UUID.
    SELECT order_id, min(board_id::text)::uuid AS board_id, max(board_name) AS board_name,
      max(finished_at) AS finished_at, sum(allocated_revenue) AS revenue,
      bool_and(cost_complete) AS cost_complete,
      CASE WHEN bool_and(cost_complete) THEN sum(actual_cost) END AS cost
    FROM current_lines GROUP BY order_id
  ), previous_orders AS (
    SELECT order_id, sum(allocated_revenue) AS revenue,
      bool_and(cost_complete) AS cost_complete,
      CASE WHEN bool_and(cost_complete) THEN sum(actual_cost) END AS cost
    FROM previous_lines GROUP BY order_id
  ), current_products AS (
    SELECT product_id, min(product_name) AS name, min(sku) AS code,
      sum(quantity) AS quantity, sum(allocated_revenue) AS revenue,
      CASE WHEN bool_and(cost_complete) THEN sum(actual_cost) END AS cost,
      bool_and(cost_complete) AS cost_complete
    FROM current_lines WHERE product_id IS NOT NULL GROUP BY product_id
  ), daily AS (
    SELECT (finished_at AT TIME ZONE p_timezone)::date AS day,
      count(*) AS orders, sum(revenue) AS revenue,
      sum(cost) FILTER (WHERE cost_complete) AS cost,
      sum(revenue - cost) FILTER (WHERE cost_complete) AS profit
    FROM current_orders GROUP BY (finished_at AT TIME ZONE p_timezone)::date
  ), days AS (
    SELECT value::date AS day FROM generate_series(
      (p_from AT TIME ZONE p_timezone)::date,
      ((p_to - interval '1 second') AT TIME ZONE p_timezone)::date,
      interval '1 day') AS value
  ), board_totals AS (
    SELECT board_id, max(board_name) AS name, count(*) AS orders, sum(revenue) AS revenue,
      sum(cost) FILTER (WHERE cost_complete) AS cost,
      sum(revenue - cost) FILTER (WHERE cost_complete) AS profit,
      sum(revenue) FILTER (WHERE cost_complete) AS costed_revenue
    FROM current_orders GROUP BY board_id
  ), pareto_base AS (
    SELECT *, sum(greatest(coalesce(revenue - cost, 0), 0)) OVER () AS total_positive_profit,
      sum(greatest(coalesce(revenue - cost, 0), 0)) OVER (ORDER BY greatest(coalesce(revenue - cost, 0), 0) DESC, name) AS accumulated_profit
    FROM current_products
  )
  SELECT jsonb_build_object(
    'summary', jsonb_build_object(
      'orders', coalesce((SELECT count(*) FROM current_orders), 0),
      'revenue', coalesce((SELECT sum(revenue) FROM current_orders), 0),
      'cost', coalesce((SELECT sum(cost) FILTER (WHERE cost_complete) FROM current_orders), 0),
      'profit', coalesce((SELECT sum(revenue - cost) FILTER (WHERE cost_complete) FROM current_orders), 0),
      'costedRevenue', coalesce((SELECT sum(revenue) FILTER (WHERE cost_complete) FROM current_orders), 0),
      'margin', coalesce(round((SELECT sum(revenue - cost) FILTER (WHERE cost_complete) FROM current_orders)
        / nullif((SELECT sum(revenue) FILTER (WHERE cost_complete) FROM current_orders), 0) * 100, 2), 0),
      'markup', coalesce(round((SELECT sum(revenue - cost) FILTER (WHERE cost_complete) FROM current_orders)
        / nullif((SELECT sum(cost) FILTER (WHERE cost_complete) FROM current_orders), 0) * 100, 2), 0),
      'averageTicket', coalesce(round((SELECT sum(revenue) FROM current_orders)
        / nullif((SELECT count(*) FROM current_orders), 0), 2), 0),
      'openPotential', coalesce((SELECT sum(CASE WHEN o.suggested_total > 0
        THEN o.final_total * item.quantity * coalesce(item.unit_price_measure,item.unit_price) / o.suggested_total ELSE 0 END)
        FROM public.order_sales o JOIN public.order_sale_items item ON item.order_id=o.id
        LEFT JOIN public.order_catalog_items catalog ON catalog.id=item.catalog_item_id
        LEFT JOIN public.products product ON product.id=coalesce(item.product_id,catalog.product_id)
        WHERE o.stock_id=p_stock_id AND o.status IN ('waiting','preparing')
          AND o.created_at>=p_from AND o.created_at<p_to
          AND (coalesce(cardinality(p_board_ids),0)=0 OR o.board_id=ANY(p_board_ids))
          AND coalesce(item.source_stock_id,product.stock_id)=p_source_stock_id),0)
    ),
    'previous', jsonb_build_object(
      'orders', coalesce((SELECT count(*) FROM previous_orders), 0),
      'revenue', coalesce((SELECT sum(revenue) FROM previous_orders), 0),
      'cost', coalesce((SELECT sum(cost) FILTER (WHERE cost_complete) FROM previous_orders), 0),
      'profit', coalesce((SELECT sum(revenue - cost) FILTER (WHERE cost_complete) FROM previous_orders), 0),
      'costedRevenue', coalesce((SELECT sum(revenue) FILTER (WHERE cost_complete) FROM previous_orders), 0),
      'margin', coalesce(round((SELECT sum(revenue - cost) FILTER (WHERE cost_complete) FROM previous_orders)
        / nullif((SELECT sum(revenue) FILTER (WHERE cost_complete) FROM previous_orders), 0) * 100, 2), 0),
      'averageTicket', coalesce(round((SELECT sum(revenue) FROM previous_orders)
        / nullif((SELECT count(*) FROM previous_orders), 0), 2), 0)
    ),
    'series', coalesce((SELECT jsonb_agg(jsonb_build_object(
      'date', days.day, 'orders', coalesce(daily.orders, 0), 'revenue', coalesce(daily.revenue, 0),
      'cost', coalesce(daily.cost, 0), 'profit', coalesce(daily.profit, 0)
    ) ORDER BY days.day) FROM days LEFT JOIN daily ON daily.day = days.day), '[]'::jsonb),
    'boards', coalesce((SELECT jsonb_agg(jsonb_build_object(
      'id', board_id, 'name', name, 'orders', orders, 'revenue', revenue,
      'cost', coalesce(cost, 0), 'profit', coalesce(profit, 0),
      'margin', coalesce(round(profit / nullif(costed_revenue, 0) * 100, 2), 0),
      'averageTicket', round(revenue / nullif(orders, 0), 2)
    ) ORDER BY profit DESC NULLS LAST, name) FROM board_totals), '[]'::jsonb),
    'rankings', jsonb_build_object(
      'byQuantity', coalesce((SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'name', name,
        'code', code, 'quantity', quantity, 'revenue', revenue, 'profit', coalesce(revenue - cost, 0)) ORDER BY quantity DESC, name)
        FROM (SELECT * FROM current_products ORDER BY quantity DESC, name LIMIT 5) ranked), '[]'::jsonb),
      'byRevenue', coalesce((SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'name', name,
        'code', code, 'quantity', quantity, 'revenue', revenue, 'profit', coalesce(revenue - cost, 0)) ORDER BY revenue DESC, name)
        FROM (SELECT * FROM current_products ORDER BY revenue DESC, name LIMIT 5) ranked), '[]'::jsonb),
      'byProfit', coalesce((SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'name', name,
        'code', code, 'quantity', quantity, 'revenue', revenue, 'profit', coalesce(revenue - cost, 0)) ORDER BY profit DESC NULLS LAST, name)
        FROM (SELECT *, revenue - cost AS profit FROM current_products ORDER BY revenue - cost DESC NULLS LAST, name LIMIT 5) ranked), '[]'::jsonb)
    ),
    'pareto', coalesce((SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'name', name,
      'profit', coalesce(revenue - cost, 0), 'accumulatedPercent', coalesce(round(accumulated_profit / nullif(total_positive_profit, 0) * 100, 2), 0))
      ORDER BY accumulated_profit) FROM pareto_base), '[]'::jsonb),
    'quality', jsonb_build_object(
      'finishedOrders', coalesce((SELECT count(*) FROM current_orders), 0),
      'costCompleteOrders', coalesce((SELECT count(*) FROM current_orders WHERE cost_complete), 0),
      'coveragePercent', coalesce(round((SELECT count(*) FILTER (WHERE cost_complete) FROM current_orders)::numeric
        / nullif((SELECT count(*) FROM current_orders), 0) * 100, 2), 100)
    )
  ) INTO result;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_analytics_unit_rankings_source_stock(
  p_stock_id uuid,p_board_ids uuid[],p_from timestamptz,p_to timestamptz,p_source_stock_id uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  -- Source stock may belong to a different account; only filter order items already imported into p_stock_id.
  IF p_from IS NULL OR p_to IS NULL OR p_to<=p_from OR p_to-p_from>interval '366 days' THEN
    RAISE EXCEPTION 'Intervalo de análise inválido.' USING ERRCODE='22023';
  END IF;
  WITH lines AS (
    SELECT * FROM public.order_analytics_lines_for_source_stock(p_stock_id,p_board_ids,p_from,p_to,p_source_stock_id)
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

CREATE OR REPLACE FUNCTION public.orders_inventory_health_source_stock(
  p_stock_id uuid,p_board_ids uuid[],p_from timestamptz,p_to timestamptz,p_source_stock_id uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  -- Source stock may belong to a different account; only filter order items already imported into p_stock_id.
  IF p_from IS NULL OR p_to IS NULL OR p_to<=p_from OR p_to-p_from>interval '366 days' THEN
    RAISE EXCEPTION 'Intervalo de análise inválido.' USING ERRCODE='22023';
  END IF;
  WITH scoped_orders AS (
    SELECT o.id,o.inventory_status FROM public.order_sales o
    WHERE o.stock_id=p_stock_id AND o.status='finished' AND o.finished_at>=p_from AND o.finished_at<p_to
      AND (coalesce(cardinality(p_board_ids),0)=0 OR o.board_id=ANY(p_board_ids))
      AND EXISTS (
        SELECT 1 FROM public.order_sale_items filter_item
        LEFT JOIN public.order_catalog_items filter_catalog ON filter_catalog.id=filter_item.catalog_item_id
        LEFT JOIN public.products filter_product ON filter_product.id=coalesce(filter_item.product_id,filter_catalog.product_id)
        WHERE filter_item.order_id=o.id
          AND coalesce(filter_item.source_stock_id,filter_product.stock_id)=p_source_stock_id
      )
  ), scoped_items AS (
    SELECT i.* FROM public.order_sale_items i JOIN scoped_orders o ON o.id=i.order_id
    LEFT JOIN public.order_catalog_items catalog ON catalog.id=i.catalog_item_id
    LEFT JOIN public.products product ON product.id=coalesce(i.product_id,catalog.product_id)
    WHERE coalesce(i.source_stock_id,product.stock_id)=p_source_stock_id
  ), pending AS (
    SELECT s.*,i.product_name FROM public.order_inventory_settlements s
    JOIN scoped_items i ON i.id=s.order_item_id WHERE s.pending_quantity>0
  )
  SELECT jsonb_build_object(
    'finishedOrders',(SELECT count(*) FROM scoped_orders),
    'settledOrders',(SELECT count(*) FROM scoped_orders WHERE inventory_status='settled'),
    'partialOrders',(SELECT count(*) FROM scoped_orders WHERE inventory_status='partial'),
    'pendingOrders',(SELECT count(*) FROM scoped_orders WHERE inventory_status='pending'),
    'pendingItems',(SELECT count(*) FROM pending),
    'manualCostItems',(SELECT count(*) FROM scoped_items WHERE cost_source IN ('manual','mixed')),
    'missingCostItems',(SELECT count(*) FROM scoped_items WHERE cost_source='missing'),
    'alerts',coalesce((SELECT jsonb_agg(jsonb_build_object(
      'productName',alert.product_name,'quantity',alert.pending_quantity,'settledQuantity',alert.settled_quantity,
      'unit',alert.requested_unit,'message',alert.issue_message
    ) ORDER BY alert.created_at DESC)
      FROM (SELECT * FROM pending ORDER BY created_at DESC LIMIT 5) alert),'[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_analytics_estimate_summary_source_stock(
  p_stock_id uuid,p_board_ids uuid[],p_from timestamptz,p_to timestamptz,p_source_stock_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  -- Source stock may belong to a different account; only filter order items already imported into p_stock_id.
  IF p_from IS NULL OR p_to IS NULL OR p_to<=p_from OR p_to-p_from>interval '366 days' THEN
    RAISE EXCEPTION 'Intervalo de análise inválido.' USING ERRCODE='22023';
  END IF;
  SELECT jsonb_build_object(
    'estimatedOrders',count(DISTINCT o.id),
    'estimatedItems',count(i.id),
    'estimatedCost',coalesce(sum(i.final_cost_snapshot),0)
  ) INTO result
  FROM public.order_sales o JOIN public.order_sale_items i ON i.order_id=o.id
  LEFT JOIN public.order_catalog_items catalog ON catalog.id=i.catalog_item_id
  LEFT JOIN public.products product ON product.id=coalesce(i.product_id,catalog.product_id)
  WHERE o.stock_id=p_stock_id AND o.status='finished' AND o.finished_at>=p_from AND o.finished_at<p_to
    AND (coalesce(cardinality(p_board_ids),0)=0 OR o.board_id=ANY(p_board_ids))
    AND coalesce(i.source_stock_id,product.stock_id)=p_source_stock_id
    AND i.cost_source='catalog_estimate';
  RETURN result;
END $$;


REVOKE ALL ON FUNCTION public.order_analytics_lines_for_source_stock(uuid,uuid[],timestamptz,timestamptz,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.orders_analytics_overview_source_stock(uuid,uuid[],timestamptz,timestamptz,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.orders_analytics_overview_source_stock(uuid,uuid[],timestamptz,timestamptz,uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.orders_analytics_unit_rankings_source_stock(uuid,uuid[],timestamptz,timestamptz,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.orders_analytics_unit_rankings_source_stock(uuid,uuid[],timestamptz,timestamptz,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.orders_inventory_health_source_stock(uuid,uuid[],timestamptz,timestamptz,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.orders_inventory_health_source_stock(uuid,uuid[],timestamptz,timestamptz,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.orders_analytics_estimate_summary_source_stock(uuid,uuid[],timestamptz,timestamptz,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.orders_analytics_estimate_summary_source_stock(uuid,uuid[],timestamptz,timestamptz,uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
