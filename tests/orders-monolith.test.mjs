import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

const owner = '10000000-0000-0000-0000-000000000301';
const stranger = '10000000-0000-0000-0000-000000000302';
const stock = '20000000-0000-0000-0000-000000000301';
const foreignStock = '20000000-0000-0000-0000-000000000302';
const product = '30000000-0000-0000-0000-000000000301';
const foreignProduct = '30000000-0000-0000-0000-000000000302';
const db = await PGlite.create();

try {
  // Small stock fixture: the actual inventory schema supplies these same
  // ownership, catalog and decrement contracts in production.
  await db.exec(`
    CREATE ROLE anon NOLOGIN;
    CREATE ROLE authenticated NOLOGIN;
    CREATE SCHEMA auth;
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
      SELECT coalesce(
        nullif(current_setting('request.jwt.claim.sub', true), ''),
        nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
      )::uuid
    $$;
    CREATE TABLE public.stocks(id uuid PRIMARY KEY, user_id uuid NOT NULL, name text NOT NULL);
    CREATE TABLE public.products(
      id uuid PRIMARY KEY, stock_id uuid NOT NULL REFERENCES public.stocks(id),
      name text NOT NULL, sku text NOT NULL, is_kit boolean NOT NULL DEFAULT false,
      active boolean NOT NULL DEFAULT true, suggested_sale_price numeric,
      next_sale numeric, type_name text
    );
    CREATE VIEW public.product_catalog AS SELECT * FROM public.products;
    CREATE TABLE public.mock_balance(product_id uuid PRIMARY KEY REFERENCES public.products(id), quantity integer NOT NULL);
    CREATE TABLE public.mock_decrements(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      stock_id uuid NOT NULL, reference text NOT NULL, UNIQUE(stock_id, reference));
    CREATE FUNCTION public.assert_stock(p_stock_id uuid) RETURNS void
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
    BEGIN
      IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.stocks
        WHERE id = p_stock_id AND user_id = auth.uid()) THEN
        RAISE EXCEPTION 'Estoque não encontrado.' USING ERRCODE = '42501';
      END IF;
    END $$;
    CREATE FUNCTION public.decrement_inventory(p_stock_id uuid,p_reference text,p_data jsonb)
      RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
    DECLARE item jsonb; decrement_id uuid;
    BEGIN
      PERFORM public.assert_stock(p_stock_id);
      IF EXISTS(SELECT 1 FROM public.mock_decrements
        WHERE stock_id=p_stock_id AND reference=p_reference) THEN
        RAISE EXCEPTION 'Baixa duplicada';
      END IF;
      FOR item IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
        UPDATE public.mock_balance SET quantity=quantity-(item->>'quantity')::integer
          WHERE product_id=(item->>'product_id')::uuid
            AND quantity >= (item->>'quantity')::integer;
        IF NOT FOUND THEN RAISE EXCEPTION 'Saldo insuficiente'; END IF;
      END LOOP;
      INSERT INTO public.mock_decrements(stock_id,reference)
        VALUES(p_stock_id,p_reference) RETURNING id INTO decrement_id;
      RETURN decrement_id;
    END $$;
    GRANT USAGE ON SCHEMA public,auth TO authenticated;
    GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;
    GRANT SELECT ON public.mock_balance,public.mock_decrements TO authenticated;
  `);
  const migration = await readFile(new URL('../supabase/orders_monolith.sql', import.meta.url), 'utf8');
  await db.exec(migration);
  await db.exec(migration);
  await db.query('INSERT INTO public.stocks(id,user_id,name) VALUES ($1,$2,$3),($4,$5,$6)',
    [stock, owner, 'Owner', foreignStock, stranger, 'Stranger']);
  await db.query('INSERT INTO public.products(id,stock_id,name,sku,active,next_sale) VALUES ($1,$2,$3,$4,true,12.90),($5,$6,$7,$8,true,9.90)',
    [product, stock, 'Coca 2 L', 'C-2L', foreignProduct, foreignStock, 'Outro', 'OUT']);
  await db.query('INSERT INTO public.mock_balance(product_id,quantity) VALUES ($1,3),($2,10)',
    [product, foreignProduct]);

  await db.exec('SET ROLE authenticated');
  await db.query("SELECT set_config('request.jwt.claims',$1,false)",
    [JSON.stringify({ sub: owner, role: 'authenticated' })]);
  assert.equal((await db.query(
    "SELECT has_table_privilege('authenticated','public.order_sales','SELECT') AS allowed"
  )).rows[0].allowed, false);

  const imported = (await db.query(
    'SELECT public.orders_import_catalog($1,$2::jsonb) AS data',
    [stock, JSON.stringify([{ sourceProductId: product, price: 14.5 }])]
  )).rows[0].data;
  assert.equal(imported.length, 1);
  const catalogId = imported[0].id;
  assert.equal(imported[0].suggestedPrice, 12.9);
  const importedAgain = (await db.query(
    'SELECT public.orders_import_catalog($1,$2::jsonb) AS data',
    [stock, JSON.stringify([{ sourceProductId: product, price: 14.5 }])]
  )).rows[0].data;
  assert.equal(importedAgain[0].id, catalogId);
  await assert.rejects(db.query('SELECT public.orders_import_catalog($1,$2::jsonb)',
    [stock, JSON.stringify([{ sourceProductId: foreignProduct, price: 5 }])]),
  /Produto não encontrado/);

  const created = (await db.query('SELECT public.orders_create($1,$2::jsonb) AS data',
    [stock, JSON.stringify({ customer: 'Mesa 4', note: '', items: [
      { productId: catalogId, quantity: 2 }], finalTotal: 27, paid: 30 })])).rows[0].data;
  assert.equal(created.suggestedTotal, 29);
  assert.equal(created.items[0].unitPrice, 14.5);
  const changedPrice = (await db.query(
    'SELECT public.orders_update_price($1,$2,$3) AS data', [stock, catalogId, 16]
  )).rows[0].data;
  assert.equal(changedPrice.price, 16);
  assert.equal((await db.query('SELECT public.orders_list($1) AS data', [stock]))
    .rows[0].data[0].items[0].unitPrice, 14.5);

  await db.query('SELECT public.orders_change_status($1,$2,$3)', [stock, created.id, 'preparing']);
  const finished = (await db.query('SELECT public.orders_change_status($1,$2,$3) AS data',
    [stock, created.id, 'finished'])).rows[0].data;
  assert.equal(finished.status, 'finished');
  assert.equal((await db.query('SELECT quantity FROM public.mock_balance WHERE product_id=$1',
    [product])).rows[0].quantity, 1);
  await assert.rejects(db.query('SELECT public.orders_change_status($1,$2,$3)',
    [stock, created.id, 'finished']), /Transição de status inválida/);
  assert.equal((await db.query('SELECT count(*)::int AS n FROM public.mock_decrements'))
    .rows[0].n, 1);

  const insufficient = (await db.query('SELECT public.orders_create($1,$2::jsonb) AS data',
    [stock, JSON.stringify({ customer: '', note: '', items: [
      { productId: catalogId, quantity: 2 }], finalTotal: 32, paid: 0 })])).rows[0].data;
  await db.query('SELECT public.orders_change_status($1,$2,$3)',
    [stock, insufficient.id, 'preparing']);
  await assert.rejects(db.query('SELECT public.orders_change_status($1,$2,$3)',
    [stock, insufficient.id, 'finished']), /Saldo insuficiente/);
  assert.equal((await db.query('SELECT public.orders_list($1) AS data', [stock]))
    .rows[0].data.find(order => order.id === insufficient.id).status, 'preparing');
  assert.equal((await db.query('SELECT quantity FROM public.mock_balance WHERE product_id=$1',
    [product])).rows[0].quantity, 1);

  await db.query("SELECT set_config('request.jwt.claims',$1,false)",
    [JSON.stringify({ sub: stranger, role: 'authenticated' })]);
  await assert.rejects(db.query('SELECT public.orders_list($1)', [stock]), /Estoque não encontrado/);
  assert.deepEqual((await db.query('SELECT public.orders_list($1) AS data',
    [foreignStock])).rows[0].data, []);
  console.log('OK: importação, preços, pedidos, baixa única/atômica e isolamento por dono.');
} finally {
  await db.close();
}
