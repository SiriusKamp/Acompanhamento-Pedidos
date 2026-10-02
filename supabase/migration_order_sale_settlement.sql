-- Sales settlement: an order is always finalised, while inventory is settled
-- when possible and otherwise recorded as a dashboard-visible pending item.
-- Apply after migration_order_analytics.sql.
BEGIN;

ALTER TABLE public.order_catalog_items
  ADD COLUMN IF NOT EXISTS unit_cost numeric(12,2);
ALTER TABLE public.order_sales
  ADD COLUMN IF NOT EXISTS inventory_status text NOT NULL DEFAULT 'not_processed';
ALTER TABLE public.order_sale_items
  ADD COLUMN IF NOT EXISTS manual_unit_cost numeric(12,2),
  ADD COLUMN IF NOT EXISTS unit_cost_snapshot numeric(12,6),
  ADD COLUMN IF NOT EXISTS cost_source text,
  ADD COLUMN IF NOT EXISTS final_revenue_snapshot numeric(12,2),
  ADD COLUMN IF NOT EXISTS final_cost_snapshot numeric(12,6),
  ADD COLUMN IF NOT EXISTS cost_complete_snapshot boolean,
  ADD COLUMN IF NOT EXISTS margin_snapshot numeric(12,4);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.order_catalog_items'::regclass
    AND conname='order_catalog_items_unit_cost_check') THEN
    ALTER TABLE public.order_catalog_items ADD CONSTRAINT order_catalog_items_unit_cost_check
      CHECK (unit_cost IS NULL OR (unit_cost >= 0 AND unit_cost <= 99999999.99));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.order_sales'::regclass
    AND conname='order_sales_inventory_status_check') THEN
    ALTER TABLE public.order_sales ADD CONSTRAINT order_sales_inventory_status_check
      CHECK (inventory_status IN ('not_processed','settled','partial','pending'));
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.order_sale_items'::regclass
    AND conname='order_sale_items_cost_source_check') THEN
    ALTER TABLE public.order_sale_items DROP CONSTRAINT order_sale_items_cost_source_check;
  END IF;
  ALTER TABLE public.order_sale_items ADD CONSTRAINT order_sale_items_cost_source_check
    CHECK (cost_source IS NULL OR cost_source IN ('inventory','manual','mixed','missing'));
END $$;

CREATE TABLE IF NOT EXISTS public.order_inventory_settlements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stock_id uuid NOT NULL REFERENCES public.stocks(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.order_sales(id) ON DELETE CASCADE,
  order_item_id uuid NOT NULL REFERENCES public.order_sale_items(id) ON DELETE CASCADE,
  product_id uuid REFERENCES public.products(id) ON DELETE SET NULL,
  requested_quantity numeric(12,6) NOT NULL CHECK (requested_quantity > 0),
  requested_unit text NOT NULL DEFAULT 'un' CHECK (requested_unit IN ('un','ml','l','g','kg')),
  status text NOT NULL CHECK (status IN ('settled','partial','pending')),
  inventory_operation_id uuid REFERENCES public.inventory_operations(id) ON DELETE SET NULL,
  actual_cost numeric(12,6),
  settled_quantity numeric(12,6) NOT NULL DEFAULT 0 CHECK (settled_quantity >= 0),
  pending_quantity numeric(12,6) NOT NULL DEFAULT 0 CHECK (pending_quantity >= 0),
  issue_message text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(order_item_id)
);
CREATE INDEX IF NOT EXISTS order_inventory_settlements_stock_status
  ON public.order_inventory_settlements(stock_id,status,created_at DESC);
CREATE INDEX IF NOT EXISTS order_inventory_settlements_order
  ON public.order_inventory_settlements(order_id);
CREATE INDEX IF NOT EXISTS order_inventory_settlements_operation
  ON public.order_inventory_settlements(inventory_operation_id)
  WHERE inventory_operation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS order_inventory_settlements_product
  ON public.order_inventory_settlements(product_id)
  WHERE product_id IS NOT NULL;

ALTER TABLE public.order_inventory_settlements
  ADD COLUMN IF NOT EXISTS settled_quantity numeric(12,6) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS pending_quantity numeric(12,6) NOT NULL DEFAULT 0;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.order_inventory_settlements'::regclass
    AND conname='order_inventory_settlements_status_check') THEN
    ALTER TABLE public.order_inventory_settlements DROP CONSTRAINT order_inventory_settlements_status_check;
  END IF;
  ALTER TABLE public.order_inventory_settlements ADD CONSTRAINT order_inventory_settlements_status_check
    CHECK (status IN ('settled','partial','pending'));
END $$;
UPDATE public.order_inventory_settlements SET
  settled_quantity=CASE WHEN status='settled' THEN requested_quantity ELSE 0 END,
  pending_quantity=CASE WHEN status='settled' THEN 0 ELSE requested_quantity END
WHERE settled_quantity=0 AND pending_quantity=0;

-- The manual cost is a fallback selected in the menu. It is copied to each
-- order line at creation time, so later menu changes never rewrite history.
UPDATE public.order_sale_items line
SET manual_unit_cost=catalog.unit_cost
FROM public.order_catalog_items catalog
WHERE line.catalog_item_id=catalog.id AND line.manual_unit_cost IS NULL
  AND EXISTS(SELECT 1 FROM public.order_sales sale WHERE sale.id=line.order_id AND sale.status<>'finished');

UPDATE public.order_sales
SET inventory_status=CASE WHEN inventory_operation_id IS NOT NULL THEN 'settled' ELSE 'pending' END
WHERE status='finished' AND inventory_status='not_processed';

CREATE OR REPLACE FUNCTION public.order_inventory_operation_cost(
  p_operation_id uuid,p_product_id uuid
)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT coalesce(sum(abs(m.quantity)*m.cost_per_base),0)
  FROM public.inventory_operation_items item
  JOIN public.inventory_movements m ON m.item_id=item.id
  WHERE item.operation_id=p_operation_id AND (p_product_id IS NULL OR item.product_id=p_product_id)
$$;

CREATE OR REPLACE FUNCTION public.orders_catalog_board(p_stock_id uuid, p_board_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF NOT EXISTS (SELECT 1 FROM public.order_boards WHERE id=p_board_id AND stock_id=p_stock_id) THEN
    RAISE EXCEPTION 'Kanban não encontrado neste estoque.' USING ERRCODE='P0002';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,'sourceProductId',c.product_id,'sourceStockId',c.stock_id,
    'name',p.name,'code',p.sku,'category',coalesce(p.type_name,'Sem categoria'),
    'isKit',p.is_kit,'suggestedPrice',coalesce(p.suggested_sale_price,p.next_sale),
    'price',c.price,'unitCost',c.unit_cost,'importedAt',c.imported_at
  ) ORDER BY p.name,c.id),'[]'::jsonb) INTO result
  FROM public.order_catalog_items c
  JOIN public.product_catalog p ON p.id=c.product_id
  WHERE c.stock_id=p_stock_id AND c.board_id=p_board_id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_import_catalog_board(
  p_stock_id uuid,p_board_id uuid,p_items jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  entry jsonb; product_id uuid; catalog_id uuid; price_value numeric; unit_cost_value numeric;
  imported uuid[]:='{}'; seen uuid[]:='{}'; result jsonb;
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
    product_id:=(entry->>'sourceProductId')::uuid;
    price_value:=(entry->>'price')::numeric;
    unit_cost_value:=CASE WHEN jsonb_typeof(entry->'unitCost')='number'
      THEN (entry->>'unitCost')::numeric ELSE NULL END;
    IF product_id=ANY(seen) OR price_value<0 OR price_value>99999999.99
      OR price_value<>round(price_value,2) OR (unit_cost_value IS NOT NULL
        AND (unit_cost_value<0 OR unit_cost_value>99999999.99 OR unit_cost_value<>round(unit_cost_value,2))) THEN
      RAISE EXCEPTION 'Produto, preço de venda ou custo unitário inválido.' USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id=product_id AND p.stock_id=p_stock_id AND p.active) THEN
      RAISE EXCEPTION 'Produto não encontrado ou inativo neste estoque.' USING ERRCODE='22023';
    END IF;
    seen:=array_append(seen,product_id);
    INSERT INTO public.order_catalog_items(stock_id,board_id,product_id,price,unit_cost)
      VALUES(p_stock_id,p_board_id,product_id,price_value,unit_cost_value)
      ON CONFLICT(board_id,product_id) DO UPDATE SET
        price=excluded.price,
        unit_cost=coalesce(excluded.unit_cost,public.order_catalog_items.unit_cost),
        imported_at=now()
      RETURNING id INTO catalog_id;
    imported:=array_append(imported,catalog_id);
  END LOOP;
  SELECT coalesce(jsonb_agg(row.value),'[]'::jsonb) INTO result
  FROM jsonb_array_elements(public.orders_catalog_board(p_stock_id,p_board_id)) row(value)
  WHERE (row.value->>'id')::uuid=ANY(imported);
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_update_catalog_item_board(
  p_stock_id uuid,p_board_id uuid,p_catalog_id uuid,p_price numeric,p_unit_cost numeric DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF p_price IS NULL OR p_price<0 OR p_price>99999999.99 OR p_price<>round(p_price,2)
    OR (p_unit_cost IS NOT NULL AND (p_unit_cost<0 OR p_unit_cost>99999999.99 OR p_unit_cost<>round(p_unit_cost,2))) THEN
    RAISE EXCEPTION 'Preço de venda ou custo unitário inválido.' USING ERRCODE='22023';
  END IF;
  UPDATE public.order_catalog_items SET price=p_price,unit_cost=p_unit_cost
  WHERE id=p_catalog_id AND stock_id=p_stock_id AND board_id=p_board_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produto importado não encontrado neste kanban.' USING ERRCODE='P0002'; END IF;
  SELECT row.value INTO result FROM jsonb_array_elements(public.orders_catalog_board(p_stock_id,p_board_id)) row(value)
  WHERE (row.value->>'id')::uuid=p_catalog_id;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_update_price_board(
  p_stock_id uuid,p_board_id uuid,p_catalog_id uuid,p_price numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE current_cost numeric;
BEGIN
  SELECT unit_cost INTO current_cost FROM public.order_catalog_items
  WHERE id=p_catalog_id AND stock_id=p_stock_id AND board_id=p_board_id;
  RETURN public.orders_update_catalog_item_board(p_stock_id,p_board_id,p_catalog_id,p_price,current_cost);
END $$;

CREATE OR REPLACE FUNCTION public.orders_create_board(
  p_stock_id uuid,p_board_id uuid,p_data jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  entry jsonb; order_id uuid; catalog_id uuid; line record; quantity integer;
  suggested numeric:=0; final_total numeric; paid_amount numeric;
  customer_name text; note_text text; seen uuid[]:='{}';
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
  final_total:=(p_data->>'finalTotal')::numeric;
  paid_amount:=(p_data->>'paid')::numeric;
  IF final_total<0 OR paid_amount<0 OR final_total>99999999.99 OR paid_amount>99999999.99
    OR final_total<>round(final_total,2) OR paid_amount<>round(paid_amount,2) THEN
    RAISE EXCEPTION 'Valores do pedido inválidos.' USING ERRCODE='22023';
  END IF;
  PERFORM 1 FROM public.stocks WHERE id=p_stock_id FOR UPDATE;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
    IF jsonb_typeof(entry)<>'object' OR jsonb_typeof(entry->'quantity')<>'number'
      OR nullif(entry->>'productId','') IS NULL THEN RAISE EXCEPTION 'Item inválido.' USING ERRCODE='22023'; END IF;
    catalog_id:=(entry->>'productId')::uuid;
    quantity:=(entry->>'quantity')::integer;
    IF (entry->>'quantity')::numeric<>quantity OR quantity NOT BETWEEN 1 AND 999 OR catalog_id=ANY(seen) THEN
      RAISE EXCEPTION 'Item repetido ou quantidade inválida.' USING ERRCODE='22023';
    END IF;
    SELECT c.id,c.product_id,p.name,c.price,c.unit_cost INTO line
    FROM public.order_catalog_items c JOIN public.products p ON p.id=c.product_id
    WHERE c.id=catalog_id AND c.stock_id=p_stock_id AND c.board_id=p_board_id AND p.active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Um item não pertence ao catálogo deste kanban.' USING ERRCODE='22023'; END IF;
    seen:=array_append(seen,catalog_id);
    suggested:=suggested+line.price*quantity;
  END LOOP;
  INSERT INTO public.order_sales(stock_id,board_id,customer,note,suggested_total,final_total,paid)
    VALUES(p_stock_id,p_board_id,customer_name,note_text,suggested,final_total,paid_amount)
    RETURNING id INTO order_id;
  FOR entry IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
    SELECT c.id,c.product_id,p.name,c.price,c.unit_cost INTO line
    FROM public.order_catalog_items c JOIN public.products p ON p.id=c.product_id
    WHERE c.id=(entry->>'productId')::uuid AND c.stock_id=p_stock_id AND c.board_id=p_board_id;
    INSERT INTO public.order_sale_items(order_id,catalog_item_id,product_id,product_name,quantity,unit_price,manual_unit_cost)
      VALUES(order_id,line.id,line.product_id,line.name,(entry->>'quantity')::integer,line.price,line.unit_cost);
  END LOOP;
  RETURN public.orders_get_board(p_stock_id,p_board_id,order_id);
END $$;

CREATE OR REPLACE FUNCTION public.orders_change_status_board(
  p_stock_id uuid,p_board_id uuid,p_order_id uuid,p_status text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  previous_status text; line_operation_id uuid; order_item record; line_cost numeric;
  available_quantity numeric; settled_quantity numeric; pending_quantity numeric;
  failure_message text; settled_count integer:=0; pending_count integer:=0;
  partial_count integer:=0; resulting_inventory_status text:='not_processed';
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF p_status='finished' THEN
    -- Inventory operations also lock this row, so availability and decrement
    -- stay consistent while this sale is being finalized.
    PERFORM 1 FROM public.stocks WHERE id=p_stock_id FOR UPDATE;
  END IF;
  SELECT status INTO previous_status FROM public.order_sales
    WHERE id=p_order_id AND stock_id=p_stock_id AND board_id=p_board_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado neste kanban.' USING ERRCODE='P0002'; END IF;
  IF NOT ((previous_status='waiting' AND p_status IN ('preparing','cancelled'))
    OR (previous_status='preparing' AND p_status IN ('waiting','finished','cancelled'))
    OR (previous_status='cancelled' AND p_status='waiting')) THEN
    RAISE EXCEPTION 'Transição de status inválida.' USING ERRCODE='22023';
  END IF;

  IF p_status='finished' THEN
    -- Use one FIFO operation per sale line. This keeps kit component costs
    -- attributable to the right order item and lets each line settle partially.
    FOR order_item IN
      SELECT i.id,coalesce(i.product_id,c.product_id) AS product_id,i.quantity,i.manual_unit_cost
      FROM public.order_sale_items i LEFT JOIN public.order_catalog_items c ON c.id=i.catalog_item_id
      WHERE i.order_id=p_order_id ORDER BY i.id
    LOOP
      line_operation_id:=NULL; line_cost:=NULL; settled_quantity:=0;
      pending_quantity:=order_item.quantity; failure_message:=NULL;
      BEGIN
        IF order_item.product_id IS NULL THEN
          RAISE EXCEPTION 'Produto deste pedido não existe mais no estoque.' USING ERRCODE='23514';
        END IF;
        SELECT CASE WHEN product.is_kit THEN (
          SELECT capacity.whole_units FROM public.estimate_kit_capacity(p_stock_id,product.id) capacity
        ) ELSE (
          SELECT coalesce(sum(floor(lot.quantity_remaining/public.content_base(product.content_quantity,product.content_unit))),0)
          FROM public.stock_lots lot WHERE lot.product_id=product.id AND lot.quantity_remaining>0
        ) END INTO available_quantity
        FROM public.products product
        WHERE product.id=order_item.product_id AND product.stock_id=p_stock_id AND product.active;
        IF NOT FOUND THEN RAISE EXCEPTION 'Produto ativo não encontrado neste estoque.' USING ERRCODE='23514'; END IF;

        settled_quantity:=least(order_item.quantity,greatest(floor(coalesce(available_quantity,0)),0));
        pending_quantity:=order_item.quantity-settled_quantity;
        IF settled_quantity>0 THEN
          SELECT public.decrement_inventory(p_stock_id,'pedido:'||p_order_id||':item:'||order_item.id,
            jsonb_build_object('reason','Venda concluída com baixa FIFO parcial por item','items',jsonb_build_array(
              jsonb_build_object('product_id',order_item.product_id,'quantity',settled_quantity,'unit','un'))))
          INTO line_operation_id;
          line_cost:=public.order_inventory_operation_cost(line_operation_id,NULL);
        END IF;

        INSERT INTO public.order_inventory_settlements(
          stock_id,order_id,order_item_id,product_id,requested_quantity,requested_unit,status,
          inventory_operation_id,actual_cost,settled_quantity,pending_quantity,issue_message
        ) VALUES(p_stock_id,p_order_id,order_item.id,order_item.product_id,order_item.quantity,'un',
          CASE WHEN pending_quantity=0 THEN 'settled' WHEN settled_quantity>0 THEN 'partial' ELSE 'pending' END,
          line_operation_id,line_cost,settled_quantity,pending_quantity,
          CASE WHEN pending_quantity>0 THEN 'Saldo insuficiente; diferença pendente de regularização.' END)
        ON CONFLICT(order_item_id) DO UPDATE SET
          status=excluded.status,inventory_operation_id=excluded.inventory_operation_id,
          actual_cost=excluded.actual_cost,settled_quantity=excluded.settled_quantity,
          pending_quantity=excluded.pending_quantity,issue_message=excluded.issue_message,updated_at=now();

        UPDATE public.order_sale_items SET
          cost_source=CASE
            WHEN pending_quantity=0 THEN 'inventory'
            WHEN order_item.manual_unit_cost IS NULL THEN 'missing'
            WHEN settled_quantity>0 THEN 'mixed'
            ELSE 'manual'
          END,
          unit_cost_snapshot=CASE
            WHEN pending_quantity=0 THEN round(coalesce(line_cost,0)/order_item.quantity,6)
            WHEN order_item.manual_unit_cost IS NOT NULL THEN round((coalesce(line_cost,0)
              + order_item.manual_unit_cost*pending_quantity)/order_item.quantity,6)
            ELSE NULL
          END
        WHERE id=order_item.id;

        IF pending_quantity>0 THEN pending_count:=pending_count+1; END IF;
        IF settled_quantity>0 AND pending_quantity>0 THEN partial_count:=partial_count+1; END IF;
        IF pending_quantity=0 THEN settled_count:=settled_count+1; END IF;
      EXCEPTION WHEN OTHERS THEN
        failure_message:=SQLERRM;
        INSERT INTO public.order_inventory_settlements(
          stock_id,order_id,order_item_id,product_id,requested_quantity,requested_unit,status,
          settled_quantity,pending_quantity,issue_message
        ) VALUES(p_stock_id,p_order_id,order_item.id,order_item.product_id,order_item.quantity,'un','pending',
          0,order_item.quantity,failure_message)
        ON CONFLICT(order_item_id) DO UPDATE SET status='pending',inventory_operation_id=NULL,actual_cost=NULL,
          settled_quantity=0,pending_quantity=excluded.pending_quantity,issue_message=excluded.issue_message,updated_at=now();
        UPDATE public.order_sale_items SET
          cost_source=CASE WHEN order_item.manual_unit_cost IS NULL THEN 'missing' ELSE 'manual' END,
          unit_cost_snapshot=order_item.manual_unit_cost
        WHERE id=order_item.id;
        pending_count:=pending_count+1;
      END;
    END LOOP;
    resulting_inventory_status:=CASE
      WHEN pending_count=0 THEN 'settled'
      WHEN settled_count>0 OR partial_count>0 THEN 'partial'
      ELSE 'pending'
    END;

    -- Freeze per-line revenue, cost provenance and margin at completion.
    WITH line_data AS (
      SELECT i.id,i.quantity*i.unit_price AS listed_revenue,i.quantity,o.suggested_total,o.final_total,
        count(*) OVER(PARTITION BY o.id) AS line_count,
        row_number() OVER(PARTITION BY o.id ORDER BY i.id) AS line_position,
        sum(i.quantity) OVER(PARTITION BY o.id) AS quantity_total,
        sum(i.quantity*i.unit_price) OVER(PARTITION BY o.id) AS listed_total,
        s.status AS settlement_status,s.pending_quantity,s.actual_cost,
        i.manual_unit_cost,i.cost_source
      FROM public.order_sale_items i JOIN public.order_sales o ON o.id=i.order_id
      LEFT JOIN public.order_inventory_settlements s ON s.order_item_id=i.id
      WHERE i.order_id=p_order_id
    ), raw_revenue AS (
      SELECT d.*,
        CASE WHEN d.suggested_total>0 THEN d.final_total*d.listed_revenue/d.suggested_total
          WHEN d.quantity_total>0 THEN d.final_total*d.quantity/d.quantity_total ELSE 0 END AS raw_line_revenue
      FROM line_data d
    ), allocated AS (
      SELECT r.*,
        CASE WHEN r.line_position=r.line_count THEN r.final_total-coalesce(sum(round(r.raw_line_revenue,2))
          OVER(ORDER BY r.line_position ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0)
          ELSE round(r.raw_line_revenue,2) END AS line_revenue
      FROM raw_revenue r
    ), costed AS (
      SELECT a.*,
        CASE
          WHEN a.settlement_status='settled' THEN a.actual_cost
          WHEN a.settlement_status='partial' THEN coalesce(a.actual_cost,0)
            + CASE WHEN a.manual_unit_cost IS NOT NULL THEN a.manual_unit_cost*a.pending_quantity ELSE 0 END
          WHEN a.settlement_status='pending' AND a.manual_unit_cost IS NOT NULL THEN a.manual_unit_cost*a.quantity
          ELSE a.actual_cost
        END AS line_cost,
        CASE WHEN a.settlement_status='settled' THEN a.actual_cost IS NOT NULL
          WHEN a.settlement_status='partial' THEN a.pending_quantity=0 OR a.manual_unit_cost IS NOT NULL
          WHEN a.settlement_status='pending' THEN a.manual_unit_cost IS NOT NULL
          ELSE false END AS is_cost_complete
      FROM allocated a
    )
    UPDATE public.order_sale_items i SET
      final_revenue_snapshot=costed.line_revenue,
      final_cost_snapshot=costed.line_cost,
      cost_complete_snapshot=costed.is_cost_complete,
      margin_snapshot=CASE WHEN costed.is_cost_complete AND costed.line_revenue<>0
        THEN round((costed.line_revenue-costed.line_cost)/costed.line_revenue*100,4) END
    FROM costed WHERE i.id=costed.id;
  END IF;

  UPDATE public.order_sales SET
    status=p_status,
    updated_at=now(),
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
      'productId',coalesce(i.catalog_item_id::text,''),'name',i.product_name,'quantity',i.quantity,'unitPrice',i.unit_price
    ) ORDER BY i.id) FROM public.order_sale_items i WHERE i.order_id=o.id),'[]'::jsonb)
  ) INTO result
  FROM public.order_sales o JOIN public.order_boards b ON b.id=o.board_id
  WHERE o.id=p_order_id AND o.stock_id=p_stock_id AND o.board_id=p_board_id;
  RETURN result;
END $$;

-- Analytics use FIFO when it was settled and the frozen manual unit cost only
-- when there was an inventory pending item. Older completed orders still use the
-- legacy single inventory operation link.
CREATE OR REPLACE FUNCTION public.order_analytics_lines(
  p_stock_id uuid,p_board_ids uuid[],p_from timestamptz,p_to timestamptz
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
  IF p_from IS NULL OR p_to IS NULL OR p_to<=p_from OR p_to-p_from>interval '366 days' THEN
    RAISE EXCEPTION 'Intervalo de análise inválido.' USING ERRCODE='22023';
  END IF;
  IF coalesce(cardinality(p_board_ids),0)>0 AND EXISTS(
    SELECT 1 FROM unnest(p_board_ids) b WHERE NOT EXISTS(
      SELECT 1 FROM public.order_boards board WHERE board.id=b AND board.stock_id=p_stock_id)) THEN
    RAISE EXCEPTION 'Kanban não pertence ao estoque selecionado.' USING ERRCODE='42501';
  END IF;
  RETURN QUERY
  WITH selected_orders AS (
    SELECT o.id,o.number,o.board_id,b.name AS board_name,o.customer,o.created_at,o.finished_at,
      o.suggested_total,o.final_total,o.inventory_operation_id
    FROM public.order_sales o JOIN public.order_boards b ON b.id=o.board_id
    WHERE o.stock_id=p_stock_id AND o.status='finished' AND o.finished_at>=p_from AND o.finished_at<p_to
      AND (coalesce(cardinality(p_board_ids),0)=0 OR o.board_id=ANY(p_board_ids))
  ), source_lines AS (
    SELECT o.*,i.id AS source_line_id,coalesce(i.product_id,catalog.product_id) AS source_product_id,
      i.product_name AS source_product_name,product.sku AS source_sku,coalesce(product.is_kit,false) AS source_is_kit,
      i.quantity AS source_quantity,i.unit_price AS source_unit_price,i.quantity*i.unit_price AS source_listed_revenue,
      i.cost_source,i.manual_unit_cost,i.unit_cost_snapshot,i.final_revenue_snapshot,i.final_cost_snapshot,i.cost_complete_snapshot,
      settlement.status AS settlement_status,settlement.actual_cost AS settlement_cost,settlement.pending_quantity AS settlement_pending_quantity,
      count(*) OVER(PARTITION BY o.id) AS line_count,row_number() OVER(PARTITION BY o.id ORDER BY i.id) AS line_position,
      sum(i.quantity) OVER(PARTITION BY o.id) AS quantity_total
    FROM selected_orders o JOIN public.order_sale_items i ON i.order_id=o.id
    LEFT JOIN public.order_catalog_items catalog ON catalog.id=i.catalog_item_id
    LEFT JOIN public.products product ON product.id=coalesce(i.product_id,catalog.product_id)
    LEFT JOIN public.order_inventory_settlements settlement ON settlement.order_item_id=i.id
  ), raw_allocations AS (
    SELECT source_lines.*,coalesce(source_lines.final_revenue_snapshot,
      CASE WHEN source_lines.suggested_total>0 THEN source_lines.final_total*source_lines.source_listed_revenue/source_lines.suggested_total
        WHEN source_lines.quantity_total>0 THEN source_lines.final_total*source_lines.source_quantity/source_lines.quantity_total ELSE 0 END) AS raw_revenue
    FROM source_lines
  ), allocations AS (
    SELECT raw_allocations.*,CASE WHEN raw_allocations.line_position=raw_allocations.line_count THEN raw_allocations.final_total-coalesce(
      sum(round(raw_allocations.raw_revenue,2)) OVER(PARTITION BY raw_allocations.id ORDER BY raw_allocations.source_line_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0)
      ELSE round(raw_allocations.raw_revenue,2) END AS line_revenue
    FROM raw_allocations
  ), legacy_costs AS (
    SELECT o.id AS cost_order_id,item.product_id AS cost_product_id,sum(abs(m.quantity)*m.cost_per_base) AS total_cost
    FROM selected_orders o JOIN public.inventory_operation_items item ON item.operation_id=o.inventory_operation_id
    JOIN public.inventory_movements m ON m.item_id=item.id GROUP BY o.id,item.product_id
  ), calculated AS (
    SELECT a.*,CASE
      WHEN a.final_cost_snapshot IS NOT NULL THEN a.final_cost_snapshot
      WHEN a.settlement_status='settled' AND a.settlement_cost IS NOT NULL THEN a.settlement_cost
      WHEN a.settlement_status='partial' THEN coalesce(a.settlement_cost,0)
        + CASE WHEN a.manual_unit_cost IS NOT NULL THEN a.manual_unit_cost*coalesce(a.settlement_pending_quantity,0) ELSE 0 END
      WHEN a.cost_source IN ('manual','mixed') AND a.unit_cost_snapshot IS NOT NULL THEN a.unit_cost_snapshot*a.source_quantity
      WHEN legacy_costs.cost_order_id IS NOT NULL THEN legacy_costs.total_cost
      ELSE NULL END AS line_cost
    FROM allocations a LEFT JOIN legacy_costs ON legacy_costs.cost_order_id=a.id
      AND legacy_costs.cost_product_id=a.source_product_id
  )
  SELECT c.id,c.number,c.board_id,c.board_name,c.customer,c.created_at,c.finished_at,c.suggested_total,c.final_total,
    c.source_line_id,c.source_product_id,c.source_product_name,c.source_sku,c.source_is_kit,c.source_quantity,
    c.source_unit_price,c.source_listed_revenue,c.line_revenue,c.line_cost,
    coalesce(c.cost_complete_snapshot,c.line_cost IS NOT NULL)
  FROM calculated c;
END $$;

CREATE OR REPLACE FUNCTION public.orders_analytics_order_detail(p_stock_id uuid,p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb; completed_at timestamptz;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  SELECT finished_at INTO completed_at FROM public.order_sales
    WHERE id=p_order_id AND stock_id=p_stock_id AND status='finished';
  IF completed_at IS NULL THEN RAISE EXCEPTION 'Pedido finalizado não encontrado.' USING ERRCODE='P0002'; END IF;
  WITH lines AS (
    SELECT * FROM public.order_analytics_lines(p_stock_id,NULL,completed_at-interval '1 microsecond',completed_at+interval '1 microsecond')
    WHERE order_id=p_order_id
  ), header AS (
    SELECT max(order_number) AS number,max(board_name) AS board_name,max(customer) AS customer,
      max(created_at) AS created_at,max(finished_at) AS finished_at,max(final_total) AS final_total,
      sum(allocated_revenue) AS revenue,bool_and(cost_complete) AS cost_complete,
      CASE WHEN bool_and(cost_complete) THEN sum(actual_cost) END AS cost
    FROM lines
  )
  SELECT jsonb_build_object(
    'order',(SELECT jsonb_build_object('number',number,'boardName',board_name,'customer',customer,
      'createdAt',created_at,'finishedAt',finished_at,'finalTotal',final_total,'revenue',revenue,
      'cost',cost,'profit',CASE WHEN cost_complete THEN revenue-cost END,
      'margin',CASE WHEN cost_complete THEN round((revenue-cost)/nullif(revenue,0)*100,2) END,
      'costComplete',cost_complete) FROM header),
    'items',coalesce((SELECT jsonb_agg(jsonb_build_object(
      'productId',line.product_id,'name',line.product_name,'code',line.sku,'isKit',line.is_kit,
      'quantity',line.quantity,'unitPrice',line.unit_price,'listedRevenue',line.listed_revenue,
      'revenue',line.allocated_revenue,'cost',line.actual_cost,
      'profit',CASE WHEN line.cost_complete THEN line.allocated_revenue-line.actual_cost END,
      'margin',CASE WHEN line.cost_complete THEN round((line.allocated_revenue-line.actual_cost)/nullif(line.allocated_revenue,0)*100,2) END,
      'costComplete',line.cost_complete,
      'lots',coalesce((SELECT jsonb_agg(jsonb_build_object('lotId',lot.id,'code',lot.code,
        'productName',component.name,'quantityBase',abs(movement.quantity),
        'cost',abs(movement.quantity)*movement.cost_per_base) ORDER BY lot.acquired_at,lot.id)
        FROM public.order_sale_items sale_line
        JOIN public.order_sales sale ON sale.id=sale_line.order_id
        LEFT JOIN public.order_inventory_settlements settlement ON settlement.order_item_id=sale_line.id
        JOIN public.inventory_operation_items operation_item ON operation_item.operation_id=
          coalesce(settlement.inventory_operation_id,sale.inventory_operation_id)
        JOIN public.inventory_movements movement ON movement.item_id=operation_item.id
        JOIN public.stock_lots lot ON lot.id=movement.lot_id
        JOIN public.products component ON component.id=lot.product_id
        WHERE sale_line.id=line.line_id),'[]'::jsonb)
    ) ORDER BY line.product_name) FROM lines line),'[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.orders_inventory_health(
  p_stock_id uuid,p_board_ids uuid[],p_from timestamptz,p_to timestamptz
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM public.assert_stock(p_stock_id);
  IF p_from IS NULL OR p_to IS NULL OR p_to<=p_from OR p_to-p_from>interval '366 days' THEN
    RAISE EXCEPTION 'Intervalo de análise inválido.' USING ERRCODE='22023';
  END IF;
  WITH scoped_orders AS (
    SELECT o.id,o.inventory_status FROM public.order_sales o
    WHERE o.stock_id=p_stock_id AND o.status='finished' AND o.finished_at>=p_from AND o.finished_at<p_to
      AND (coalesce(cardinality(p_board_ids),0)=0 OR o.board_id=ANY(p_board_ids))
  ), scoped_items AS (
    SELECT i.* FROM public.order_sale_items i JOIN scoped_orders o ON o.id=i.order_id
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

REVOKE ALL ON FUNCTION public.order_inventory_operation_cost(uuid,uuid),
  public.orders_inventory_health(uuid,uuid[],timestamptz,timestamptz),
  public.orders_update_catalog_item_board(uuid,uuid,uuid,numeric,numeric) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.orders_inventory_health(uuid,uuid[],timestamptz,timestamptz),
  public.orders_update_catalog_item_board(uuid,uuid,uuid,numeric,numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
