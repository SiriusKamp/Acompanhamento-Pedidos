-- Keep the cross-stock import RPC's PL/pgSQL variable distinct from the product_id column.
CREATE OR REPLACE FUNCTION public.orders_import_catalog_board(p_stock_id uuid,p_board_id uuid,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb; v_product_id uuid; source_stock_id uuid; catalog_id uuid; price_value numeric;
  cost_value numeric; imported uuid[]:='{}'; seen uuid[]:='{}'; result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF NOT EXISTS(SELECT 1 FROM public.order_boards WHERE id=p_board_id AND stock_id=p_stock_id) THEN
    RAISE EXCEPTION 'Kanban não encontrado neste estoque.' USING ERRCODE='P0002';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
    OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Selecione de 1 a 100 produtos.' USING ERRCODE='22023';
  END IF;
  PERFORM 1 FROM public.stocks WHERE id=p_stock_id FOR UPDATE;
  FOR e IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(e)<>'object' OR jsonb_typeof(e->'price') IS DISTINCT FROM 'number'
      OR nullif(e->>'sourceProductId','') IS NULL THEN
      RAISE EXCEPTION 'Produto ou preço inválido.' USING ERRCODE='22023';
    END IF;
    v_product_id:=(e->>'sourceProductId')::uuid;
    price_value:=(e->>'price')::numeric;
    cost_value:=CASE WHEN jsonb_typeof(e->'unitCost')='number' THEN (e->>'unitCost')::numeric ELSE NULL END;
    SELECT p.stock_id INTO source_stock_id FROM public.products p WHERE p.id=v_product_id;
    IF source_stock_id IS NULL THEN RAISE EXCEPTION 'Produto não encontrado.' USING ERRCODE='22023'; END IF;
    IF nullif(e->>'sourceStockId','') IS NOT NULL AND (e->>'sourceStockId')::uuid IS DISTINCT FROM source_stock_id THEN
      RAISE EXCEPTION 'O produto não pertence ao estoque de origem informado.' USING ERRCODE='22023';
    END IF;
    PERFORM public.assert_stock(source_stock_id);
    IF v_product_id=ANY(seen) OR price_value<0 OR price_value>99999999.99 OR price_value<>round(price_value,2)
      OR (cost_value IS NOT NULL AND (cost_value<0 OR cost_value>99999999.99 OR cost_value<>round(cost_value,2))) THEN
      RAISE EXCEPTION 'Produto, preço de venda ou custo unitário inválido.' USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.products p WHERE p.id=v_product_id AND p.stock_id=source_stock_id AND p.active) THEN
      RAISE EXCEPTION 'Produto não encontrado ou inativo no estoque de origem.' USING ERRCODE='22023';
    END IF;
    seen:=array_append(seen,v_product_id);
    INSERT INTO public.order_catalog_items(stock_id,board_id,product_id,price,unit_cost)
      VALUES(p_stock_id,p_board_id,v_product_id,price_value,cost_value)
      ON CONFLICT(board_id,product_id) DO UPDATE SET price=excluded.price,
        unit_cost=coalesce(excluded.unit_cost,public.order_catalog_items.unit_cost),imported_at=now()
      RETURNING id INTO catalog_id;
    imported:=array_append(imported,catalog_id);
  END LOOP;
  SELECT coalesce(jsonb_agg(catalog_row.value),'[]'::jsonb) INTO result
  FROM jsonb_array_elements(public.orders_catalog_board(p_stock_id,p_board_id)) AS catalog_row(value)
  WHERE (catalog_row.value->>'id')::uuid=ANY(imported);
  RETURN result;
END $$;
