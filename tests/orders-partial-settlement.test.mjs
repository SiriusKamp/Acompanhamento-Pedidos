import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

const owner = '10000000-0000-0000-0000-000000000401';
const stock = '20000000-0000-0000-0000-000000000401';
const board = '30000000-0000-0000-0000-000000000401';
const product = '40000000-0000-0000-0000-000000000401';
const order = '50000000-0000-0000-0000-000000000401';
const orderItem = '60000000-0000-0000-0000-000000000401';
const lot = '70000000-0000-0000-0000-000000000401';
const db = await PGlite.create();

function functionDdl(source, signature) {
  const start = source.indexOf(signature);
  assert.notEqual(start, -1, `Missing ${signature}`);
  const end = source.indexOf('END $$;', start);
  assert.notEqual(end, -1, `Unterminated ${signature}`);
  return source.slice(start, end + 'END $$;'.length);
}

try {
  await db.exec(`
    CREATE SCHEMA auth;
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
      SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
    $$;
    CREATE TABLE public.stocks(id uuid PRIMARY KEY,user_id uuid NOT NULL);
    CREATE TABLE public.order_boards(id uuid PRIMARY KEY,stock_id uuid NOT NULL,name text NOT NULL);
    CREATE TABLE public.products(
      id uuid PRIMARY KEY,stock_id uuid NOT NULL,is_kit boolean NOT NULL DEFAULT false,
      active boolean NOT NULL DEFAULT true,content_quantity numeric NOT NULL,content_unit text NOT NULL,name text NOT NULL,
      sku text NOT NULL
    );
    CREATE TABLE public.stock_lots(
      id uuid PRIMARY KEY,product_id uuid NOT NULL,quantity_remaining numeric NOT NULL,
      unit_cost numeric NOT NULL,acquired_at timestamptz NOT NULL DEFAULT now(),code text NOT NULL
    );
    CREATE TABLE public.order_catalog_items(id uuid PRIMARY KEY,product_id uuid NOT NULL);
    CREATE TABLE public.order_sales(
      id uuid PRIMARY KEY,stock_id uuid NOT NULL,board_id uuid NOT NULL,number bigint NOT NULL,customer text NOT NULL DEFAULT '',
      created_at timestamptz NOT NULL DEFAULT now(),status text NOT NULL,
      inventory_status text NOT NULL DEFAULT 'not_processed',suggested_total numeric NOT NULL,
      final_total numeric NOT NULL,finished_at timestamptz,updated_at timestamptz DEFAULT now(),inventory_operation_id uuid
    );
    CREATE TABLE public.order_sale_items(
      id uuid PRIMARY KEY,order_id uuid NOT NULL,product_id uuid,catalog_item_id uuid,product_name text NOT NULL,
      quantity integer NOT NULL,unit_price numeric NOT NULL,manual_unit_cost numeric,
      cost_source text,unit_cost_snapshot numeric,final_revenue_snapshot numeric,final_cost_snapshot numeric,
      cost_complete_snapshot boolean,margin_snapshot numeric
    );
    CREATE TABLE public.order_inventory_settlements(
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),stock_id uuid NOT NULL,order_id uuid NOT NULL,
      order_item_id uuid NOT NULL UNIQUE,product_id uuid,requested_quantity numeric NOT NULL,requested_unit text NOT NULL,
      status text NOT NULL,inventory_operation_id uuid,actual_cost numeric,settled_quantity numeric NOT NULL DEFAULT 0,
      pending_quantity numeric NOT NULL DEFAULT 0,issue_message text,created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now()
    );
    CREATE TABLE public.inventory_operations(
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),stock_id uuid NOT NULL,reference text NOT NULL UNIQUE,
      kind text NOT NULL,request_payload jsonb NOT NULL
    );
    CREATE TABLE public.inventory_operation_items(
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),operation_id uuid NOT NULL,product_id uuid NOT NULL,
      quantity numeric NOT NULL,unit text NOT NULL
    );
    CREATE TABLE public.inventory_movements(
      item_id uuid NOT NULL,lot_id uuid NOT NULL,quantity numeric NOT NULL,cost_per_base numeric NOT NULL
    );
    CREATE FUNCTION public.assert_stock(p_stock_id uuid) RETURNS void LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT EXISTS(SELECT 1 FROM public.stocks WHERE id=p_stock_id AND user_id=auth.uid()) THEN
        RAISE EXCEPTION 'Estoque não encontrado.';
      END IF;
    END $$;
    CREATE FUNCTION public.content_base(p_quantity numeric,p_unit text) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
      SELECT CASE WHEN p_unit='un' THEN p_quantity ELSE p_quantity END
    $$;
    CREATE FUNCTION public.estimate_kit_capacity(p_stock_id uuid,p_kit_id uuid)
      RETURNS TABLE(whole_units numeric) LANGUAGE sql AS $$ SELECT 0::numeric $$;
    CREATE FUNCTION public.decrement_inventory(p_stock_id uuid,p_reference text,p_data jsonb)
      RETURNS uuid LANGUAGE plpgsql AS $$
    DECLARE op uuid; entry jsonb; remaining numeric; take numeric; movement_item uuid; lot_row record;
    BEGIN
      SELECT id INTO op FROM public.inventory_operations WHERE stock_id=p_stock_id AND reference=p_reference;
      IF op IS NOT NULL THEN RETURN op; END IF;
      INSERT INTO public.inventory_operations(stock_id,reference,kind,request_payload)
        VALUES(p_stock_id,p_reference,'OUT',p_data) RETURNING id INTO op;
      FOR entry IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
        remaining:=(entry->>'quantity')::numeric;
        INSERT INTO public.inventory_operation_items(operation_id,product_id,quantity,unit)
          VALUES(op,(entry->>'product_id')::uuid,remaining,entry->>'unit') RETURNING id INTO movement_item;
        FOR lot_row IN SELECT * FROM public.stock_lots WHERE product_id=(entry->>'product_id')::uuid
          AND quantity_remaining>0 ORDER BY acquired_at,id FOR UPDATE LOOP
          EXIT WHEN remaining<=0;
          take:=least(remaining,floor(lot_row.quantity_remaining/public.content_base(1,'un')));
          IF take<=0 THEN CONTINUE; END IF;
          UPDATE public.stock_lots SET quantity_remaining=quantity_remaining-take WHERE id=lot_row.id;
          INSERT INTO public.inventory_movements(item_id,lot_id,quantity,cost_per_base)
            VALUES(movement_item,lot_row.id,-take,lot_row.unit_cost);
          remaining:=remaining-take;
        END LOOP;
        IF remaining>0 THEN RAISE EXCEPTION 'Saldo insuficiente'; END IF;
      END LOOP;
      RETURN op;
    END $$;
    CREATE FUNCTION public.orders_get_board(p_stock_id uuid,p_board_id uuid,p_order_id uuid)
      RETURNS jsonb LANGUAGE sql STABLE AS $$
        SELECT jsonb_build_object('id',o.id,'status',o.status,'inventoryStatus',o.inventory_status)
        FROM public.order_sales o WHERE o.id=p_order_id AND o.stock_id=p_stock_id AND o.board_id=p_board_id
      $$;
    INSERT INTO public.stocks VALUES('${stock}','${owner}');
    INSERT INTO public.order_boards VALUES('${board}','${stock}','Hoje');
    INSERT INTO public.products VALUES('${product}','${stock}',false,true,1,'un','Item teste','ITEM-1');
    INSERT INTO public.stock_lots(id,product_id,quantity_remaining,unit_cost,code) VALUES('${lot}','${product}',2,2,'LOTE-1');
    INSERT INTO public.order_sales(id,stock_id,board_id,number,customer,status,suggested_total,final_total)
      VALUES('${order}','${stock}','${board}',401,'Balcão','preparing',50,40);
    INSERT INTO public.order_sale_items(id,order_id,product_id,product_name,quantity,unit_price,manual_unit_cost)
      VALUES('${orderItem}','${order}','${product}','Item teste',5,10,3);
    SELECT set_config('request.jwt.claim.sub','${owner}',false);
  `);

  const source = await readFile(new URL('../supabase/migration_order_sale_partial_settlement.sql', import.meta.url), 'utf8');
  await db.exec(functionDdl(source, 'CREATE OR REPLACE FUNCTION public.order_inventory_operation_cost('));
  await db.exec(functionDdl(source, 'CREATE OR REPLACE FUNCTION public.orders_change_status_board('));

  const result = (await db.query(
    "SELECT public.orders_change_status_board($1,$2,$3,'finished') AS result",
    [stock, board, order],
  )).rows[0].result;
  assert.equal(result.status, 'finished');
  assert.equal(result.inventoryStatus, 'partial');

  const settlement = (await db.query(
    'SELECT status,requested_quantity,settled_quantity,pending_quantity,actual_cost FROM public.order_inventory_settlements WHERE order_item_id=$1',
    [orderItem],
  )).rows[0];
  assert.equal(settlement.status, 'partial');
  assert.equal(Number(settlement.requested_quantity), 5);
  assert.equal(Number(settlement.settled_quantity), 2);
  assert.equal(Number(settlement.pending_quantity), 3);
  assert.equal(Number(settlement.actual_cost), 4);

  const snapshot = (await db.query(
    'SELECT cost_source,unit_cost_snapshot,final_revenue_snapshot,final_cost_snapshot,cost_complete_snapshot,margin_snapshot FROM public.order_sale_items WHERE id=$1',
    [orderItem],
  )).rows[0];
  assert.equal(snapshot.cost_source, 'mixed');
  assert.equal(Number(snapshot.unit_cost_snapshot), 2.6);
  assert.equal(Number(snapshot.final_revenue_snapshot), 40);
  assert.equal(Number(snapshot.final_cost_snapshot), 13);
  assert.equal(snapshot.cost_complete_snapshot, true);
  assert.equal(Number(snapshot.margin_snapshot), 67.5);
  assert.equal(Number((await db.query('SELECT quantity_remaining FROM public.stock_lots WHERE id=$1', [lot])).rows[0].quantity_remaining), 0);

  await db.exec(`
    CREATE FUNCTION public.order_analytics_lines(p_stock_id uuid,p_board_ids uuid[],p_from timestamptz,p_to timestamptz)
    RETURNS TABLE(order_id uuid,order_number bigint,board_id uuid,board_name text,customer text,
      created_at timestamptz,finished_at timestamptz,suggested_total numeric,final_total numeric,
      line_id uuid,product_id uuid,product_name text,sku text,is_kit boolean,quantity integer,
      unit_price numeric,listed_revenue numeric,allocated_revenue numeric,actual_cost numeric,cost_complete boolean)
    LANGUAGE sql AS $$
      SELECT o.id,o.number,o.board_id,b.name,o.customer,o.created_at,o.finished_at,o.suggested_total,o.final_total,
        i.id,i.product_id,i.product_name,p.sku,p.is_kit,i.quantity,i.unit_price,i.quantity*i.unit_price,
        i.final_revenue_snapshot,i.final_cost_snapshot,i.cost_complete_snapshot
      FROM public.order_sales o JOIN public.order_boards b ON b.id=o.board_id
      JOIN public.order_sale_items i ON i.order_id=o.id JOIN public.products p ON p.id=i.product_id
      WHERE o.stock_id=p_stock_id AND o.status='finished' AND o.finished_at>=p_from AND o.finished_at<p_to
    $$;
  `);
  await db.exec(functionDdl(source, 'CREATE OR REPLACE FUNCTION public.orders_analytics_order_detail('));
  const detail = (await db.query('SELECT public.orders_analytics_order_detail($1,$2) AS detail', [stock, order])).rows[0].detail;
  assert.equal(detail.items[0].costComplete, true);
  assert.equal(detail.items[0].lots[0].productName, 'Item teste');
  assert.equal(detail.items[0].lots[0].code, 'LOTE-1');
  assert.equal(Number(detail.items[0].lots[0].cost), 4);
  console.log('OK: pedido finalizado, estoque baixado até zero, diferença pendente e snapshots financeiros congelados.');
} finally {
  await db.close();
}
