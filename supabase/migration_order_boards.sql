-- Kanbans, board-scoped catalogs and reusable item presets.
-- Run after orders_monolith.sql in the same Supabase project as Estoque.
BEGIN;

CREATE TABLE IF NOT EXISTS public.order_boards (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stock_id uuid NOT NULL REFERENCES public.stocks(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  is_default boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, stock_id),
  UNIQUE (stock_id, name)
);
CREATE UNIQUE INDEX IF NOT EXISTS order_boards_one_default_per_stock
  ON public.order_boards(stock_id) WHERE is_default;
CREATE INDEX IF NOT EXISTS order_boards_stock_created
  ON public.order_boards(stock_id, created_at, id);

-- Keep all current orders and imported products visible in the original board.
INSERT INTO public.order_boards(stock_id, name, is_default)
SELECT s.id, 'Geral', true FROM public.stocks s
WHERE NOT EXISTS (SELECT 1 FROM public.order_boards b WHERE b.stock_id = s.id);

ALTER TABLE public.order_catalog_items ADD COLUMN IF NOT EXISTS board_id uuid;
UPDATE public.order_catalog_items c SET board_id = b.id
FROM public.order_boards b WHERE c.stock_id = b.stock_id AND b.is_default
  AND c.board_id IS NULL;
ALTER TABLE public.order_catalog_items ALTER COLUMN board_id SET NOT NULL;
ALTER TABLE public.order_sales ADD COLUMN IF NOT EXISTS board_id uuid;
UPDATE public.order_sales o SET board_id = b.id
FROM public.order_boards b WHERE o.stock_id = b.stock_id AND b.is_default
  AND o.board_id IS NULL;
ALTER TABLE public.order_sales ALTER COLUMN board_id SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.order_boards'::regclass
      AND conname = 'order_boards_id_stock_id_key') THEN
    ALTER TABLE public.order_boards ADD CONSTRAINT order_boards_id_stock_id_key UNIQUE (id, stock_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.order_catalog_items'::regclass
      AND conname = 'order_catalog_items_board_stock_fkey') THEN
    ALTER TABLE public.order_catalog_items ADD CONSTRAINT order_catalog_items_board_stock_fkey
      FOREIGN KEY (board_id, stock_id) REFERENCES public.order_boards(id, stock_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.order_sales'::regclass
      AND conname = 'order_sales_board_stock_fkey') THEN
    ALTER TABLE public.order_sales ADD CONSTRAINT order_sales_board_stock_fkey
      FOREIGN KEY (board_id, stock_id) REFERENCES public.order_boards(id, stock_id);
  END IF;
END $$;

ALTER TABLE public.order_catalog_items
  DROP CONSTRAINT IF EXISTS order_catalog_items_stock_id_product_id_key;
CREATE UNIQUE INDEX IF NOT EXISTS order_catalog_items_board_product
  ON public.order_catalog_items(board_id, product_id);
CREATE INDEX IF NOT EXISTS order_catalog_items_board ON public.order_catalog_items(board_id);
CREATE INDEX IF NOT EXISTS order_sales_board_created
  ON public.order_sales(board_id, created_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS public.order_item_presets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stock_id uuid NOT NULL REFERENCES public.stocks(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (stock_id, name)
);
CREATE TABLE IF NOT EXISTS public.order_item_preset_items (
  preset_id uuid NOT NULL REFERENCES public.order_item_presets(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  price numeric(12,2) NOT NULL CHECK (price >= 0 AND price <= 99999999.99),
  PRIMARY KEY (preset_id, product_id)
);
CREATE INDEX IF NOT EXISTS order_item_presets_stock_name
  ON public.order_item_presets(stock_id, name);

ALTER TABLE public.order_boards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_item_presets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_item_preset_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_boards, public.order_item_presets, public.order_item_preset_items
  FROM PUBLIC, anon, authenticated;

-- The existing Stock API keeps its legacy HTTP routes on the default board.
-- It receives read-only board access, still scoped by the stock ownership RLS policy.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stock_api') THEN
    EXECUTE 'GRANT SELECT ON public.order_boards TO stock_api';
    DROP POLICY IF EXISTS order_boards_stock_api ON public.order_boards;
    CREATE POLICY order_boards_stock_api ON public.order_boards
      FOR SELECT TO stock_api USING (public.owns_stock(stock_id));
  END IF;
END $$;

-- Board owner access remains behind SECURITY DEFINER functions and assert_stock.
CREATE OR REPLACE FUNCTION public.orders_board_ensure_default(p_stock_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result uuid;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT id INTO result FROM public.order_boards
    WHERE stock_id = p_stock_id AND is_default;
  IF result IS NULL THEN
    BEGIN
      INSERT INTO public.order_boards(stock_id, name, is_default)
        VALUES (p_stock_id, 'Geral', true) RETURNING id INTO result;
    EXCEPTION WHEN unique_violation THEN
      SELECT id INTO result FROM public.order_boards
        WHERE stock_id = p_stock_id AND is_default;
    END;
  END IF;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.order_boards_list(p_stock_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.orders_board_ensure_default(p_stock_id);
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id, 'name', b.name, 'isDefault', b.is_default,
    'orderCount', (SELECT count(*) FROM public.order_sales o WHERE o.board_id = b.id)
  ) ORDER BY b.is_default DESC, b.created_at, b.name), '[]'::jsonb)
  INTO result FROM public.order_boards b WHERE b.stock_id = p_stock_id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.order_boards_create(p_stock_id uuid, p_name text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE clean_name text; created public.order_boards;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  clean_name := btrim(coalesce(p_name, ''));
  IF length(clean_name) NOT BETWEEN 1 AND 80 THEN
    RAISE EXCEPTION 'O nome do kanban deve ter de 1 a 80 caracteres.' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.order_boards(stock_id, name)
    VALUES (p_stock_id, clean_name) RETURNING * INTO created;
  RETURN jsonb_build_object('id', created.id, 'name', created.name,
    'isDefault', created.is_default, 'orderCount', 0);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Já existe um kanban com esse nome neste estoque.' USING ERRCODE = '23505';
END $$;

CREATE OR REPLACE FUNCTION public.order_presets_list(p_stock_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id, 'name', p.name, 'createdAt', p.created_at, 'updatedAt', p.updated_at,
    'items', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'sourceProductId', i.product_id, 'price', i.price
      ) ORDER BY pr.name, i.product_id)
      FROM public.order_item_preset_items i
      JOIN public.products pr ON pr.id = i.product_id
      WHERE i.preset_id = p.id
    ), '[]'::jsonb)
  ) ORDER BY p.name), '[]'::jsonb)
  INTO result FROM public.order_item_presets p WHERE p.stock_id = p_stock_id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.order_presets_save(
  p_stock_id uuid, p_name text, p_items jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE clean_name text; entry jsonb; v_preset_id uuid; product_id uuid;
  item_price numeric; seen uuid[] := '{}'; result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  clean_name := btrim(coalesce(p_name, ''));
  IF length(clean_name) NOT BETWEEN 1 AND 80
    OR p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Informe nome e selecione de 1 a 100 itens para o preset.' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_items) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Informe nome e selecione de 1 a 100 itens para o preset.' USING ERRCODE = '22023';
  END IF;
  PERFORM 1 FROM public.stocks WHERE id = p_stock_id FOR UPDATE;
  INSERT INTO public.order_item_presets(stock_id, name, updated_at)
    VALUES (p_stock_id, clean_name, now())
    ON CONFLICT (stock_id, name) DO UPDATE SET updated_at = now()
    RETURNING id INTO v_preset_id;
  DELETE FROM public.order_item_preset_items i WHERE i.preset_id = v_preset_id;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(entry) <> 'object'
      OR jsonb_typeof(entry->'price') IS DISTINCT FROM 'number'
      OR nullif(entry->>'sourceProductId', '') IS NULL THEN
      RAISE EXCEPTION 'Item ou preço inválido no preset.' USING ERRCODE = '22023';
    END IF;
    product_id := (entry->>'sourceProductId')::uuid;
    item_price := (entry->>'price')::numeric;
    IF product_id = ANY(seen) OR item_price < 0 OR item_price > 99999999.99
      OR item_price <> round(item_price, 2)
      OR NOT EXISTS (SELECT 1 FROM public.products p
        WHERE p.id = product_id AND p.stock_id = p_stock_id AND p.active) THEN
      RAISE EXCEPTION 'Item repetido, inativo ou preço inválido no preset.' USING ERRCODE = '22023';
    END IF;
    seen := array_append(seen, product_id);
    INSERT INTO public.order_item_preset_items(preset_id, product_id, price)
      VALUES (v_preset_id, product_id, item_price);
  END LOOP;
  SELECT p.value INTO result FROM jsonb_array_elements(
    public.order_presets_list(p_stock_id)
  ) AS p(value) WHERE (p.value->>'id')::uuid = v_preset_id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_catalog_board(p_stock_id uuid, p_board_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF NOT EXISTS (SELECT 1 FROM public.order_boards WHERE id = p_board_id AND stock_id = p_stock_id) THEN
    RAISE EXCEPTION 'Kanban não encontrado neste estoque.' USING ERRCODE = 'P0002';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'sourceProductId', c.product_id, 'sourceStockId', c.stock_id,
    'name', p.name, 'code', p.sku, 'category', coalesce(p.type_name, 'Sem categoria'),
    'isKit', p.is_kit, 'suggestedPrice', coalesce(p.suggested_sale_price, p.next_sale),
    'price', c.price, 'importedAt', c.imported_at
  ) ORDER BY p.name, c.id), '[]'::jsonb) INTO result
  FROM public.order_catalog_items c JOIN public.product_catalog p ON p.id = c.product_id
  WHERE c.stock_id = p_stock_id AND c.board_id = p_board_id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_import_catalog_board(
  p_stock_id uuid, p_board_id uuid, p_items jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE entry jsonb; product_id uuid; catalog_id uuid; price_value numeric;
  imported uuid[] := '{}'; seen uuid[] := '{}'; result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF NOT EXISTS (SELECT 1 FROM public.order_boards WHERE id = p_board_id AND stock_id = p_stock_id) THEN
    RAISE EXCEPTION 'Kanban não encontrado neste estoque.' USING ERRCODE = 'P0002';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Selecione de 1 a 100 produtos.' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_items) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Selecione de 1 a 100 produtos.' USING ERRCODE = '22023';
  END IF;
  PERFORM 1 FROM public.stocks WHERE id = p_stock_id FOR UPDATE;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(entry) <> 'object'
      OR jsonb_typeof(entry->'price') IS DISTINCT FROM 'number'
      OR nullif(entry->>'sourceProductId', '') IS NULL THEN
      RAISE EXCEPTION 'Produto ou preço inválido.' USING ERRCODE = '22023';
    END IF;
    product_id := (entry->>'sourceProductId')::uuid;
    price_value := (entry->>'price')::numeric;
    IF product_id = ANY(seen) OR price_value < 0 OR price_value > 99999999.99
      OR price_value <> round(price_value, 2) THEN
      RAISE EXCEPTION 'Produto repetido ou preço inválido.' USING ERRCODE = '22023';
    END IF;
    seen := array_append(seen, product_id);
    IF NOT EXISTS (SELECT 1 FROM public.products p
      WHERE p.id = product_id AND p.stock_id = p_stock_id AND p.active) THEN
      RAISE EXCEPTION 'Produto não encontrado ou inativo neste estoque.' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.order_catalog_items(stock_id, board_id, product_id, price)
      VALUES (p_stock_id, p_board_id, product_id, price_value)
      ON CONFLICT (board_id, product_id) DO UPDATE
        SET price = excluded.price, imported_at = now()
      RETURNING id INTO catalog_id;
    imported := array_append(imported, catalog_id);
  END LOOP;
  SELECT coalesce(jsonb_agg(row.value), '[]'::jsonb) INTO result
  FROM jsonb_array_elements(public.orders_catalog_board(p_stock_id, p_board_id)) AS row(value)
  WHERE (row.value->>'id')::uuid = ANY(imported);
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_update_price_board(
  p_stock_id uuid, p_board_id uuid, p_catalog_id uuid, p_price numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF p_price IS NULL OR p_price < 0 OR p_price > 99999999.99 OR p_price <> round(p_price, 2) THEN
    RAISE EXCEPTION 'Preço inválido.' USING ERRCODE = '22023';
  END IF;
  PERFORM 1 FROM public.stocks WHERE id = p_stock_id FOR UPDATE;
  UPDATE public.order_catalog_items SET price = p_price
    WHERE id = p_catalog_id AND stock_id = p_stock_id AND board_id = p_board_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produto importado não encontrado neste kanban.' USING ERRCODE = 'P0002'; END IF;
  SELECT row.value INTO result FROM jsonb_array_elements(
    public.orders_catalog_board(p_stock_id, p_board_id)
  ) AS row(value) WHERE (row.value->>'id')::uuid = p_catalog_id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_get_board(
  p_stock_id uuid, p_board_id uuid, p_order_id uuid
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'id', o.id, 'boardId', o.board_id, 'boardName', b.name,
    'number', o.number, 'customer', o.customer, 'note', o.note,
    'suggestedTotal', o.suggested_total, 'finalTotal', o.final_total, 'paid', o.paid,
    'status', o.status, 'createdAt', o.created_at, 'updatedAt', o.updated_at,
    'items', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'productId', coalesce(i.catalog_item_id::text, ''),
        'name', i.product_name, 'quantity', i.quantity, 'unitPrice', i.unit_price
      ) ORDER BY i.id) FROM public.order_sale_items i WHERE i.order_id = o.id
    ), '[]'::jsonb)
  ) INTO result
  FROM public.order_sales o JOIN public.order_boards b ON b.id = o.board_id
  WHERE o.id = p_order_id AND o.stock_id = p_stock_id AND o.board_id = p_board_id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_list_board(p_stock_id uuid, p_board_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF NOT EXISTS (SELECT 1 FROM public.order_boards WHERE id = p_board_id AND stock_id = p_stock_id) THEN
    RAISE EXCEPTION 'Kanban não encontrado neste estoque.' USING ERRCODE = 'P0002';
  END IF;
  SELECT coalesce(jsonb_agg(public.orders_get_board(p_stock_id, p_board_id, o.id)
    ORDER BY o.created_at DESC, o.id DESC), '[]'::jsonb) INTO result
  FROM public.order_sales o WHERE o.stock_id = p_stock_id AND o.board_id = p_board_id;
  RETURN result;
END $$;

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
    SELECT c.id, p.name, c.price INTO line
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
    SELECT c.id, p.name, c.price INTO line
      FROM public.order_catalog_items c JOIN public.products p ON p.id = c.product_id
      WHERE c.id = (entry->>'productId')::uuid AND c.stock_id = p_stock_id AND c.board_id = p_board_id;
    INSERT INTO public.order_sale_items(order_id, catalog_item_id, product_name, quantity, unit_price)
      VALUES (order_id, line.id, line.name, (entry->>'quantity')::integer, line.price);
  END LOOP;
  RETURN public.orders_get_board(p_stock_id, p_board_id, order_id);
END $$;

CREATE OR REPLACE FUNCTION public.orders_change_status_board(
  p_stock_id uuid, p_board_id uuid, p_order_id uuid, p_status text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE previous_status text; sold jsonb;
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
      WHERE i.order_id = p_order_id AND c.product_id IS NULL) THEN
      RAISE EXCEPTION 'Um produto deste pedido não existe mais no estoque.' USING ERRCODE = '23514';
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
      'product_id', c.product_id, 'quantity', i.quantity, 'unit', 'un'
    ) ORDER BY i.id) INTO sold
    FROM public.order_sale_items i
    JOIN public.order_catalog_items c ON c.id = i.catalog_item_id
    WHERE i.order_id = p_order_id;
    PERFORM public.decrement_inventory(p_stock_id, 'pedido:' || p_order_id || ':finalizado',
      jsonb_build_object('reason', 'Venda concluída no acompanhamento de pedidos', 'items', sold));
  END IF;
  UPDATE public.order_sales SET status = p_status, updated_at = now()
    WHERE id = p_order_id AND stock_id = p_stock_id AND board_id = p_board_id;
  RETURN public.orders_get_board(p_stock_id, p_board_id, p_order_id);
END $$;

-- Keep older callers operating on the default kanban where possible.
CREATE OR REPLACE FUNCTION public.orders_catalog(p_stock_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.orders_catalog_board(p_stock_id, public.orders_board_ensure_default(p_stock_id))
$$;
CREATE OR REPLACE FUNCTION public.orders_import_catalog(p_stock_id uuid, p_items jsonb)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.orders_import_catalog_board(
    p_stock_id, public.orders_board_ensure_default(p_stock_id), p_items)
$$;
CREATE OR REPLACE FUNCTION public.orders_update_price(
  p_stock_id uuid, p_catalog_id uuid, p_price numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE selected_board uuid;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT board_id INTO selected_board FROM public.order_catalog_items
    WHERE id = p_catalog_id AND stock_id = p_stock_id;
  IF selected_board IS NULL THEN RAISE EXCEPTION 'Produto importado não encontrado.' USING ERRCODE = 'P0002'; END IF;
  RETURN public.orders_update_price_board(p_stock_id, selected_board, p_catalog_id, p_price);
END $$;
CREATE OR REPLACE FUNCTION public.orders_create(p_stock_id uuid, p_data jsonb)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.orders_create_board(p_stock_id, public.orders_board_ensure_default(p_stock_id), p_data)
$$;
CREATE OR REPLACE FUNCTION public.orders_change_status(
  p_stock_id uuid, p_order_id uuid, p_status text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE selected_board uuid;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT board_id INTO selected_board FROM public.order_sales
    WHERE id = p_order_id AND stock_id = p_stock_id;
  IF selected_board IS NULL THEN RAISE EXCEPTION 'Pedido não encontrado.' USING ERRCODE = 'P0002'; END IF;
  RETURN public.orders_change_status_board(p_stock_id, selected_board, p_order_id, p_status);
END $$;

-- Realtime is limited by stock ownership and only exposes order rows to their owner.
DROP POLICY IF EXISTS order_sales_realtime_select ON public.order_sales;
CREATE POLICY order_sales_realtime_select ON public.order_sales
  FOR SELECT TO authenticated USING (public.owns_stock(stock_id));
GRANT SELECT ON public.order_sales TO authenticated;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
    AND NOT EXISTS (SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'order_sales') THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.order_sales';
  END IF;
END $$;

REVOKE ALL ON FUNCTION public.orders_board_ensure_default(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.orders_get_board(uuid,uuid,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.order_boards_list(uuid), public.order_boards_create(uuid,text),
  public.order_presets_list(uuid), public.order_presets_save(uuid,text,jsonb),
  public.orders_catalog_board(uuid,uuid), public.orders_import_catalog_board(uuid,uuid,jsonb),
  public.orders_update_price_board(uuid,uuid,uuid,numeric), public.orders_list_board(uuid,uuid),
  public.orders_create_board(uuid,uuid,jsonb), public.orders_change_status_board(uuid,uuid,uuid,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_boards_list(uuid), public.order_boards_create(uuid,text),
  public.order_presets_list(uuid), public.order_presets_save(uuid,text,jsonb),
  public.orders_catalog_board(uuid,uuid), public.orders_import_catalog_board(uuid,uuid,jsonb),
  public.orders_update_price_board(uuid,uuid,uuid,numeric), public.orders_list_board(uuid,uuid),
  public.orders_create_board(uuid,uuid,jsonb), public.orders_change_status_board(uuid,uuid,uuid,text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
