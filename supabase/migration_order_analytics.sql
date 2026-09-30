-- Analytics for completed orders. Apply after orders_monolith.sql and
-- migration_order_boards.sql in the same Supabase project as Estoque.
-- This migration is additive: FIFO movements remain the source of truth for cost.
BEGIN;

ALTER TABLE public.order_sales
  ADD COLUMN IF NOT EXISTS finished_at timestamptz,
  ADD COLUMN IF NOT EXISTS inventory_operation_id uuid REFERENCES public.inventory_operations(id);
ALTER TABLE public.order_sale_items
  ADD COLUMN IF NOT EXISTS product_id uuid REFERENCES public.products(id);

-- The operation used as cost source must belong to the same stock as the sale.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.inventory_operations'::regclass
    AND conname = 'inventory_operations_id_stock_id_key') THEN
    ALTER TABLE public.inventory_operations ADD CONSTRAINT inventory_operations_id_stock_id_key UNIQUE (id, stock_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.order_sales'::regclass
    AND conname = 'order_sales_inventory_operation_stock_fkey') THEN
    ALTER TABLE public.order_sales ADD CONSTRAINT order_sales_inventory_operation_stock_fkey
      FOREIGN KEY (inventory_operation_id, stock_id) REFERENCES public.inventory_operations(id, stock_id);
  END IF;
END $$;

-- Recover durable links for historical orders without inventing a cost.
UPDATE public.order_sale_items i
SET product_id = c.product_id
FROM public.order_catalog_items c
WHERE i.catalog_item_id = c.id AND i.product_id IS NULL;

UPDATE public.order_sales o
SET inventory_operation_id = operation.id,
    finished_at = coalesce(o.finished_at, operation.occurred_at)
FROM public.inventory_operations operation
WHERE o.status = 'finished'
  AND operation.stock_id = o.stock_id
  AND operation.reference = 'pedido:' || o.id || ':finalizado'
  AND o.inventory_operation_id IS NULL;

-- Legacy finished orders without a matching operation remain visible as
-- incomplete instead of disappearing from the financial history.
UPDATE public.order_sales
SET finished_at = updated_at
WHERE status = 'finished' AND finished_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS order_sales_inventory_operation_unique
  ON public.order_sales(inventory_operation_id) WHERE inventory_operation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS order_sales_analytics_finished
  ON public.order_sales(stock_id, finished_at DESC, id DESC) WHERE status = 'finished';
CREATE INDEX IF NOT EXISTS order_sales_analytics_board_finished
  ON public.order_sales(stock_id, board_id, finished_at DESC, id DESC) WHERE status = 'finished';
CREATE INDEX IF NOT EXISTS order_sale_items_analytics_product
  ON public.order_sale_items(product_id, order_id) WHERE product_id IS NOT NULL;

-- A finished order receives a direct link to its immutable FIFO operation.
CREATE OR REPLACE FUNCTION public.orders_create_board(
  p_stock_id uuid, p_board_id uuid, p_data jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE entry jsonb; order_id uuid; catalog_id uuid; line record; quantity integer;
  suggested numeric := 0; final_total numeric; paid_amount numeric;
  customer_name text; note_text text; seen uuid[] := '{}';
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF NOT EXISTS (SELECT 1 FROM public.order_boards WHERE id = p_board_id AND stock_id = p_stock_id) THEN
    RAISE EXCEPTION 'Kanban não encontrado neste estoque.' USING ERRCODE = 'P0002';
  END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data) IS DISTINCT FROM 'object'
    OR jsonb_typeof(p_data->'items') IS DISTINCT FROM 'array'
    OR jsonb_typeof(p_data->'finalTotal') IS DISTINCT FROM 'number'
    OR jsonb_typeof(p_data->'paid') IS DISTINCT FROM 'number' THEN
    RAISE EXCEPTION 'Pedido inválido.' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_data->'items') NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Inclua de 1 a 100 itens no pedido.' USING ERRCODE = '22023';
  END IF;
  customer_name := left(btrim(coalesce(p_data->>'customer', '')), 100);
  note_text := left(btrim(coalesce(p_data->>'note', '')), 500);
  final_total := (p_data->>'finalTotal')::numeric;
  paid_amount := (p_data->>'paid')::numeric;
  IF final_total < 0 OR paid_amount < 0 OR final_total > 99999999.99
    OR paid_amount > 99999999.99 OR final_total <> round(final_total, 2)
    OR paid_amount <> round(paid_amount, 2) THEN
    RAISE EXCEPTION 'Valores do pedido inválidos.' USING ERRCODE = '22023';
  END IF;
  PERFORM 1 FROM public.stocks WHERE id = p_stock_id FOR UPDATE;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
    IF jsonb_typeof(entry) IS DISTINCT FROM 'object'
      OR jsonb_typeof(entry->'quantity') IS DISTINCT FROM 'number'
      OR nullif(entry->>'productId', '') IS NULL THEN
      RAISE EXCEPTION 'Item inválido.' USING ERRCODE = '22023';
    END IF;
    catalog_id := (entry->>'productId')::uuid;
    quantity := (entry->>'quantity')::integer;
    IF (entry->>'quantity')::numeric <> quantity
      OR quantity NOT BETWEEN 1 AND 999 OR catalog_id = ANY(seen) THEN
      RAISE EXCEPTION 'Item repetido ou quantidade inválida.' USING ERRCODE = '22023';
    END IF;
    seen := array_append(seen, catalog_id);
    SELECT c.id, c.product_id, p.name, c.price INTO line
      FROM public.order_catalog_items c JOIN public.products p ON p.id = c.product_id
      WHERE c.id = catalog_id AND c.stock_id = p_stock_id
        AND c.board_id = p_board_id AND p.active;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Um item não pertence ao catálogo deste kanban.' USING ERRCODE = '22023';
    END IF;
    suggested := suggested + line.price * quantity;
  END LOOP;
  INSERT INTO public.order_sales(stock_id, board_id, customer, note, suggested_total, final_total, paid)
    VALUES (p_stock_id, p_board_id, customer_name, note_text, suggested, final_total, paid_amount)
    RETURNING id INTO order_id;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
    SELECT c.id, c.product_id, p.name, c.price INTO line
      FROM public.order_catalog_items c JOIN public.products p ON p.id = c.product_id
      WHERE c.id = (entry->>'productId')::uuid AND c.stock_id = p_stock_id AND c.board_id = p_board_id;
    INSERT INTO public.order_sale_items(order_id, catalog_item_id, product_id, product_name, quantity, unit_price)
      VALUES (order_id, line.id, line.product_id, line.name, (entry->>'quantity')::integer, line.price);
  END LOOP;
  RETURN public.orders_get_board(p_stock_id, p_board_id, order_id);
END $$;

CREATE OR REPLACE FUNCTION public.orders_change_status_board(
  p_stock_id uuid, p_board_id uuid, p_order_id uuid, p_status text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE previous_status text; sold jsonb; operation_id uuid;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT status INTO previous_status FROM public.order_sales
    WHERE id = p_order_id AND stock_id = p_stock_id AND board_id = p_board_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado neste kanban.' USING ERRCODE = 'P0002'; END IF;
  IF NOT (
    (previous_status = 'waiting' AND p_status IN ('preparing', 'cancelled'))
    OR (previous_status = 'preparing' AND p_status IN ('waiting', 'finished', 'cancelled'))
    OR (previous_status = 'cancelled' AND p_status = 'waiting')
  ) THEN
    RAISE EXCEPTION 'Transição de status inválida.' USING ERRCODE = '22023';
  END IF;
  IF p_status = 'finished' THEN
    IF EXISTS (SELECT 1 FROM public.order_sale_items i
      LEFT JOIN public.order_catalog_items c ON c.id = i.catalog_item_id
      WHERE i.order_id = p_order_id AND coalesce(i.product_id, c.product_id) IS NULL) THEN
      RAISE EXCEPTION 'Um produto deste pedido não existe mais no estoque.' USING ERRCODE = '23514';
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
      'product_id', coalesce(i.product_id, c.product_id), 'quantity', i.quantity, 'unit', 'un'
    ) ORDER BY i.id) INTO sold
    FROM public.order_sale_items i
    LEFT JOIN public.order_catalog_items c ON c.id = i.catalog_item_id
    WHERE i.order_id = p_order_id;
    SELECT public.decrement_inventory(p_stock_id, 'pedido:' || p_order_id || ':finalizado',
      jsonb_build_object('reason', 'Venda concluída no acompanhamento de pedidos', 'items', sold))
      INTO operation_id;
  END IF;
  UPDATE public.order_sales
  SET status = p_status,
      updated_at = now(),
      finished_at = CASE WHEN p_status = 'finished' THEN coalesce(finished_at, now()) ELSE finished_at END,
      inventory_operation_id = CASE WHEN p_status = 'finished' THEN coalesce(inventory_operation_id, operation_id) ELSE inventory_operation_id END
  WHERE id = p_order_id AND stock_id = p_stock_id AND board_id = p_board_id;
  RETURN public.orders_get_board(p_stock_id, p_board_id, p_order_id);
END $$;

-- Internal fact source. It returns one finished order line with its actual FIFO cost.
CREATE OR REPLACE FUNCTION public.order_analytics_lines(
  p_stock_id uuid, p_board_ids uuid[], p_from timestamptz, p_to timestamptz
)
RETURNS TABLE(
  order_id uuid, order_number bigint, board_id uuid, board_name text, customer text,
  created_at timestamptz, finished_at timestamptz, suggested_total numeric, final_total numeric,
  line_id uuid, product_id uuid, product_name text, sku text, is_kit boolean,
  quantity integer, unit_price numeric, listed_revenue numeric, allocated_revenue numeric,
  actual_cost numeric, cost_complete boolean
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from OR p_to - p_from > interval '366 days' THEN
    RAISE EXCEPTION 'Intervalo de análise inválido.' USING ERRCODE = '22023';
  END IF;
  IF coalesce(cardinality(p_board_ids), 0) > 0 AND EXISTS (
    SELECT 1 FROM unnest(p_board_ids) selected_board
    WHERE NOT EXISTS (SELECT 1 FROM public.order_boards b WHERE b.id = selected_board AND b.stock_id = p_stock_id)
  ) THEN
    RAISE EXCEPTION 'Kanban não pertence ao estoque selecionado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  WITH selected_orders AS (
    SELECT o.id, o.number, o.board_id, b.name AS board_name, o.customer, o.created_at,
      o.finished_at, o.suggested_total, o.final_total, o.inventory_operation_id
    FROM public.order_sales o
    JOIN public.order_boards b ON b.id = o.board_id
    WHERE o.stock_id = p_stock_id AND o.status = 'finished'
      AND o.finished_at >= p_from AND o.finished_at < p_to
      AND (coalesce(cardinality(p_board_ids), 0) = 0 OR o.board_id = ANY(p_board_ids))
  ), source_lines AS (
    SELECT o.*, i.id AS source_line_id, coalesce(i.product_id, catalog.product_id) AS source_product_id,
      i.product_name AS source_product_name, product.sku AS source_sku, coalesce(product.is_kit, false) AS source_is_kit,
      i.quantity AS source_quantity, i.unit_price AS source_unit_price,
      i.quantity * i.unit_price AS source_listed_revenue,
      count(*) OVER (PARTITION BY o.id) AS line_count,
      row_number() OVER (PARTITION BY o.id ORDER BY i.id) AS line_position,
      sum(i.quantity) OVER (PARTITION BY o.id) AS quantity_total
    FROM selected_orders o
    JOIN public.order_sale_items i ON i.order_id = o.id
    LEFT JOIN public.order_catalog_items catalog ON catalog.id = i.catalog_item_id
    LEFT JOIN public.products product ON product.id = coalesce(i.product_id, catalog.product_id)
  ), raw_allocations AS (
    SELECT source_lines.*,
      CASE WHEN suggested_total > 0 THEN final_total * source_listed_revenue / suggested_total
        WHEN quantity_total > 0 THEN final_total * source_quantity / quantity_total
        ELSE 0 END AS raw_revenue
    FROM source_lines
  ), allocations AS (
    SELECT raw_allocations.*,
      CASE WHEN line_position = line_count THEN final_total - coalesce(
        sum(round(raw_revenue, 2)) OVER (PARTITION BY id ORDER BY source_line_id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
      ELSE round(raw_revenue, 2) END AS line_revenue
    FROM raw_allocations
  ), costs AS (
    SELECT o.id AS cost_order_id, operation_item.product_id AS cost_product_id,
      sum(abs(movement.quantity) * movement.cost_per_base) AS total_cost
    FROM selected_orders o
    JOIN public.inventory_operation_items operation_item ON operation_item.operation_id = o.inventory_operation_id
    JOIN public.inventory_movements movement ON movement.item_id = operation_item.id
    GROUP BY o.id, operation_item.product_id
  )
  SELECT a.id, a.number, a.board_id, a.board_name, a.customer, a.created_at, a.finished_at,
    a.suggested_total, a.final_total, a.source_line_id, a.source_product_id,
    a.source_product_name, a.source_sku, a.source_is_kit, a.source_quantity,
    a.source_unit_price, a.source_listed_revenue, a.line_revenue,
    CASE WHEN a.inventory_operation_id IS NOT NULL AND a.source_product_id IS NOT NULL
      AND costs.cost_order_id IS NOT NULL THEN costs.total_cost ELSE NULL END,
    a.inventory_operation_id IS NOT NULL AND a.source_product_id IS NOT NULL AND costs.cost_order_id IS NOT NULL
  FROM allocations a
  LEFT JOIN costs ON costs.cost_order_id = a.id AND costs.cost_product_id = a.source_product_id;
END $$;

CREATE OR REPLACE FUNCTION public.orders_analytics_overview(
  p_stock_id uuid, p_board_ids uuid[], p_from timestamptz, p_to timestamptz,
  p_timezone text DEFAULT 'America/Sao_Paulo'
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb; previous_from timestamptz := p_from - (p_to - p_from);
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF p_timezone IS DISTINCT FROM 'America/Sao_Paulo' THEN
    RAISE EXCEPTION 'Fuso horário não suportado.' USING ERRCODE = '22023';
  END IF;
  WITH current_lines AS (
    SELECT * FROM public.order_analytics_lines(p_stock_id, p_board_ids, p_from, p_to)
  ), previous_lines AS (
    SELECT * FROM public.order_analytics_lines(p_stock_id, p_board_ids, previous_from, p_from)
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
      'openPotential', coalesce((SELECT sum(final_total) FROM public.order_sales o
        WHERE o.stock_id = p_stock_id AND o.status IN ('waiting', 'preparing')
          AND o.created_at >= p_from AND o.created_at < p_to
          AND (coalesce(cardinality(p_board_ids), 0) = 0 OR o.board_id = ANY(p_board_ids))), 0)
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

CREATE OR REPLACE FUNCTION public.orders_analytics_products(
  p_stock_id uuid, p_board_ids uuid[], p_from timestamptz, p_to timestamptz,
  p_search text DEFAULT NULL, p_kind text DEFAULT 'all', p_sort text DEFAULT 'profit',
  p_direction text DEFAULT 'desc', p_limit integer DEFAULT 50, p_offset integer DEFAULT 0
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb; previous_from timestamptz := p_from - (p_to - p_from); period_days numeric;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF p_kind NOT IN ('all', 'product', 'kit') OR p_sort NOT IN ('profit', 'revenue', 'quantity', 'margin', 'name')
    OR p_direction NOT IN ('asc', 'desc') OR p_limit NOT BETWEEN 1 AND 100 OR p_offset NOT BETWEEN 0 AND 10000 THEN
    RAISE EXCEPTION 'Filtros de produtos inválidos.' USING ERRCODE = '22023';
  END IF;
  period_days := greatest(1, extract(epoch FROM p_to - p_from) / 86400);
  WITH current_lines AS (
    SELECT * FROM public.order_analytics_lines(p_stock_id, p_board_ids, p_from, p_to)
  ), previous_lines AS (
    SELECT * FROM public.order_analytics_lines(p_stock_id, p_board_ids, previous_from, p_from)
  ), current_product AS (
    SELECT product_id, min(product_name) AS name, min(sku) AS code, bool_or(is_kit) AS is_kit,
      count(DISTINCT order_id) AS orders, sum(quantity) AS quantity, sum(listed_revenue) AS listed_revenue,
      sum(allocated_revenue) AS revenue, bool_and(cost_complete) AS cost_complete,
      CASE WHEN bool_and(cost_complete) THEN sum(actual_cost) END AS cost, max(finished_at) AS last_sale_at
    FROM current_lines WHERE product_id IS NOT NULL GROUP BY product_id
  ), previous_product AS (
    SELECT product_id, sum(quantity) AS quantity, sum(allocated_revenue) AS revenue,
      CASE WHEN bool_and(cost_complete) THEN sum(actual_cost) END AS cost
    FROM previous_lines WHERE product_id IS NOT NULL GROUP BY product_id
  ), merged AS (
    SELECT current_product.*, coalesce(previous_product.quantity, 0) AS previous_quantity,
      coalesce(previous_product.revenue, 0) AS previous_revenue,
      CASE WHEN previous_product.cost IS NULL THEN NULL ELSE previous_product.revenue - previous_product.cost END AS previous_profit,
      coalesce(catalog.whole_units, 0) AS stock_whole_units
    FROM current_product
    LEFT JOIN previous_product ON previous_product.product_id = current_product.product_id
    LEFT JOIN public.product_catalog catalog ON catalog.id = current_product.product_id
  ), calculated AS (
    SELECT merged.*, round(quantity / period_days, 4) AS daily_velocity,
      CASE WHEN quantity > 0 THEN round(stock_whole_units / (quantity / period_days), 2) END AS coverage_days,
      CASE WHEN cost_complete THEN revenue - cost END AS profit,
      CASE WHEN cost_complete THEN round((revenue - cost) / nullif(revenue, 0) * 100, 2) END AS margin,
      CASE WHEN cost_complete THEN round((revenue - cost) / nullif(cost, 0) * 100, 2) END AS markup,
      round(revenue / nullif(quantity, 0), 2) AS average_price,
      round((revenue / nullif(listed_revenue, 0) - 1) * 100, 2) AS adjustment_percent
    FROM merged
  ), filtered AS (
    SELECT * FROM calculated
    WHERE (p_kind = 'all' OR (p_kind = 'kit') = is_kit)
      AND (nullif(btrim(coalesce(p_search, '')), '') IS NULL
        OR lower(name || ' ' || coalesce(code, '')) LIKE '%' || lower(btrim(p_search)) || '%')
  ), paged AS (
    SELECT * FROM filtered
    ORDER BY
      CASE WHEN p_sort = 'name' AND p_direction = 'asc' THEN name END ASC NULLS LAST,
      CASE WHEN p_sort = 'name' AND p_direction = 'desc' THEN name END DESC NULLS LAST,
      CASE WHEN p_sort = 'profit' AND p_direction = 'asc' THEN profit END ASC NULLS LAST,
      CASE WHEN p_sort = 'profit' AND p_direction = 'desc' THEN profit END DESC NULLS LAST,
      CASE WHEN p_sort = 'revenue' AND p_direction = 'asc' THEN revenue END ASC NULLS LAST,
      CASE WHEN p_sort = 'revenue' AND p_direction = 'desc' THEN revenue END DESC NULLS LAST,
      CASE WHEN p_sort = 'quantity' AND p_direction = 'asc' THEN quantity END ASC NULLS LAST,
      CASE WHEN p_sort = 'quantity' AND p_direction = 'desc' THEN quantity END DESC NULLS LAST,
      CASE WHEN p_sort = 'margin' AND p_direction = 'asc' THEN margin END ASC NULLS LAST,
      CASE WHEN p_sort = 'margin' AND p_direction = 'desc' THEN margin END DESC NULLS LAST,
      name ASC
    LIMIT p_limit OFFSET p_offset
  )
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM filtered),
    'periodDays', period_days,
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
      'productId', product_id, 'name', name, 'code', code, 'isKit', is_kit, 'orders', orders,
      'quantity', quantity, 'revenue', revenue, 'cost', cost, 'profit', profit, 'margin', margin,
      'markup', markup, 'averagePrice', average_price, 'adjustmentPercent', adjustment_percent,
      'stockWholeUnits', stock_whole_units, 'dailyVelocity', daily_velocity, 'coverageDays', coverage_days,
      'lastSaleAt', last_sale_at, 'previousQuantity', previous_quantity, 'previousRevenue', previous_revenue,
      'previousProfit', previous_profit, 'costComplete', cost_complete
    ) ORDER BY name) FROM paged), '[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_analytics_orders(
  p_stock_id uuid, p_board_ids uuid[], p_from timestamptz, p_to timestamptz,
  p_limit integer DEFAULT 50, p_offset integer DEFAULT 0
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF p_limit NOT BETWEEN 1 AND 100 OR p_offset NOT BETWEEN 0 AND 10000 THEN
    RAISE EXCEPTION 'Paginação inválida.' USING ERRCODE = '22023';
  END IF;
  WITH lines AS (
    SELECT * FROM public.order_analytics_lines(p_stock_id, p_board_ids, p_from, p_to)
  ), totals AS (
    SELECT order_id, max(order_number) AS number, min(board_id::text)::uuid AS board_id, max(board_name) AS board_name,
      max(customer) AS customer, max(created_at) AS created_at, max(finished_at) AS finished_at,
      max(suggested_total) AS suggested_total, max(final_total) AS final_total,
      count(*) AS line_count, sum(quantity) AS item_quantity, sum(allocated_revenue) AS revenue,
      bool_and(cost_complete) AS cost_complete, CASE WHEN bool_and(cost_complete) THEN sum(actual_cost) END AS cost
    FROM lines GROUP BY order_id
  ), paged AS (
    SELECT * FROM totals ORDER BY finished_at DESC, number DESC LIMIT p_limit OFFSET p_offset
  )
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM totals),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
      'orderId', order_id, 'number', number, 'boardId', board_id, 'boardName', board_name,
      'customer', customer, 'createdAt', created_at, 'finishedAt', finished_at,
      'suggestedTotal', suggested_total, 'finalTotal', final_total, 'lineCount', line_count,
      'itemQuantity', item_quantity, 'revenue', revenue, 'cost', cost,
      'profit', CASE WHEN cost_complete THEN revenue - cost END,
      'margin', CASE WHEN cost_complete THEN round((revenue - cost) / nullif(revenue, 0) * 100, 2) END,
      'adjustmentPercent', round((final_total / nullif(suggested_total, 0) - 1) * 100, 2),
      'costComplete', cost_complete
    ) ORDER BY finished_at DESC, number DESC) FROM paged), '[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_analytics_order_detail(p_stock_id uuid, p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb; completed_at timestamptz;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT finished_at INTO completed_at FROM public.order_sales
    WHERE id = p_order_id AND stock_id = p_stock_id AND status = 'finished';
  IF completed_at IS NULL THEN RAISE EXCEPTION 'Pedido finalizado não encontrado.' USING ERRCODE = 'P0002'; END IF;
  WITH lines AS (
    SELECT * FROM public.order_analytics_lines(p_stock_id, NULL, completed_at - interval '1 microsecond', completed_at + interval '1 microsecond')
    WHERE order_id = p_order_id
  ), header AS (
    SELECT max(order_number) AS number, max(board_name) AS board_name, max(customer) AS customer,
      max(created_at) AS created_at, max(finished_at) AS finished_at, max(final_total) AS final_total,
      sum(allocated_revenue) AS revenue, bool_and(cost_complete) AS cost_complete,
      CASE WHEN bool_and(cost_complete) THEN sum(actual_cost) END AS cost
    FROM lines
  )
  SELECT jsonb_build_object(
    'order', (SELECT jsonb_build_object('number', number, 'boardName', board_name, 'customer', customer,
      'createdAt', created_at, 'finishedAt', finished_at, 'finalTotal', final_total, 'revenue', revenue,
      'cost', cost, 'profit', CASE WHEN cost_complete THEN revenue - cost END,
      'margin', CASE WHEN cost_complete THEN round((revenue - cost) / nullif(revenue, 0) * 100, 2) END,
      'costComplete', cost_complete) FROM header),
    'items', coalesce((SELECT jsonb_agg(jsonb_build_object(
      'productId', line.product_id, 'name', line.product_name, 'code', line.sku, 'isKit', line.is_kit,
      'quantity', line.quantity, 'unitPrice', line.unit_price, 'listedRevenue', line.listed_revenue,
      'revenue', line.allocated_revenue, 'cost', line.actual_cost,
      'profit', CASE WHEN line.cost_complete THEN line.allocated_revenue - line.actual_cost END,
      'margin', CASE WHEN line.cost_complete THEN round((line.allocated_revenue - line.actual_cost) / nullif(line.allocated_revenue, 0) * 100, 2) END,
      'costComplete', line.cost_complete,
      'lots', coalesce((SELECT jsonb_agg(jsonb_build_object('lotId', lot.id, 'code', lot.code,
        'quantityBase', abs(movement.quantity), 'cost', abs(movement.quantity) * movement.cost_per_base)
        ORDER BY lot.acquired_at, lot.id)
        FROM public.order_sales sale
        JOIN public.inventory_operation_items operation_item ON operation_item.operation_id = sale.inventory_operation_id
        JOIN public.inventory_movements movement ON movement.item_id = operation_item.id
        JOIN public.stock_lots lot ON lot.id = movement.lot_id
        WHERE sale.id = p_order_id AND operation_item.product_id = line.product_id), '[]'::jsonb)
    ) ORDER BY line.product_name) FROM lines line), '[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;

REVOKE ALL ON FUNCTION public.order_analytics_lines(uuid,uuid[],timestamptz,timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.orders_analytics_overview(uuid,uuid[],timestamptz,timestamptz,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.orders_analytics_products(uuid,uuid[],timestamptz,timestamptz,text,text,text,text,integer,integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.orders_analytics_orders(uuid,uuid[],timestamptz,timestamptz,integer,integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.orders_analytics_order_detail(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.orders_analytics_overview(uuid,uuid[],timestamptz,timestamptz,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.orders_analytics_products(uuid,uuid[],timestamptz,timestamptz,text,text,text,text,integer,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.orders_analytics_orders(uuid,uuid[],timestamptz,timestamptz,integer,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.orders_analytics_order_detail(uuid,uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
