-- Avoid ambiguity between the preset_id column and PL/pgSQL variables while saving presets.
CREATE OR REPLACE FUNCTION public.order_presets_save(p_stock_id uuid,p_name text,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE clean_name text; entry jsonb; v_preset_id uuid; v_product_id uuid;
  v_source_stock_id uuid; v_price numeric; seen uuid[]:='{}'; result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  clean_name:=btrim(coalesce(p_name,''));
  IF length(clean_name) NOT BETWEEN 1 AND 80 OR p_items IS NULL
    OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
    OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Informe nome e selecione de 1 a 100 itens para o preset.' USING ERRCODE='22023';
  END IF;
  PERFORM 1 FROM public.stocks WHERE id=p_stock_id FOR UPDATE;
  INSERT INTO public.order_item_presets(stock_id,name,updated_at)
    VALUES(p_stock_id,clean_name,now())
    ON CONFLICT(stock_id,name) DO UPDATE SET updated_at=now()
    RETURNING id INTO v_preset_id;
  DELETE FROM public.order_item_preset_items AS preset_item
    WHERE preset_item.preset_id=v_preset_id;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(entry)<>'object'
      OR jsonb_typeof(entry->'price') IS DISTINCT FROM 'number'
      OR nullif(entry->>'sourceProductId','') IS NULL THEN
      RAISE EXCEPTION 'Item ou preço inválido no preset.' USING ERRCODE='22023';
    END IF;
    v_product_id:=(entry->>'sourceProductId')::uuid;
    v_price:=(entry->>'price')::numeric;
    SELECT product.stock_id INTO v_source_stock_id
      FROM public.products AS product
      WHERE product.id=v_product_id AND product.active;
    IF v_source_stock_id IS NULL THEN
      RAISE EXCEPTION 'Produto inativo ou não encontrado.' USING ERRCODE='22023';
    END IF;
    IF nullif(entry->>'sourceStockId','') IS NOT NULL
      AND (entry->>'sourceStockId')::uuid IS DISTINCT FROM v_source_stock_id THEN
      RAISE EXCEPTION 'O produto não pertence ao estoque de origem informado.' USING ERRCODE='22023';
    END IF;
    PERFORM public.assert_stock(v_source_stock_id);
    IF v_product_id=ANY(seen) OR v_price<0 OR v_price>99999999.99 OR v_price<>round(v_price,2) THEN
      RAISE EXCEPTION 'Item repetido, inativo ou preço inválido no preset.' USING ERRCODE='22023';
    END IF;
    seen:=array_append(seen,v_product_id);
    INSERT INTO public.order_item_preset_items(preset_id,product_id,price)
      VALUES(v_preset_id,v_product_id,v_price);
  END LOOP;
  SELECT preset_row.value INTO result
    FROM jsonb_array_elements(public.order_presets_list(p_stock_id)) AS preset_row(value)
    WHERE (preset_row.value->>'id')::uuid=v_preset_id;
  RETURN result;
END $$;
