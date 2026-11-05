-- Allow an order board to import products from any stock owned by the signed-in user.
-- Orders remain scoped to the board stock; each line retains the product's origin stock.
BEGIN;

ALTER TABLE public.order_sale_items
  ADD COLUMN IF NOT EXISTS source_stock_id uuid REFERENCES public.stocks(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS source_stock_name text;

UPDATE public.order_sale_items i
SET source_stock_id = p.stock_id,
    source_stock_name = s.name
FROM public.products p
JOIN public.stocks s ON s.id = p.stock_id
WHERE p.id = i.product_id
  AND (i.source_stock_id IS NULL OR i.source_stock_name IS NULL);

CREATE OR REPLACE FUNCTION public.orders_catalog_board(p_stock_id uuid, p_board_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF NOT EXISTS (SELECT 1 FROM public.order_boards WHERE id=p_board_id AND stock_id=p_stock_id) THEN
    RAISE EXCEPTION 'Kanban não encontrado neste estoque.' USING ERRCODE='P0002';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,'sourceProductId',c.product_id,'sourceStockId',p.stock_id,
    'sourceStockName',source_stock.name,'name',p.name,'code',p.sku,
    'category',coalesce(p.type_name,'Sem categoria'),'isKit',p.is_kit,
    'suggestedPrice',coalesce(p.suggested_sale_price,p.next_sale),
    'price',c.price,'unitCost',c.unit_cost,'importedAt',c.imported_at
  ) ORDER BY p.name,c.id),'[]'::jsonb) INTO result
  FROM public.order_catalog_items c
  JOIN public.product_catalog p ON p.id=c.product_id
  JOIN public.stocks source_stock ON source_stock.id=p.stock_id
  WHERE c.stock_id=p_stock_id AND c.board_id=p_board_id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_import_catalog_board(
  p_stock_id uuid,p_board_id uuid,p_items jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  entry jsonb; v_product_id uuid; source_stock_id uuid; catalog_id uuid;
  price_value numeric; unit_cost_value numeric; imported uuid[]:='{}';
  seen uuid[]:='{}'; result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF NOT EXISTS (SELECT 1 FROM public.order_boards WHERE id=p_board_id AND stock_id=p_stock_id) THEN
    RAISE EXCEPTION 'Kanban não encontrado neste estoque.' USING ERRCODE='P0002';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
    OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Selecione de 1 a 100 produtos.' USING ERRCODE='22023';
  END IF;
  PERFORM 1 FROM public.stocks WHERE id=p_stock_id FOR UPDATE;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(entry)<>'object' OR jsonb_typeof(entry->'price') IS DISTINCT FROM 'number'
      OR nullif(entry->>'sourceProductId','') IS NULL THEN
      RAISE EXCEPTION 'Produto ou preço inválido.' USING ERRCODE='22023';
    END IF;
    v_product_id:=(entry->>'sourceProductId')::uuid;
    price_value:=(entry->>'price')::numeric;
    unit_cost_value:=CASE WHEN jsonb_typeof(entry->'unitCost')='number'
      THEN (entry->>'unitCost')::numeric ELSE NULL END;
    SELECT p.stock_id INTO source_stock_id FROM public.products p WHERE p.id=v_product_id;
    IF source_stock_id IS NULL THEN RAISE EXCEPTION 'Produto não encontrado.' USING ERRCODE='22023'; END IF;
    IF nullif(entry->>'sourceStockId','') IS NOT NULL
      AND (entry->>'sourceStockId')::uuid IS DISTINCT FROM source_stock_id THEN
      RAISE EXCEPTION 'O produto não pertence ao estoque de origem informado.' USING ERRCODE='22023';
    END IF;
    PERFORM public.assert_stock(source_stock_id);
    IF v_product_id=ANY(seen) OR price_value<0 OR price_value>99999999.99
      OR price_value<>round(price_value,2) OR (unit_cost_value IS NOT NULL
        AND (unit_cost_value<0 OR unit_cost_value>99999999.99 OR unit_cost_value<>round(unit_cost_value,2))) THEN
      RAISE EXCEPTION 'Produto, preço de venda ou custo unitário inválido.' USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id=v_product_id
      AND p.stock_id=source_stock_id AND p.active) THEN
      RAISE EXCEPTION 'Produto não encontrado ou inativo no estoque de origem.' USING ERRCODE='22023';
    END IF;
    seen:=array_append(seen,v_product_id);
    INSERT INTO public.order_catalog_items(stock_id,board_id,product_id,price,unit_cost)
      VALUES(p_stock_id,p_board_id,v_product_id,price_value,unit_cost_value)
      ON CONFLICT(board_id,product_id) DO UPDATE SET price=excluded.price,
        unit_cost=coalesce(excluded.unit_cost,public.order_catalog_items.unit_cost),imported_at=now()
      RETURNING id INTO catalog_id;
    imported:=array_append(imported,catalog_id);
  END LOOP;
  SELECT coalesce(jsonb_agg(row.value),'[]'::jsonb) INTO result
  FROM jsonb_array_elements(public.orders_catalog_board(p_stock_id,p_board_id)) row(value)
  WHERE (row.value->>'id')::uuid=ANY(imported);
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.order_presets_list(p_stock_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', preset.id, 'name', preset.name, 'createdAt', preset.created_at, 'updatedAt', preset.updated_at,
    'items', coalesce((SELECT jsonb_agg(jsonb_build_object(
      'sourceProductId', item.product_id, 'sourceStockId', product.stock_id, 'price', item.price
    ) ORDER BY product.name, item.product_id)
      FROM public.order_item_preset_items item
      JOIN public.products product ON product.id=item.product_id
      WHERE item.preset_id=preset.id), '[]'::jsonb)
  ) ORDER BY preset.name), '[]'::jsonb)
  INTO result FROM public.order_item_presets preset WHERE preset.stock_id=p_stock_id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.order_presets_save(p_stock_id uuid,p_name text,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE clean_name text; entry jsonb; preset_id uuid; product_id uuid;
  source_stock_id uuid; item_price numeric; seen uuid[]:='{}'; result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  clean_name:=btrim(coalesce(p_name,''));
  IF length(clean_name) NOT BETWEEN 1 AND 80 OR p_items IS NULL
    OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Informe nome e selecione de 1 a 100 itens para o preset.' USING ERRCODE='22023';
  END IF;
  PERFORM 1 FROM public.stocks WHERE id=p_stock_id FOR UPDATE;
  INSERT INTO public.order_item_presets(stock_id,name,updated_at)
    VALUES(p_stock_id,clean_name,now())
    ON CONFLICT(stock_id,name) DO UPDATE SET updated_at=now() RETURNING id INTO preset_id;
  DELETE FROM public.order_item_preset_items item WHERE item.preset_id=preset_id;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(entry)<>'object' OR jsonb_typeof(entry->'price') IS DISTINCT FROM 'number'
      OR nullif(entry->>'sourceProductId','') IS NULL THEN
      RAISE EXCEPTION 'Item ou preço inválido no preset.' USING ERRCODE='22023';
    END IF;
    product_id:=(entry->>'sourceProductId')::uuid;
    item_price:=(entry->>'price')::numeric;
    SELECT p.stock_id INTO source_stock_id FROM public.products p WHERE p.id=product_id AND p.active;
    IF source_stock_id IS NULL THEN RAISE EXCEPTION 'Produto inativo ou não encontrado.' USING ERRCODE='22023'; END IF;
    IF nullif(entry->>'sourceStockId','') IS NOT NULL
      AND (entry->>'sourceStockId')::uuid IS DISTINCT FROM source_stock_id THEN
      RAISE EXCEPTION 'O produto não pertence ao estoque de origem informado.' USING ERRCODE='22023';
    END IF;
    PERFORM public.assert_stock(source_stock_id);
    IF product_id=ANY(seen) OR item_price<0 OR item_price>99999999.99 OR item_price<>round(item_price,2) THEN
      RAISE EXCEPTION 'Item repetido, inativo ou preço inválido no preset.' USING ERRCODE='22023';
    END IF;
    seen:=array_append(seen,product_id);
    INSERT INTO public.order_item_preset_items(preset_id,product_id,price) VALUES(preset_id,product_id,item_price);
  END LOOP;
  SELECT item.value INTO result FROM jsonb_array_elements(public.order_presets_list(p_stock_id)) item(value)
    WHERE (item.value->>'id')::uuid=preset_id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_create_board(p_stock_id uuid,p_board_id uuid,p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE entry jsonb; order_id uuid; catalog_id uuid; line record; quantity integer;
  suggested numeric:=0; final_total numeric; paid_amount numeric; customer_name text; note_text text; seen uuid[]:='{}';
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF NOT EXISTS (SELECT 1 FROM public.order_boards WHERE id=p_board_id AND stock_id=p_stock_id) THEN
    RAISE EXCEPTION 'Kanban não encontrado neste estoque.' USING ERRCODE='P0002';
  END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data)<>'object' OR jsonb_typeof(p_data->'items')<>'array'
    OR jsonb_typeof(p_data->'finalTotal')<>'number' OR jsonb_typeof(p_data->'paid')<>'number'
    OR jsonb_array_length(p_data->'items') NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Pedido inválido.' USING ERRCODE='22023';
  END IF;
  customer_name:=left(btrim(coalesce(p_data->>'customer','')),100);
  note_text:=left(btrim(coalesce(p_data->>'note','')),500);
  final_total:=(p_data->>'finalTotal')::numeric; paid_amount:=(p_data->>'paid')::numeric;
  IF final_total<0 OR paid_amount<0 OR final_total>99999999.99 OR paid_amount>99999999.99
    OR final_total<>round(final_total,2) OR paid_amount<>round(paid_amount,2) THEN
    RAISE EXCEPTION 'Valores do pedido inválidos.' USING ERRCODE='22023';
  END IF;
  PERFORM 1 FROM public.stocks WHERE id=p_stock_id FOR UPDATE;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
    IF jsonb_typeof(entry)<>'object' OR jsonb_typeof(entry->'quantity')<>'number'
      OR nullif(entry->>'productId','') IS NULL THEN RAISE EXCEPTION 'Item inválido.' USING ERRCODE='22023'; END IF;
    catalog_id:=(entry->>'productId')::uuid; quantity:=(entry->>'quantity')::integer;
    IF (entry->>'quantity')::numeric<>quantity OR quantity NOT BETWEEN 1 AND 999 OR catalog_id=ANY(seen) THEN
      RAISE EXCEPTION 'Item repetido ou quantidade inválida.' USING ERRCODE='22023';
    END IF;
    SELECT c.id,c.product_id,p.name,p.stock_id,s.name AS source_stock_name,c.price,c.unit_cost INTO line
    FROM public.order_catalog_items c JOIN public.products p ON p.id=c.product_id
    JOIN public.stocks s ON s.id=p.stock_id
    WHERE c.id=catalog_id AND c.stock_id=p_stock_id AND c.board_id=p_board_id AND p.active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Um item não pertence ao catálogo deste kanban.' USING ERRCODE='22023'; END IF;
    PERFORM public.assert_stock(line.stock_id);
    seen:=array_append(seen,catalog_id); suggested:=suggested+line.price*quantity;
  END LOOP;
  INSERT INTO public.order_sales(stock_id,board_id,customer,note,suggested_total,final_total,paid)
    VALUES(p_stock_id,p_board_id,customer_name,note_text,suggested,final_total,paid_amount) RETURNING id INTO order_id;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
    SELECT c.id,c.product_id,p.name,p.stock_id,s.name AS source_stock_name,c.price,c.unit_cost INTO line
    FROM public.order_catalog_items c JOIN public.products p ON p.id=c.product_id
    JOIN public.stocks s ON s.id=p.stock_id
    WHERE c.id=(entry->>'productId')::uuid AND c.stock_id=p_stock_id AND c.board_id=p_board_id;
    INSERT INTO public.order_sale_items(order_id,catalog_item_id,product_id,product_name,quantity,unit_price,
      manual_unit_cost,source_stock_id,source_stock_name)
      VALUES(order_id,line.id,line.product_id,line.name,(entry->>'quantity')::integer,line.price,
        line.unit_cost,line.stock_id,line.source_stock_name);
  END LOOP;
  RETURN public.orders_get_board(p_stock_id,p_board_id,order_id);
END $$;

CREATE OR REPLACE FUNCTION public.orders_change_status_board(
  p_stock_id uuid,p_board_id uuid,p_order_id uuid,p_status text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE previous_status text; line_operation_id uuid; order_item record; line_cost numeric;
  available_quantity numeric; settled_quantity numeric; pending_quantity numeric; failure_message text;
  settled_count integer:=0; pending_count integer:=0; partial_count integer:=0;
  resulting_inventory_status text:='not_processed';
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT status INTO previous_status FROM public.order_sales
    WHERE id=p_order_id AND stock_id=p_stock_id AND board_id=p_board_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado neste kanban.' USING ERRCODE='P0002'; END IF;
  IF NOT ((previous_status='waiting' AND p_status IN ('preparing','cancelled'))
    OR (previous_status='preparing' AND p_status IN ('waiting','finished','cancelled'))
    OR (previous_status='cancelled' AND p_status='waiting')) THEN
    RAISE EXCEPTION 'Transição de status inválida.' USING ERRCODE='22023';
  END IF;

  IF p_status='finished' THEN
    -- Lock the board stock and every source stock in a stable order to avoid deadlocks.
    PERFORM 1 FROM public.stocks stock
    WHERE stock.id IN (SELECT p_stock_id UNION
      SELECT coalesce(i.source_stock_id,p.stock_id)
      FROM public.order_sale_items i LEFT JOIN public.products p ON p.id=i.product_id
      WHERE i.order_id=p_order_id)
    ORDER BY stock.id FOR UPDATE;

    FOR order_item IN
      SELECT i.id,coalesce(i.product_id,c.product_id) AS product_id,
        coalesce(i.source_stock_id,p.stock_id) AS source_stock_id,i.quantity,i.manual_unit_cost
      FROM public.order_sale_items i LEFT JOIN public.order_catalog_items c ON c.id=i.catalog_item_id
      LEFT JOIN public.products p ON p.id=coalesce(i.product_id,c.product_id)
      WHERE i.order_id=p_order_id ORDER BY i.id
    LOOP
      line_operation_id:=NULL; line_cost:=NULL; settled_quantity:=0;
      pending_quantity:=order_item.quantity; failure_message:=NULL;
      BEGIN
        IF order_item.product_id IS NULL OR order_item.source_stock_id IS NULL THEN
          RAISE EXCEPTION 'Produto ou estoque de origem deste pedido não existe mais.' USING ERRCODE='23514';
        END IF;
        SELECT CASE WHEN product.is_kit THEN (
          SELECT capacity.whole_units FROM public.estimate_kit_capacity(order_item.source_stock_id,product.id) capacity
        ) ELSE (
          SELECT coalesce(sum(floor(lot.quantity_remaining/public.content_base(product.content_quantity,product.content_unit))),0)
          FROM public.stock_lots lot WHERE lot.product_id=product.id AND lot.quantity_remaining>0
        ) END INTO available_quantity
        FROM public.products product
        WHERE product.id=order_item.product_id AND product.stock_id=order_item.source_stock_id AND product.active;
        IF NOT FOUND THEN RAISE EXCEPTION 'Produto ativo não encontrado no estoque de origem.' USING ERRCODE='23514'; END IF;
        settled_quantity:=least(order_item.quantity,greatest(floor(coalesce(available_quantity,0)),0));
        pending_quantity:=order_item.quantity-settled_quantity;
        IF settled_quantity>0 THEN
          SELECT public.decrement_inventory(order_item.source_stock_id,'pedido:'||p_order_id||':item:'||order_item.id,
            jsonb_build_object('reason','Venda concluída com baixa FIFO parcial por item','items',jsonb_build_array(
              jsonb_build_object('product_id',order_item.product_id,'quantity',settled_quantity,'unit','un'))))
          INTO line_operation_id;
          line_cost:=public.order_inventory_operation_cost(line_operation_id,NULL);
        END IF;
        INSERT INTO public.order_inventory_settlements(
          stock_id,order_id,order_item_id,product_id,requested_quantity,requested_unit,status,
          inventory_operation_id,actual_cost,settled_quantity,pending_quantity,issue_message
        ) VALUES(order_item.source_stock_id,p_order_id,order_item.id,order_item.product_id,order_item.quantity,'un',
          CASE WHEN pending_quantity=0 THEN 'settled' WHEN settled_quantity>0 THEN 'partial' ELSE 'pending' END,
          line_operation_id,line_cost,settled_quantity,pending_quantity,
          CASE WHEN pending_quantity>0 THEN 'Saldo insuficiente; diferença pendente de regularização.' END)
        ON CONFLICT(order_item_id) DO UPDATE SET stock_id=excluded.stock_id,status=excluded.status,
          inventory_operation_id=excluded.inventory_operation_id,actual_cost=excluded.actual_cost,
          settled_quantity=excluded.settled_quantity,pending_quantity=excluded.pending_quantity,
          issue_message=excluded.issue_message,updated_at=now();
        UPDATE public.order_sale_items SET
          cost_source=CASE WHEN pending_quantity=0 THEN 'inventory'
            WHEN order_item.manual_unit_cost IS NULL THEN 'missing'
            WHEN settled_quantity>0 THEN 'mixed' ELSE 'manual' END,
          unit_cost_snapshot=CASE WHEN pending_quantity=0 THEN round(coalesce(line_cost,0)/order_item.quantity,6)
            WHEN order_item.manual_unit_cost IS NOT NULL THEN round((coalesce(line_cost,0)
              +order_item.manual_unit_cost*pending_quantity)/order_item.quantity,6) ELSE NULL END
        WHERE id=order_item.id;
        IF pending_quantity>0 THEN pending_count:=pending_count+1; END IF;
        IF settled_quantity>0 AND pending_quantity>0 THEN partial_count:=partial_count+1; END IF;
        IF pending_quantity=0 THEN settled_count:=settled_count+1; END IF;
      EXCEPTION WHEN OTHERS THEN
        failure_message:=SQLERRM;
        INSERT INTO public.order_inventory_settlements(
          stock_id,order_id,order_item_id,product_id,requested_quantity,requested_unit,status,
          settled_quantity,pending_quantity,issue_message
        ) VALUES(coalesce(order_item.source_stock_id,p_stock_id),p_order_id,order_item.id,order_item.product_id,
          order_item.quantity,'un','pending',0,order_item.quantity,failure_message)
        ON CONFLICT(order_item_id) DO UPDATE SET stock_id=excluded.stock_id,status='pending',
          inventory_operation_id=NULL,actual_cost=NULL,settled_quantity=0,pending_quantity=excluded.pending_quantity,
          issue_message=excluded.issue_message,updated_at=now();
        UPDATE public.order_sale_items SET
          cost_source=CASE WHEN order_item.manual_unit_cost IS NULL THEN 'missing' ELSE 'manual' END,
          unit_cost_snapshot=order_item.manual_unit_cost WHERE id=order_item.id;
        pending_count:=pending_count+1;
      END;
    END LOOP;
    resulting_inventory_status:=CASE WHEN pending_count=0 THEN 'settled'
      WHEN settled_count>0 OR partial_count>0 THEN 'partial' ELSE 'pending' END;

    WITH line_data AS (
      SELECT i.id,i.quantity*i.unit_price AS listed_revenue,i.quantity,o.suggested_total,o.final_total,
        count(*) OVER(PARTITION BY o.id) AS line_count,
        row_number() OVER(PARTITION BY o.id ORDER BY i.id) AS line_position,
        sum(i.quantity) OVER(PARTITION BY o.id) AS quantity_total,
        sum(i.quantity*i.unit_price) OVER(PARTITION BY o.id) AS listed_total,
        s.status AS settlement_status,s.pending_quantity,s.actual_cost,i.manual_unit_cost,i.cost_source
      FROM public.order_sale_items i JOIN public.order_sales o ON o.id=i.order_id
      LEFT JOIN public.order_inventory_settlements s ON s.order_item_id=i.id WHERE i.order_id=p_order_id
    ), raw_revenue AS (
      SELECT d.*,CASE WHEN d.suggested_total>0 THEN d.final_total*d.listed_revenue/d.suggested_total
        WHEN d.quantity_total>0 THEN d.final_total*d.quantity/d.quantity_total ELSE 0 END AS raw_line_revenue
      FROM line_data d
    ), allocated AS (
      SELECT r.*,CASE WHEN r.line_position=r.line_count THEN r.final_total-coalesce(sum(round(r.raw_line_revenue,2))
        OVER(ORDER BY r.line_position ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0)
        ELSE round(r.raw_line_revenue,2) END AS line_revenue FROM raw_revenue r
    ), costed AS (
      SELECT a.*,CASE WHEN a.settlement_status='settled' THEN a.actual_cost
        WHEN a.settlement_status='partial' THEN coalesce(a.actual_cost,0)
          +CASE WHEN a.manual_unit_cost IS NOT NULL THEN a.manual_unit_cost*a.pending_quantity ELSE 0 END
        WHEN a.settlement_status='pending' AND a.manual_unit_cost IS NOT NULL THEN a.manual_unit_cost*a.quantity
        ELSE a.actual_cost END AS line_cost,
        CASE WHEN a.settlement_status='settled' THEN a.actual_cost IS NOT NULL
          WHEN a.settlement_status='partial' THEN a.pending_quantity=0 OR a.manual_unit_cost IS NOT NULL
          WHEN a.settlement_status='pending' THEN a.manual_unit_cost IS NOT NULL ELSE false END AS is_cost_complete
      FROM allocated a
    )
    UPDATE public.order_sale_items i SET final_revenue_snapshot=costed.line_revenue,
      final_cost_snapshot=costed.line_cost,cost_complete_snapshot=costed.is_cost_complete,
      margin_snapshot=CASE WHEN costed.is_cost_complete AND costed.line_revenue<>0
        THEN round((costed.line_revenue-costed.line_cost)/costed.line_revenue*100,4) END
    FROM costed WHERE i.id=costed.id;
  END IF;
  UPDATE public.order_sales SET status=p_status,updated_at=now(),
    finished_at=CASE WHEN p_status='finished' THEN coalesce(finished_at,now()) ELSE finished_at END,
    inventory_operation_id=CASE WHEN p_status='finished' THEN NULL ELSE inventory_operation_id END,
    inventory_status=CASE WHEN p_status='finished' THEN resulting_inventory_status ELSE inventory_status END
  WHERE id=p_order_id AND stock_id=p_stock_id AND board_id=p_board_id;
  RETURN public.orders_get_board(p_stock_id,p_board_id,p_order_id);
END $$;

CREATE OR REPLACE FUNCTION public.orders_get_board(p_stock_id uuid,p_board_id uuid,p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'id',o.id,'boardId',o.board_id,'boardName',b.name,'number',o.number,'customer',o.customer,'note',o.note,
    'suggestedTotal',o.suggested_total,'finalTotal',o.final_total,'paid',o.paid,'status',o.status,
    'inventoryStatus',o.inventory_status,'createdAt',o.created_at,'updatedAt',o.updated_at,
    'items',coalesce((SELECT jsonb_agg(jsonb_build_object(
      'productId',coalesce(i.catalog_item_id::text,''),'name',i.product_name,'quantity',i.quantity,
      'unitPrice',i.unit_price,'sourceStockName',i.source_stock_name
    ) ORDER BY i.id) FROM public.order_sale_items i WHERE i.order_id=o.id),'[]'::jsonb)
  ) INTO result FROM public.order_sales o JOIN public.order_boards b ON b.id=o.board_id
  WHERE o.id=p_order_id AND o.stock_id=p_stock_id AND o.board_id=p_board_id;
  RETURN result;
END $$;

COMMIT;
