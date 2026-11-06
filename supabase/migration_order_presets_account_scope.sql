-- Make saved import presets account-wide while leaving each board's catalog scoped to that board.
-- Existing stock-scoped presets, products and prices are preserved.
BEGIN;

ALTER TABLE public.order_item_presets
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE;

UPDATE public.order_item_presets AS preset
SET user_id = stock.user_id
FROM public.stocks AS stock
WHERE stock.id = preset.stock_id
  AND preset.user_id IS NULL;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.order_item_presets WHERE user_id IS NULL) THEN
    RAISE EXCEPTION 'Não foi possível associar todos os presets à conta dona do estoque.';
  END IF;
END;
$$;

ALTER TABLE public.order_item_presets
  ALTER COLUMN user_id SET NOT NULL;

-- Keep same-named presets from separate stocks as distinct presets with clear names.
WITH ranked AS (
  SELECT preset.id, stock.name AS stock_name,
    row_number() OVER (
      PARTITION BY preset.user_id, lower(preset.name)
      ORDER BY preset.created_at, preset.id
    ) AS duplicate_number
  FROM public.order_item_presets AS preset
  LEFT JOIN public.stocks AS stock ON stock.id = preset.stock_id
)
UPDATE public.order_item_presets AS preset
SET name = left(preset.name, 50) || ' (' || left(coalesce(ranked.stock_name, 'Estoque'), 12)
  || '-' || right(preset.id::text, 8) || ')'
FROM ranked
WHERE ranked.id = preset.id
  AND ranked.duplicate_number > 1;

CREATE UNIQUE INDEX IF NOT EXISTS order_item_presets_user_name
  ON public.order_item_presets(user_id, lower(name));

COMMENT ON COLUMN public.order_item_presets.user_id IS
  'Supabase Auth account that owns the preset; determines visibility across all of the account''s stocks.';
COMMENT ON COLUMN public.order_item_presets.stock_id IS
  'Legacy origin stock for compatibility and audit only; presets are scoped by user_id.';

CREATE OR REPLACE FUNCTION public.order_presets_list(p_stock_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb; owner_id uuid;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  owner_id := auth.uid();

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', preset.id,
    'name', preset.name,
    'createdAt', preset.created_at,
    'updatedAt', preset.updated_at,
    'items', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'sourceProductId', item.product_id,
        'sourceStockId', product.stock_id,
        'price', item.price
      ) ORDER BY product.name, item.product_id)
      FROM public.order_item_preset_items AS item
      JOIN public.products AS product ON product.id = item.product_id
      WHERE item.preset_id = preset.id
    ), '[]'::jsonb)
  ) ORDER BY preset.name), '[]'::jsonb)
  INTO result
  FROM public.order_item_presets AS preset
  WHERE preset.user_id = owner_id;

  RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION public.order_presets_save(
  p_stock_id uuid,
  p_name text,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE clean_name text; entry jsonb; v_preset_id uuid; v_product_id uuid;
  v_source_stock_id uuid; v_price numeric; seen uuid[] := '{}'; result jsonb;
  owner_id uuid;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  owner_id := auth.uid();
  clean_name := btrim(coalesce(p_name, ''));

  IF length(clean_name) NOT BETWEEN 1 AND 80 OR p_items IS NULL
    OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
    OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Informe nome e selecione de 1 a 100 itens para o preset.' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.order_item_presets(user_id, stock_id, name, updated_at)
    VALUES (owner_id, p_stock_id, clean_name, now())
    ON CONFLICT (user_id, lower(name)) DO UPDATE
      SET name = EXCLUDED.name,
          stock_id = EXCLUDED.stock_id,
          updated_at = now()
    RETURNING id INTO v_preset_id;

  DELETE FROM public.order_item_preset_items AS preset_item
  WHERE preset_item.preset_id = v_preset_id;

  FOR entry IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(entry) <> 'object'
      OR jsonb_typeof(entry->'price') IS DISTINCT FROM 'number'
      OR nullif(entry->>'sourceProductId', '') IS NULL THEN
      RAISE EXCEPTION 'Item ou preço inválido no preset.' USING ERRCODE = '22023';
    END IF;

    v_product_id := (entry->>'sourceProductId')::uuid;
    v_price := (entry->>'price')::numeric;

    SELECT product.stock_id INTO v_source_stock_id
    FROM public.products AS product
    WHERE product.id = v_product_id AND product.active;

    IF v_source_stock_id IS NULL THEN
      RAISE EXCEPTION 'Produto inativo ou não encontrado.' USING ERRCODE = '22023';
    END IF;

    IF nullif(entry->>'sourceStockId', '') IS NOT NULL
      AND (entry->>'sourceStockId')::uuid IS DISTINCT FROM v_source_stock_id THEN
      RAISE EXCEPTION 'O produto não pertence ao estoque de origem informado.' USING ERRCODE = '22023';
    END IF;

    PERFORM public.assert_stock(v_source_stock_id);

    IF v_product_id = ANY(seen) OR v_price < 0 OR v_price > 99999999.99
      OR v_price <> round(v_price, 2) THEN
      RAISE EXCEPTION 'Item repetido, inativo ou preço inválido no preset.' USING ERRCODE = '22023';
    END IF;

    seen := array_append(seen, v_product_id);
    INSERT INTO public.order_item_preset_items(preset_id, product_id, price)
      VALUES (v_preset_id, v_product_id, v_price);
  END LOOP;

  SELECT preset_row.value INTO result
  FROM jsonb_array_elements(public.order_presets_list(p_stock_id)) AS preset_row(value)
  WHERE (preset_row.value->>'id')::uuid = v_preset_id;

  RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION public.order_presets_delete(
  p_stock_id uuid,
  p_preset_id uuid
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE deleted_id uuid; owner_id uuid;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  owner_id := auth.uid();

  DELETE FROM public.order_item_presets AS preset
  WHERE preset.id = p_preset_id AND preset.user_id = owner_id
  RETURNING preset.id INTO deleted_id;

  IF deleted_id IS NULL THEN
    RAISE EXCEPTION 'Preset não encontrado nesta conta.' USING ERRCODE = 'P0002';
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.order_presets_list(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.order_presets_save(uuid, text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.order_presets_delete(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_presets_list(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.order_presets_save(uuid, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.order_presets_delete(uuid, uuid) TO authenticated;

-- Preset data must only be accessed through ownership-checking RPCs in the monolith.
REVOKE ALL ON public.order_item_presets, public.order_item_preset_items
  FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
