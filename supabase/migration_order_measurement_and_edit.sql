BEGIN;

-- Orders keep whole counts but now record the sale measurement separately.
ALTER TABLE public.order_sale_items ADD COLUMN IF NOT EXISTS unit text NOT NULL DEFAULT 'un';
ALTER TABLE public.order_sale_items ADD COLUMN IF NOT EXISTS unit_price_measure numeric(16,8);
ALTER TABLE public.order_sale_items ADD COLUMN IF NOT EXISTS manual_unit_cost_measure numeric(16,8);
ALTER TABLE public.order_sale_items DROP CONSTRAINT IF EXISTS order_sale_items_unit_check;
ALTER TABLE public.order_sale_items ADD CONSTRAINT order_sale_items_unit_check CHECK (unit IN ('un','ml','g'));

CREATE OR REPLACE FUNCTION public.orders_get_board(p_stock_id uuid,p_board_id uuid,p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT jsonb_build_object(
    'id',o.id,'boardId',o.board_id,'boardName',b.name,'number',o.number,'customer',o.customer,'note',o.note,
    'suggestedTotal',o.suggested_total,'finalTotal',o.final_total,'paid',o.paid,'status',o.status,
    'inventoryStatus',o.inventory_status,'createdAt',o.created_at,'updatedAt',o.updated_at,
    'items',coalesce((SELECT jsonb_agg(jsonb_build_object(
      'productId',coalesce(i.catalog_item_id::text,''),'name',i.product_name,'quantity',i.quantity,
      'unit',i.unit,'unitPrice',coalesce(i.unit_price_measure,i.unit_price),'sourceStockName',i.source_stock_name
    ) ORDER BY i.id) FROM public.order_sale_items i WHERE i.order_id=o.id),'[]'::jsonb)
  ) INTO result FROM public.order_sales o JOIN public.order_boards b ON b.id=o.board_id
  WHERE o.id=p_order_id AND o.stock_id=p_stock_id AND o.board_id=p_board_id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_catalog_board(p_stock_id uuid,p_board_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF NOT EXISTS(SELECT 1 FROM public.order_boards WHERE id=p_board_id AND stock_id=p_stock_id) THEN
    RAISE EXCEPTION 'Kanban não encontrado neste estoque.' USING ERRCODE='P0002';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,'sourceProductId',p.id,'sourceStockId',p.stock_id,'sourceStockName',s.name,
    'name',p.name,'code',p.sku,'category',coalesce(p.type_name,'Sem categoria'),'isKit',p.is_kit,
    'suggestedPrice',coalesce(p.suggested_sale_price,p.next_sale),'contentQuantity',p.content_quantity,
    'contentUnit',p.content_unit,'price',c.price,'unitCost',c.unit_cost,'importedAt',c.imported_at
  ) ORDER BY p.name,c.id),'[]'::jsonb) INTO result
  FROM public.order_catalog_items c JOIN public.product_catalog p ON p.id=c.product_id
  JOIN public.stocks s ON s.id=p.stock_id
  WHERE c.stock_id=p_stock_id AND c.board_id=p_board_id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_create_board(p_stock_id uuid,p_board_id uuid,p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE entry jsonb; order_id uuid; catalog_id uuid; line record; qty integer; sale_unit text;
  suggested numeric:=0; final_total numeric; paid_amount numeric; customer_name text; note_text text; seen uuid[]:='{}';
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF NOT EXISTS(SELECT 1 FROM public.order_boards WHERE id=p_board_id AND stock_id=p_stock_id) THEN RAISE EXCEPTION 'Kanban não encontrado.' USING ERRCODE='P0002'; END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data->'items')<>'array' OR jsonb_array_length(p_data->'items') NOT BETWEEN 1 AND 100
    OR jsonb_typeof(p_data->'finalTotal')<>'number' OR jsonb_typeof(p_data->'paid')<>'number' THEN RAISE EXCEPTION 'Pedido inválido.' USING ERRCODE='22023'; END IF;
  customer_name:=left(btrim(coalesce(p_data->>'customer','')),100); note_text:=left(btrim(coalesce(p_data->>'note','')),500);
  final_total:=(p_data->>'finalTotal')::numeric; paid_amount:=(p_data->>'paid')::numeric;
  IF final_total<0 OR paid_amount<0 OR final_total>99999999.99 OR paid_amount>99999999.99 OR final_total<>round(final_total,2) OR paid_amount<>round(paid_amount,2) THEN RAISE EXCEPTION 'Valores do pedido inválidos.' USING ERRCODE='22023'; END IF;
  PERFORM 1 FROM public.stocks WHERE id=p_stock_id FOR UPDATE;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
    IF jsonb_typeof(entry)<>'object' OR jsonb_typeof(entry->'quantity')<>'number' OR nullif(entry->>'productId','') IS NULL THEN RAISE EXCEPTION 'Item inválido.' USING ERRCODE='22023'; END IF;
    catalog_id:=(entry->>'productId')::uuid; qty:=(entry->>'quantity')::integer; sale_unit:=coalesce(entry->>'unit','un');
    IF (entry->>'quantity')::numeric<>qty OR qty NOT BETWEEN 1 AND 999999 OR sale_unit NOT IN ('un','ml','g') OR catalog_id=ANY(seen) THEN RAISE EXCEPTION 'Item repetido ou quantidade/unidade inválida.' USING ERRCODE='22023'; END IF;
    SELECT c.id,c.product_id,p.name,p.stock_id,s.name AS source_stock_name,c.price,c.unit_cost,p.content_quantity,p.content_unit,p.is_kit INTO line
    FROM public.order_catalog_items c JOIN public.products p ON p.id=c.product_id JOIN public.stocks s ON s.id=p.stock_id
    WHERE c.id=catalog_id AND c.stock_id=p_stock_id AND c.board_id=p_board_id AND p.active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Um item não pertence ao catálogo deste kanban.' USING ERRCODE='22023'; END IF;
    PERFORM public.assert_stock(line.stock_id);
    IF sale_unit<>'un' AND public.required_base(line.content_quantity,line.content_unit,1,sale_unit) IS NULL THEN RAISE EXCEPTION 'A unidade informada não combina com o conteúdo do produto %.',line.name USING ERRCODE='22023'; END IF;
    IF sale_unit<>'un' AND coalesce(line.content_quantity,0)<=0 THEN RAISE EXCEPTION 'Cadastre o conteúdo por embalagem de % antes de vender por medida.',line.name USING ERRCODE='22023'; END IF;
    seen:=array_append(seen,catalog_id);
    suggested:=suggested+round((CASE WHEN sale_unit='un' THEN line.price ELSE line.price/public.content_base(line.content_quantity,line.content_unit) END)*qty,2);
  END LOOP;
  INSERT INTO public.order_sales(stock_id,board_id,customer,note,suggested_total,final_total,paid)
    VALUES(p_stock_id,p_board_id,customer_name,note_text,suggested,final_total,paid_amount) RETURNING id INTO order_id;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
    sale_unit:=coalesce(entry->>'unit','un');
    SELECT c.id,c.product_id,p.name,p.stock_id,s.name AS source_stock_name,c.price,c.unit_cost,p.content_quantity,p.content_unit INTO line
    FROM public.order_catalog_items c JOIN public.products p ON p.id=c.product_id JOIN public.stocks s ON s.id=p.stock_id
    WHERE c.id=(entry->>'productId')::uuid AND c.stock_id=p_stock_id AND c.board_id=p_board_id;
    INSERT INTO public.order_sale_items(order_id,catalog_item_id,product_id,product_name,quantity,unit,unit_price,manual_unit_cost,unit_price_measure,manual_unit_cost_measure,source_stock_id,source_stock_name)
    VALUES(order_id,line.id,line.product_id,line.name,(entry->>'quantity')::integer,sale_unit,
      CASE WHEN sale_unit='un' THEN line.price ELSE line.price/public.content_base(line.content_quantity,line.content_unit) END,
      CASE WHEN line.unit_cost IS NULL THEN NULL WHEN sale_unit='un' THEN line.unit_cost ELSE line.unit_cost/public.content_base(line.content_quantity,line.content_unit) END,
      CASE WHEN sale_unit='un' THEN line.price ELSE line.price/public.content_base(line.content_quantity,line.content_unit) END,
      CASE WHEN line.unit_cost IS NULL THEN NULL WHEN sale_unit='un' THEN line.unit_cost ELSE line.unit_cost/public.content_base(line.content_quantity,line.content_unit) END,
      line.stock_id,line.source_stock_name);
  END LOOP;
  RETURN public.orders_get_board(p_stock_id,p_board_id,order_id);
END $$;

CREATE OR REPLACE FUNCTION public.orders_update_board(p_stock_id uuid,p_board_id uuid,p_order_id uuid,p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE entry jsonb; line record; qty integer; sale_unit text; suggested numeric:=0; final_total numeric; paid_amount numeric;
  customer_name text; note_text text; seen uuid[]:='{}'; current_status text;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT status INTO current_status FROM public.order_sales WHERE id=p_order_id AND stock_id=p_stock_id AND board_id=p_board_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado neste kanban.' USING ERRCODE='P0002'; END IF;
  IF current_status='finished' THEN RAISE EXCEPTION 'Pedidos finalizados não podem ser editados; o histórico de estoque é imutável.' USING ERRCODE='23514'; END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data->'items')<>'array' OR jsonb_array_length(p_data->'items') NOT BETWEEN 1 AND 100
    OR jsonb_typeof(p_data->'finalTotal')<>'number' OR jsonb_typeof(p_data->'paid')<>'number' THEN RAISE EXCEPTION 'Pedido inválido.' USING ERRCODE='22023'; END IF;
  customer_name:=left(btrim(coalesce(p_data->>'customer','')),100); note_text:=left(btrim(coalesce(p_data->>'note','')),500);
  final_total:=(p_data->>'finalTotal')::numeric; paid_amount:=(p_data->>'paid')::numeric;
  IF final_total<0 OR paid_amount<0 OR final_total>99999999.99 OR paid_amount>99999999.99 OR final_total<>round(final_total,2) OR paid_amount<>round(paid_amount,2) THEN RAISE EXCEPTION 'Valores do pedido inválidos.' USING ERRCODE='22023'; END IF;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
    IF jsonb_typeof(entry)<>'object' OR jsonb_typeof(entry->'quantity')<>'number' OR nullif(entry->>'productId','') IS NULL THEN RAISE EXCEPTION 'Item inválido.' USING ERRCODE='22023'; END IF;
    qty:=(entry->>'quantity')::integer; sale_unit:=coalesce(entry->>'unit','un');
    IF (entry->>'quantity')::numeric<>qty OR qty NOT BETWEEN 1 AND 999999 OR sale_unit NOT IN ('un','ml','g') THEN RAISE EXCEPTION 'Quantidade/unidade inválida.' USING ERRCODE='22023'; END IF;
    SELECT c.id,c.product_id,p.name,p.stock_id,s.name AS source_stock_name,c.price,c.unit_cost,p.content_quantity,p.content_unit INTO line
    FROM public.order_catalog_items c JOIN public.products p ON p.id=c.product_id JOIN public.stocks s ON s.id=p.stock_id
    WHERE c.id=(entry->>'productId')::uuid AND c.stock_id=p_stock_id AND c.board_id=p_board_id AND p.active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Um item não pertence ao catálogo deste kanban.' USING ERRCODE='22023'; END IF;
    PERFORM public.assert_stock(line.stock_id);
    IF (entry->>'productId')::uuid=ANY(seen) THEN RAISE EXCEPTION 'Item repetido.' USING ERRCODE='22023'; END IF;
    IF sale_unit<>'un' AND (coalesce(line.content_quantity,0)<=0 OR public.required_base(line.content_quantity,line.content_unit,1,sale_unit) IS NULL) THEN RAISE EXCEPTION 'A unidade informada não combina com o conteúdo do produto %.',line.name USING ERRCODE='22023'; END IF;
    seen:=array_append(seen,(entry->>'productId')::uuid); suggested:=suggested+round((CASE WHEN sale_unit='un' THEN line.price ELSE line.price/public.content_base(line.content_quantity,line.content_unit) END)*qty,2);
  END LOOP;
  UPDATE public.order_sales SET customer=customer_name,note=note_text,suggested_total=suggested,final_total=final_total,paid=paid_amount,updated_at=now()
    WHERE id=p_order_id AND stock_id=p_stock_id AND board_id=p_board_id;
  DELETE FROM public.order_sale_items WHERE order_id=p_order_id;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
    sale_unit:=coalesce(entry->>'unit','un');
    SELECT c.id,c.product_id,p.name,p.stock_id,s.name AS source_stock_name,c.price,c.unit_cost,p.content_quantity,p.content_unit INTO line
    FROM public.order_catalog_items c JOIN public.products p ON p.id=c.product_id JOIN public.stocks s ON s.id=p.stock_id
    WHERE c.id=(entry->>'productId')::uuid AND c.stock_id=p_stock_id AND c.board_id=p_board_id;
    INSERT INTO public.order_sale_items(order_id,catalog_item_id,product_id,product_name,quantity,unit,unit_price,manual_unit_cost,unit_price_measure,manual_unit_cost_measure,source_stock_id,source_stock_name)
    VALUES(p_order_id,line.id,line.product_id,line.name,(entry->>'quantity')::integer,sale_unit,
      CASE WHEN sale_unit='un' THEN line.price ELSE line.price/public.content_base(line.content_quantity,line.content_unit) END,
      CASE WHEN line.unit_cost IS NULL THEN NULL WHEN sale_unit='un' THEN line.unit_cost ELSE line.unit_cost/public.content_base(line.content_quantity,line.content_unit) END,
      CASE WHEN sale_unit='un' THEN line.price ELSE line.price/public.content_base(line.content_quantity,line.content_unit) END,
      CASE WHEN line.unit_cost IS NULL THEN NULL WHEN sale_unit='un' THEN line.unit_cost ELSE line.unit_cost/public.content_base(line.content_quantity,line.content_unit) END,
      line.stock_id,line.source_stock_name);
  END LOOP;
  RETURN public.orders_get_board(p_stock_id,p_board_id,p_order_id);
END $$;

CREATE OR REPLACE FUNCTION public.orders_change_status_board(p_stock_id uuid,p_board_id uuid,p_order_id uuid,p_status text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE previous_status text; order_item record; operation_id uuid; line_cost numeric; available_quantity numeric;
  settled_quantity numeric; pending_quantity numeric; failure_message text; settled_count int:=0; pending_count int:=0; partial_count int:=0; inventory_result text:='not_processed';
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT status INTO previous_status FROM public.order_sales WHERE id=p_order_id AND stock_id=p_stock_id AND board_id=p_board_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado neste kanban.' USING ERRCODE='P0002'; END IF;
  IF NOT ((previous_status='waiting' AND p_status IN ('preparing','cancelled')) OR (previous_status='preparing' AND p_status IN ('waiting','finished','cancelled')) OR (previous_status='cancelled' AND p_status='waiting')) THEN RAISE EXCEPTION 'Transição de status inválida.' USING ERRCODE='22023'; END IF;
  IF p_status='finished' THEN
    PERFORM 1 FROM public.stocks stock WHERE stock.id IN(SELECT p_stock_id UNION SELECT coalesce(i.source_stock_id,p.stock_id) FROM public.order_sale_items i LEFT JOIN public.products p ON p.id=i.product_id WHERE i.order_id=p_order_id) ORDER BY stock.id FOR UPDATE;
    FOR order_item IN SELECT i.id,coalesce(i.product_id,c.product_id) product_id,coalesce(i.source_stock_id,p.stock_id) source_stock_id,i.quantity,i.unit,coalesce(i.manual_unit_cost_measure,i.manual_unit_cost) manual_unit_cost
      FROM public.order_sale_items i LEFT JOIN public.order_catalog_items c ON c.id=i.catalog_item_id LEFT JOIN public.products p ON p.id=coalesce(i.product_id,c.product_id)
      WHERE i.order_id=p_order_id ORDER BY i.id LOOP
      operation_id:=NULL; line_cost:=NULL; settled_quantity:=0; pending_quantity:=order_item.quantity; failure_message:=NULL;
      BEGIN
        IF order_item.product_id IS NULL THEN RAISE EXCEPTION 'Produto deste pedido não existe mais no estoque.' USING ERRCODE='23514'; END IF;
        IF order_item.unit='un' THEN
          SELECT CASE WHEN product.is_kit THEN (SELECT capacity.whole_units FROM public.estimate_kit_capacity(order_item.source_stock_id,product.id) capacity)
            ELSE (SELECT coalesce(sum(floor(lot.quantity_remaining/coalesce(public.content_base(product.content_quantity,product.content_unit),1))),0) FROM public.stock_lots lot WHERE lot.product_id=product.id AND lot.quantity_remaining>0) END
          INTO available_quantity FROM public.products product WHERE product.id=order_item.product_id AND product.stock_id=order_item.source_stock_id AND product.active;
        ELSE
          SELECT coalesce(sum(lot.quantity_remaining),0)/unit.base_factor INTO available_quantity
          FROM public.products product JOIN public.measurement_units unit ON unit.code=order_item.unit
          LEFT JOIN public.stock_lots lot ON lot.product_id=product.id AND lot.quantity_remaining>0
          WHERE product.id=order_item.product_id AND product.stock_id=order_item.source_stock_id AND product.active GROUP BY unit.base_factor;
        END IF;
        IF NOT FOUND THEN RAISE EXCEPTION 'Produto ativo não encontrado neste estoque.' USING ERRCODE='23514'; END IF;
        settled_quantity:=least(order_item.quantity,greatest(CASE WHEN order_item.unit='un' THEN floor(coalesce(available_quantity,0)) ELSE floor(coalesce(available_quantity,0)*1000000)/1000000 END,0));
        pending_quantity:=order_item.quantity-settled_quantity;
        IF settled_quantity>0 THEN
          SELECT public.decrement_inventory(order_item.source_stock_id,'pedido:'||p_order_id||':item:'||order_item.id,
            jsonb_build_object('reason','Venda concluída com baixa FIFO parcial por item','items',jsonb_build_array(jsonb_build_object('product_id',order_item.product_id,'quantity',settled_quantity,'unit',order_item.unit)))) INTO operation_id;
          line_cost:=public.order_inventory_operation_cost(operation_id,NULL);
        END IF;
        INSERT INTO public.order_inventory_settlements(stock_id,order_id,order_item_id,product_id,requested_quantity,requested_unit,status,inventory_operation_id,actual_cost,settled_quantity,pending_quantity,issue_message)
        VALUES(order_item.source_stock_id,p_order_id,order_item.id,order_item.product_id,order_item.quantity,order_item.unit,CASE WHEN pending_quantity=0 THEN 'settled' WHEN settled_quantity>0 THEN 'partial' ELSE 'pending' END,operation_id,line_cost,settled_quantity,pending_quantity,CASE WHEN pending_quantity>0 THEN 'Saldo insuficiente; diferença pendente de regularização.' END)
        ON CONFLICT(order_item_id) DO UPDATE SET status=excluded.status,inventory_operation_id=excluded.inventory_operation_id,actual_cost=excluded.actual_cost,settled_quantity=excluded.settled_quantity,pending_quantity=excluded.pending_quantity,issue_message=excluded.issue_message,updated_at=now();
        UPDATE public.order_sale_items SET cost_source=CASE WHEN pending_quantity=0 THEN 'inventory' WHEN order_item.manual_unit_cost IS NULL THEN 'missing' WHEN settled_quantity>0 THEN 'mixed' ELSE 'manual' END,
          unit_cost_snapshot=CASE WHEN pending_quantity=0 THEN round(coalesce(line_cost,0)/order_item.quantity,6) WHEN order_item.manual_unit_cost IS NOT NULL THEN round((coalesce(line_cost,0)+order_item.manual_unit_cost*pending_quantity)/order_item.quantity,6) ELSE NULL END WHERE id=order_item.id;
        IF pending_quantity>0 THEN pending_count:=pending_count+1; END IF; IF settled_quantity>0 AND pending_quantity>0 THEN partial_count:=partial_count+1; END IF; IF pending_quantity=0 THEN settled_count:=settled_count+1; END IF;
      EXCEPTION WHEN OTHERS THEN
        failure_message:=SQLERRM;
        INSERT INTO public.order_inventory_settlements(stock_id,order_id,order_item_id,product_id,requested_quantity,requested_unit,status,settled_quantity,pending_quantity,issue_message)
        VALUES(order_item.source_stock_id,p_order_id,order_item.id,order_item.product_id,order_item.quantity,order_item.unit,'pending',0,order_item.quantity,failure_message)
        ON CONFLICT(order_item_id) DO UPDATE SET status='pending',inventory_operation_id=NULL,actual_cost=NULL,settled_quantity=0,pending_quantity=excluded.pending_quantity,issue_message=excluded.issue_message,updated_at=now();
        UPDATE public.order_sale_items SET cost_source=CASE WHEN order_item.manual_unit_cost IS NULL THEN 'missing' ELSE 'manual' END,unit_cost_snapshot=order_item.manual_unit_cost WHERE id=order_item.id;
        pending_count:=pending_count+1;
      END;
    END LOOP;
    inventory_result:=CASE WHEN pending_count=0 THEN 'settled' WHEN settled_count>0 OR partial_count>0 THEN 'partial' ELSE 'pending' END;
    WITH line_data AS (SELECT i.id,i.quantity*coalesce(i.unit_price_measure,i.unit_price) listed_revenue,i.quantity,o.suggested_total,o.final_total,count(*) OVER(PARTITION BY o.id) line_count,row_number() OVER(PARTITION BY o.id ORDER BY i.id) line_position,sum(i.quantity) OVER(PARTITION BY o.id) quantity_total,s.status settlement_status,s.pending_quantity,s.actual_cost,coalesce(i.manual_unit_cost_measure,i.manual_unit_cost) manual_unit_cost FROM public.order_sale_items i JOIN public.order_sales o ON o.id=i.order_id LEFT JOIN public.order_inventory_settlements s ON s.order_item_id=i.id WHERE i.order_id=p_order_id),
    raw AS (SELECT d.*,CASE WHEN d.suggested_total>0 THEN d.final_total*d.listed_revenue/d.suggested_total WHEN d.quantity_total>0 THEN d.final_total*d.quantity/d.quantity_total ELSE 0 END raw_revenue FROM line_data d),
    alloc AS (SELECT r.*,CASE WHEN r.line_position=r.line_count THEN r.final_total-coalesce(sum(round(r.raw_revenue,2)) OVER(ORDER BY r.line_position ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) ELSE round(r.raw_revenue,2) END line_revenue FROM raw r),
    costed AS (SELECT a.*,CASE WHEN a.settlement_status='settled' THEN a.actual_cost WHEN a.settlement_status='partial' THEN coalesce(a.actual_cost,0)+CASE WHEN a.manual_unit_cost IS NOT NULL THEN a.manual_unit_cost*a.pending_quantity ELSE 0 END WHEN a.settlement_status='pending' AND a.manual_unit_cost IS NOT NULL THEN a.manual_unit_cost*a.quantity ELSE a.actual_cost END line_cost,CASE WHEN a.settlement_status='settled' THEN a.actual_cost IS NOT NULL WHEN a.settlement_status='partial' THEN a.pending_quantity=0 OR a.manual_unit_cost IS NOT NULL WHEN a.settlement_status='pending' THEN a.manual_unit_cost IS NOT NULL ELSE false END is_cost_complete FROM alloc a)
    UPDATE public.order_sale_items i SET final_revenue_snapshot=c.line_revenue,final_cost_snapshot=c.line_cost,cost_complete_snapshot=c.is_cost_complete,margin_snapshot=CASE WHEN c.is_cost_complete AND c.line_revenue<>0 THEN round((c.line_revenue-c.line_cost)/c.line_revenue*100,4) END FROM costed c WHERE i.id=c.id;
  END IF;
  UPDATE public.order_sales SET status=p_status,updated_at=now(),finished_at=CASE WHEN p_status='finished' THEN coalesce(finished_at,now()) ELSE finished_at END,inventory_operation_id=CASE WHEN p_status='finished' THEN NULL ELSE inventory_operation_id END,inventory_status=CASE WHEN p_status='finished' THEN inventory_result ELSE inventory_status END WHERE id=p_order_id AND stock_id=p_stock_id AND board_id=p_board_id;
  RETURN public.orders_get_board(p_stock_id,p_board_id,p_order_id);
END $$;

-- Normalize sold quantities to the product's base measurement for analytics
-- while retaining raw entered units for prices, cost snapshots and audit.
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
      coalesce(p.is_kit,false) source_is_kit,i.quantity raw_quantity,i.unit,coalesce(i.unit_price_measure,i.unit_price) unit_price,i.quantity*coalesce(i.unit_price_measure,i.unit_price) raw_listed,
      p.content_quantity,p.content_unit,CASE WHEN lower(coalesce(p.content_unit,'un')) IN('ml','l') THEN 'ml' WHEN lower(coalesce(p.content_unit,'un')) IN('g','kg') THEN 'g' ELSE 'un' END base_unit,
      i.cost_source,coalesce(i.manual_unit_cost_measure,i.manual_unit_cost) manual_unit_cost,i.unit_cost_snapshot,i.final_revenue_snapshot,i.final_cost_snapshot,i.cost_complete_snapshot,
      s.status settlement_status,s.actual_cost settlement_cost,s.pending_quantity,
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

CREATE OR REPLACE FUNCTION public.orders_analytics_products(p_stock_id uuid,p_board_ids uuid[],p_from timestamptz,p_to timestamptz,
  p_search text DEFAULT NULL,p_kind text DEFAULT 'all',p_sort text DEFAULT 'profit',p_direction text DEFAULT 'desc',p_limit integer DEFAULT 50,p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb; previous_from timestamptz:=p_from-(p_to-p_from); period_days numeric;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF p_kind NOT IN('all','product','kit') OR p_sort NOT IN('profit','revenue','quantity','margin','name') OR p_direction NOT IN('asc','desc') OR p_limit NOT BETWEEN 1 AND 100 OR p_offset NOT BETWEEN 0 AND 10000 THEN RAISE EXCEPTION 'Filtros de produtos inválidos.' USING ERRCODE='22023'; END IF;
  period_days:=greatest(1,extract(epoch FROM p_to-p_from)/86400);
  WITH current_lines AS(SELECT * FROM public.order_analytics_lines(p_stock_id,p_board_ids,p_from,p_to)),
  previous_lines AS(SELECT * FROM public.order_analytics_lines(p_stock_id,p_board_ids,previous_from,p_from)),
  current_product AS(SELECT product_id,min(product_name) name,min(sku) code,bool_or(is_kit) is_kit,count(DISTINCT order_id) orders,sum(quantity) quantity,
    sum(listed_revenue) listed_revenue,sum(allocated_revenue) revenue,bool_and(cost_complete) cost_complete,CASE WHEN bool_and(cost_complete) THEN sum(actual_cost) END cost,max(finished_at) last_sale_at
    FROM current_lines WHERE product_id IS NOT NULL GROUP BY product_id),
  previous_product AS(SELECT product_id,sum(quantity) quantity,sum(allocated_revenue) revenue,CASE WHEN bool_and(cost_complete) THEN sum(actual_cost) END cost
    FROM previous_lines WHERE product_id IS NOT NULL GROUP BY product_id),
  merged AS(SELECT current_product.*,coalesce(previous_product.quantity,0) previous_quantity,coalesce(previous_product.revenue,0) previous_revenue,
    CASE WHEN previous_product.cost IS NULL THEN NULL ELSE previous_product.revenue-previous_product.cost END previous_profit,
    coalesce(catalog.base_quantity,catalog.whole_units,0) stock_quantity,coalesce(catalog.base_unit,'un') quantity_unit
    FROM current_product LEFT JOIN previous_product ON previous_product.product_id=current_product.product_id
    LEFT JOIN public.product_catalog catalog ON catalog.id=current_product.product_id),
  calculated AS(SELECT merged.*,round(quantity/period_days,4) daily_velocity,CASE WHEN quantity>0 THEN round(stock_quantity/(quantity/period_days),2) END coverage_days,
    CASE WHEN cost_complete THEN revenue-cost END profit,CASE WHEN cost_complete THEN round((revenue-cost)/nullif(revenue,0)*100,2) END margin,
    CASE WHEN cost_complete THEN round((revenue-cost)/nullif(cost,0)*100,2) END markup,round(revenue/nullif(quantity,0),2) average_price,
    round((revenue/nullif(listed_revenue,0)-1)*100,2) adjustment_percent FROM merged),
  filtered AS(SELECT * FROM calculated WHERE(p_kind='all' OR(p_kind='kit')=is_kit)
    AND(nullif(btrim(coalesce(p_search,'')),'') IS NULL OR lower(name||' '||coalesce(code,'')) LIKE '%'||lower(btrim(p_search))||'%')),
  paged AS(SELECT * FROM filtered ORDER BY CASE WHEN p_sort='name' AND p_direction='asc' THEN name END ASC NULLS LAST,
    CASE WHEN p_sort='name' AND p_direction='desc' THEN name END DESC NULLS LAST,CASE WHEN p_sort='profit' AND p_direction='asc' THEN profit END ASC NULLS LAST,
    CASE WHEN p_sort='profit' AND p_direction='desc' THEN profit END DESC NULLS LAST,CASE WHEN p_sort='revenue' AND p_direction='asc' THEN revenue END ASC NULLS LAST,
    CASE WHEN p_sort='revenue' AND p_direction='desc' THEN revenue END DESC NULLS LAST,CASE WHEN p_sort='quantity' AND p_direction='asc' THEN quantity END ASC NULLS LAST,
    CASE WHEN p_sort='quantity' AND p_direction='desc' THEN quantity END DESC NULLS LAST,CASE WHEN p_sort='margin' AND p_direction='asc' THEN margin END ASC NULLS LAST,
    CASE WHEN p_sort='margin' AND p_direction='desc' THEN margin END DESC NULLS LAST,name ASC LIMIT p_limit OFFSET p_offset)
  SELECT jsonb_build_object('total',(SELECT count(*) FROM filtered),'periodDays',period_days,'rows',coalesce((SELECT jsonb_agg(jsonb_build_object(
    'productId',product_id,'name',name,'code',code,'isKit',is_kit,'orders',orders,'quantity',quantity,'quantityUnit',quantity_unit,'revenue',revenue,'cost',cost,'profit',profit,'margin',margin,'markup',markup,'averagePrice',average_price,'adjustmentPercent',adjustment_percent,
    'stockWholeUnits',stock_quantity,'dailyVelocity',daily_velocity,'coverageDays',coverage_days,'lastSaleAt',last_sale_at,'previousQuantity',previous_quantity,'previousRevenue',previous_revenue,'previousProfit',previous_profit,'costComplete',cost_complete) ORDER BY name) FROM paged),'[]'::jsonb)) INTO result;
  RETURN result;
END $$;

REVOKE ALL ON FUNCTION public.orders_update_board(uuid,uuid,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.orders_update_board(uuid,uuid,uuid,jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.order_analytics_lines(uuid,uuid[],timestamptz,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.orders_analytics_products(uuid,uuid[],timestamptz,timestamptz,text,text,text,text,integer,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.orders_analytics_products(uuid,uuid[],timestamptz,timestamptz,text,text,text,text,integer,integer) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
